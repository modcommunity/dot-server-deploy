extends RefCounted

## A slow TCP link for a suite: a client connects to [method port] instead of the server, and
## everything the server sends it is let through at [member rate_down] bytes a second.
##
## [codeblock]
## const SlowTcpRelay := preload("res://examples/slow_tcp_relay.gd")
## var relay := SlowTcpRelay.new()
## relay.rate_down = 125000.0                 # 1 Mbit/s, server -> client
## var port := relay.start(server_tcp_port)
## # in _process: relay.poll(delta)
## [/codeblock]
##
## [b]Why not dot-net's relay.[/b] `dot_net_udp_relay.gd` carries datagrams, which is ENet; a
## WebSocket is TCP and nothing is lost on it, so what a slow link does to one is take time:
## a joiner's reliable messages queue behind each other and the server's other work has to
## carry on meanwhile. A queueing discipline would do it properly and needs root.
##
## [b]Polled, by the suite's frame.[/b] Delivery lands on frame boundaries, which is fine for a
## rate: what is measured is seconds, not milliseconds.

## Bytes a second from the server to the client. Upstream is not limited.
var rate_down: float = 125000.0

## The most a quiet link may save up and send at once, in seconds of [member rate_down].
var burst_seconds: float = 0.05

## Bytes carried towards the client so far.
var bytes_down: int = 0

## The most carried towards the client inside any [member peak_window_usec] (a browser's frame:
## its WebSocket peer holds what arrives between two frames in a 64 KiB buffer), and in any one
## [method poll], since [method reset_peaks]. Measured with [member rate_down] unlimited
## ([constant UNLIMITED]) these are what the server sent in a burst; see examples/burst_probe.gd.
var peak_window_usec: int = 16667
var peak_window: int = 0
var peak_poll: int = 0

## A [member rate_down] that never holds anything back.
const UNLIMITED := 1.0e12

var _arrivals: Array = []
var _arrival_sum: int = 0

var _listener := TCPServer.new()
var _target_port := 0
var _pairs: Array = []
var _budget := 0.0


## Listens on a free local port and returns it, or 0.
func start(target_port: int) -> int:
	_target_port = target_port

	if _listener.listen(0, "127.0.0.1") != OK:
		return 0

	return _listener.get_local_port()


func port() -> int:
	return _listener.get_local_port() if _listener.is_listening() else 0


func poll(delta: float) -> void:
	while _listener.is_connection_available():
		var downstream := _listener.take_connection()
		var upstream := StreamPeerTCP.new()
		upstream.connect_to_host("127.0.0.1", _target_port)
		_pairs.append([downstream, upstream])

	_budget = minf(_budget + rate_down * delta, rate_down * burst_seconds)
	var polled := 0

	for pair: Array in _pairs:
		var downstream: StreamPeerTCP = pair[0]
		var upstream: StreamPeerTCP = pair[1]
		downstream.poll()
		upstream.poll()

		# Either end gone (a client that disconnected): nothing to carry, and asking a closed
		# socket for its bytes is an engine error.
		if upstream.get_status() != StreamPeerTCP.STATUS_CONNECTED \
				or downstream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue

		var up := downstream.get_available_bytes()

		if up > 0:
			upstream.put_data(downstream.get_data(up)[1])

		var down := mini(upstream.get_available_bytes(), int(_budget))

		if down > 0:
			downstream.put_data(upstream.get_data(down)[1])
			_budget -= down
			bytes_down += down
			polled += down

	if polled > 0:
		_note_arrival(polled)


func reset_peaks() -> void:
	peak_window = 0
	peak_poll = 0
	_arrivals.clear()
	_arrival_sum = 0


func _note_arrival(bytes: int) -> void:
	var now := Time.get_ticks_usec()
	_arrivals.append([now, bytes])
	_arrival_sum += bytes

	while not _arrivals.is_empty() and int(_arrivals[0][0]) <= now - peak_window_usec:
		_arrival_sum -= int(_arrivals[0][1])
		_arrivals.pop_front()

	peak_window = maxi(peak_window, _arrival_sum)
	peak_poll = maxi(peak_poll, bytes)


func stop() -> void:
	for pair: Array in _pairs:
		(pair[0] as StreamPeerTCP).disconnect_from_host()
		(pair[1] as StreamPeerTCP).disconnect_from_host()

	_pairs.clear()
	_listener.stop()

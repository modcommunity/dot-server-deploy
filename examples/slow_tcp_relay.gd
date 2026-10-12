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

	for pair: Array in _pairs:
		var downstream: StreamPeerTCP = pair[0]
		var upstream: StreamPeerTCP = pair[1]
		downstream.poll()
		upstream.poll()

		if upstream.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue

		var up := downstream.get_available_bytes()

		if up > 0:
			upstream.put_data(downstream.get_data(up)[1])

		var down := mini(upstream.get_available_bytes(), int(_budget))

		if down > 0:
			downstream.put_data(upstream.get_data(down)[1])
			_budget -= down
			bytes_down += down


func stop() -> void:
	for pair: Array in _pairs:
		(pair[0] as StreamPeerTCP).disconnect_from_host()
		(pair[1] as StreamPeerTCP).disconnect_from_host()

	_pairs.clear()
	_listener.stop()

# Services built for every game: logging, the guard, parties, replay, friends

Each of these is operator- or shell-level: a game should not have to know about it, and this is where everything of that kind is built for every game at once. Each was once an addon that was installed, configured-for and documented here and never constructed by anything ([history.md](history.md#addons-installed-and-never-built)). **An addon in the list is not an addon in use: check that something constructs it.**

## The log sink layer

`TmcConfig.build_log_router()` and `TmcHost._build_logging()`, configured by `cfg/addon/dot_log/log.yml` below its "sink layer" divider: the in-memory ring behind `log tail`, RFC 5424 syslog, a batched HTTP collector in nine wire formats, redaction, and flood control.

- **The shared settings are copied out of `server`, not read twice.** The level, channels, mirror threshold and file settings exist on `DotServerConfig` because a deployment with no dot-log still has them through dot-core's sink; `build_log_router()` carries them across. A second set of keys would let a deployment that turned the router on silently write its log somewhere else.
- **`log_router: auto` is on.** The router's file target is a strict superset of the plain sink (same directory, basename, rotation, naming, `log_json`), and it adds `log status|tail|grep|targets|test` on the console. `off` restores the plain sink exactly. It accepts a bool as well as the three words ([configuration.md](configuration.md#the-configuration-is-a-surface-not-a-second-parser)).
- **It is built before the `DotServer`**: the router registers as a `DotLog` sink when it enters the tree, and the reason a boot went wrong is what an admin most wants from a log.

## The guard: dot-server-security

`TmcHost._build_security()`: a `DotSecurityManager` beside the server, one `DotSecurityWatch` wiring it to chat, connections, RCON, the console and dot-auth, and a `DotAntiCheat` reporting into the same rule engine. `cfg/addon/dot_server_security/security.yml` is the whole policy.

- **It ships in dry run**: every trip is logged and ledgered as `WOULD`, nobody is punished. A guard that punishes a community on thresholds nobody chose gets turned off after the first false positive. The intended sequence: read `sec_status` and `sec_log` for a week, then `sec_dryrun: false`.
- **Every anti-cheat movement threshold ships at 0 ("do not check").** A guessed speed limit bans the best player the first time they chain a surf ramp into a boost. `sec_ac_status` reports the fastest legitimate values seen.
- **Do not register its console commands here**: `DotSecurityManager.attach()` does it.
- **The guard is a child of the server, so its `server_ref` is `".."`**, not `"../Server"`. The two watchers are siblings of the guard, so their `"../Security"` is right, which is what makes the pair easy to copy wrong.

## Party, matchmaking and locale

`host/tmc_party.gd` (`TmcParty.install`, from the end of `TmcHost._boot`), from `cfg/addon/dot_party/party.yml` and `cfg/addon/dot_matchmaking/matchmaking.yml` (prefix rules: [configuration.md](configuration.md#prefixes-that-keep-two-copies-of-an-addon-apart)).

- **`DotPartyReservations`, always** (unless `party_enabled: false`); with no booking it admits everybody. `seats_fn` counts sessions past authentication against `max_players`; `bypass_fn` is a session holding `DotAdminFlags.RESERVATION`. Bookings come from the backbone when there is a client and from `party_reserve` at the console either way. `party_reserve` lends the booking a copy of the terms with the gates open and the ceiling kept, because the policy's gates are for site bookings, not an owner at their own console.
- **`DotPartyServer`, only with a backbone client** (`TmcReport`'s, which exists when `data/listing.json` has a token); one client serves both so one token has one rate limiter.
- **`DotMatchmaker`, only with `mm_enabled: true`.** Ratings go under `data/matchmaking/` unless the operator names a file.
- **The booking must be re-chained after every game change.** `DotPartyReservations` chains onto whatever holds `dot_ban_source`, which is the loaded game's dot-moderation; a game change registers a new one and `DotRegistry` is last-wins, so a private booking admitted anybody from the first `changelevel` on, in silence. `TmcParty` watches `DotRegistry.signals()` and puts the booking back on top, deferred, walking the holder's `previous_source` chain first so it never makes a loop. `examples/party_live.tscn` checks the seam before and after a real `changelevel`.
- **A player claims their party with a chat command**, `/party_claim <id>`, not a handshake field: a new handshake key is a signon change in every project, while a prefixed chat line is dispatched to the console before `player_chat` fires, so no game's router can swallow it. `DotPartyServer.claim` checks the roster; one claim per player per ten seconds.
- **Party chat is dot-chat's grouped members channel** (`DotChatChannel.grouped`, `DotChatRouter.group_fn`). Each game's router found in `DotRegistry` gets `DotChatChannel.group(&"party", "Party")` and a `group_fn` of `party_of(session.uid())` unless the game set either. `/party_say <text>`; a game with no dot-chat router gets system messages.
- **In the shell**, a signed-in player gets a `DotPartyClient` over `DotPartyBackendApp` with the shell's `DotAuthClient`; its `connect_fn` is the Connect button's `_connect_to`. Refusals go through a `DotLocale` over `client/locales/<lang>/*.json` (English ships); `explain()` uses the site's refusal key when the catalogue has it.
- **Not verified**: the booking feed (`GET party/reservation`) and the player routes under `/api/app/v1/party/*` are merged on the site and not known to be deployed. Until they are, a server with a token makes one failing sync every 30 s and says so once at INFO, and the shell switches its party client off on the first 404. No client has claimed a party over a real socket.

## The replay ring

`host/tmc_replay.gd` (`TmcReplay.install`, after `TmcParty`), from `cfg/addon/dot_replay/replay.yml`. Every server keeps a `DotReplayRing` (60 s, capped at 32 MiB) fed by a `DotReplayEventTap` on dot-server's event bus, plus a roster keyframe every 10 s. `replay`, `replay save [seconds] [why]` and `replay list` are on the console, RCON and chat.

- **It records the event bus and a roster, not the netcode.** Which peer's view a net tap records is a game's decision; a game that wants a watchable demo wires `DotReplayNetTap` itself.
- **The clock is the wall clock at `sv_tickrate`**, not the physics tick, because dot-server hibernates to 5 Hz when empty and "the last sixty seconds" must mean sixty seconds.
- **Per tick it costs one `Time.get_ticks_msec()` and `recorder.advance()`.** Chunks are compressed once a second when something was recorded; only a save is not O(1).
- **Evidence goes onto the punishment after the fact**, because none of the three punishment paths can ask for evidence before storing: on `DotBanManager.ban_added` the clip's `evidence()` goes on the stored dictionary and `save_bans()` runs again; an admin's `kick`/`kickid` gets a second audit line, `replay_evidence`; dot-moderation's `punished` gets the clip merged into `punishment.evidence` and an upsert. Every path also writes the audit line, which is append-only. The manager is re-found on every game change.
- **One clip per incident** (`replay_evidence_cooldown_sec`, 10). Two clips of the same ring are identical bytes, so the check compares paths and counts files.
- **Bounded on disk per directory**: `data/replays/matches`, `clips` and `evidence` each keep `replay_keep_files` and `replay_keep_mib`, so manual saves cannot push ban evidence off the disk. `replay_record` (a file per match) is off.
- **`directory` defaults to `data/replays`**, not the addon's `user://replays`, which is outside what a container mounts writable.

## The friends client, in the shell

`client/tmc_friends.gd` (`TmcFriends`), built by `shell.gd`'s `_build_friends()` from the same sign-in as the party client, over a `DotFriendsBackendApp` with the shell's `DotAuthClient`. Its own node so the suite can drive it with no window.

- **Presence follows the connection**: menu = online, not joinable; spawned = in game, joinable, "Playing <game> on <hostname>" (cut to 128); disconnect = online. The addon debounces into one post.
- **Quitting posts offline for up to two seconds** (`auto_accept_quit = false` while friends exist). A closed browser tab never asks; its presence expires after 120 s.
- **"Join my friend" prefers the party**, and falls back to a server only when this shell has been on it and knows its address: a presence that carried an address would bypass the site's `showNetInfo` gate. Anything else is refused with the site's `friends.join.deny.unsupported`.
- **A bare 404 turns it off for the session, once**; a 404 the site explained is a refusal. The node is kept with its backend nulled, because in-flight requests resume into it.
- The UI sits under the party line and is hidden for a guest. Rows are all the button's height (found by rendering it).

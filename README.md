This repository stores useful configurations and layouts for deploying a server under TMC's [Dot](https://moddingcommunity.com/co/4-dot-assets) ecosystem.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This tool is what puts them together into something you run.

**This tool and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This tool, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## A Server You Start With One Command
TMC's server tool, as a thing you can run.

This repository is where the [dot-*](https://github.com/modcommunity) family comes together into something a server owner starts with one command. It is a Godot project that boots a [dot-server](https://github.com/modcommunity/dot-server), reads its configuration from `cfg/*.yml`, loads games out of `content/`, and serves a browser client — and it ships **no game of its own**. The games are copied in from their own repositories by `setup.sh`: [game-simple-lobby](https://github.com/modcommunity/game-simple-lobby), which is the lobby it serves by default, [game-hungario](https://github.com/modcommunity/game-hungario) and [game-g2gfast](https://github.com/modcommunity/game-g2gfast).

```bash
./setup.sh              # find a runtime, wire the addons, write ./server
./server                # start it

docker compose up -d    # or the same thing in a container
```

Windows: `setup.bat` (a shim for `setup.ps1`), then `server.cmd`.

## What it gives a server owner

- **One command to start.** `./setup.sh` finds a Godot runtime, wires in the nineteen addons, writes a commented `cfg/`, and writes `./server`. It never overwrites a config file that already exists. RCON ships off; `cfg/rcon.yml` says how to turn it on.
- **Configuration in YAML**, in files split by subject — `server.yml`, `net.yml`, `rcon.yml`, `auth.yml`, `groups.yml`, `permissions.yml`. Anything dot-server exposes as a console variable can go in them under its own name.
- **Roles, not flags.** dot-server's permission model is flags, deliberately; `groups.yml` is the translation, so an operator writes `admin: [kick, ban, mute]` and a player gets the flags.
- **Moderation.** Bans, kicks, mutes, votes and an audit log, all dot-server's, all reachable from the console or over RCON.
- **Games loaded at runtime.** A directory under `content/` with a `game.yml` in it is a game. `changelevel` switches between them with players still connected.
- **The players choose the next game.** `!nominate`, `!rtv`, `!votefor`, `!timeleft`, `!nextmap` — the shape every server in this genre has had since 2005, over the games in `content/` rather than over maps. Each game gets its own time limit, in its own `game.yml`. All of it is `cfg/vote.yml`, and `enabled: false` turns it off.
- **A browser client.** `./server export-web` builds it; one export serves every server, because the address comes from `?server=`.

## The layout

```
cfg/                 what an operator edits
  server.yml           name, slots, tickrate, the game to boot
  net.yml              bind address, port, bandwidth
  rcon.yml             remote console. Generated once, printed once
  auth.yml             the identity backend, or nothing and everybody is a guest
  groups.yml           groups, as sets of permissions
  vote.yml             voting for the next game: rtv, nominations, time limits
  permissions.yml      who is in which group
  content/<id>/        per-game configuration

content/             what the server serves
  global/              loaded by every game
  lobby/game.yml       the lobby. The default

data/                what the server writes
  from_yaml.cfg        what your YAML became. Read this when a setting seems ignored
  admins.json  bans.json  audit.jsonl

host/                the boot: YAML -> DotServer
client/              the client shell. Knows nothing about any game
web/                 the browser build, and the page that takes ?server= from the URL
```

Three directories, and the split is the point: `cfg/` and `content/` are read, `data/` is written. A container mounts the first two read-only and the third read-write, and a systemd unit points `ReadWritePaths` at exactly one directory.

## Configuration

`cfg/*.yml` is a **surface over dot-server's own vocabulary**, not a second one.

Where a key names something the console already knows, it is compiled into a `.cfg` and handed to the console — which is the parser, the validator, the range clamp and the audit trail. Where it names something fixed before the console exists (the port, the bind address) it goes to the boot config. Everything else — groups, per-user permissions, the auth backend — is handed to whatever owns it.

`data/from_yaml.cfg` is written on every boot and is exactly what your YAML became. It is written out rather than kept in memory because "what did my configuration actually become" is the question an operator has when a setting appears not to work.

An unknown key is **reported, never fatal**. Refusing to boot because a config mentions a setting from a newer version is worse than ignoring it.

The YAML reader is a deliberately small subset and refuses everything else with a file and a line number: tabs, duplicate keys, anchors, aliases, tags, block scalars, inline mappings, document markers. See `host/tmc_yaml.gd` for why.

`vote.yml` is the one file that is not a console surface: it is dot-vote's `DotVoteRules`, applied straight onto the resource, so every setting in it is documented on the property of the same name. **Enums are written by name** — `method: instant_runoff`, not `method: 2` — because a config file full of enum indices is one nobody can read or diff, and renumbering an enum would silently change how a server counts votes.

## ./server

```
./server                      start it
./server check                boot, load the game, shut down. Exit 0 if it worked
./server config               the resolved configuration
./server games                what is in content/
./server export-web           build the browser client
./server --help               every option

./server --port 27015 --name "My server"
./server -- +sv_cheats 1 +changelevel lobby
```

Exit codes are meaningful, so a supervisor can tell a misconfiguration from a crash: `2` usage, `3` no runtime, `4` no project, `5` bad config, `6` port in use, `7` bad content.

**Secrets are not options.** `--rcon-password` is refused outright: argv is readable by every other process on the machine and ends up in pasted bug reports, which is why `DotConfig` refuses secrets from argv and the environment too.

## Docker

```bash
docker compose up -d
docker compose logs -f
```

The build context is the **parent** directory: every dot-* addon is its own repository and there is no way to clone the tree at once, so they are siblings rather than subdirectories.

`cfg/` and `data/` are bind mounts, so the first run writes a configuration you can edit and an RCON password that survives a rebuild. `content/` is mounted read-only. The container runs as your own uid (`UID=$(id -u) GID=$(id -g) docker compose up -d`), not as root, and drops every capability.

RCON is published on **loopback only**. It is a remote console and the password is the only thing between it and whoever finds the port; reach it through an SSH tunnel, or put an address allow-list in `cfg/rcon.yml` and widen the mapping deliberately.

## Validating

```bash
tools/check.sh          # parse, shell syntax, every suite, then a real boot
tools/package_check.sh  # vendor the addons, move the tree away from its siblings, boot it
```

| | |
| --- | --- |
| `examples/selftest.tscn` | the YAML reader, the config translation, the permission translation, the content index |
| `examples/multigame.tscn` | changing games on a running server, and the module swap that goes with it |
| `examples/live_switch.tscn` | **the same, with a real client on a real socket** |
| `./server check` | a real `DotServer` booting, loading the lobby, and shutting down |

The third one earns its place. Switching games under a live client segfaulted the server — twice over, once going in and once coming out — and `multigame` passes the same switch with an occupant seated in the world. An occupant is not a socket.

The second one matters because a release tarball and the container have no sibling repositories to link to, and a symlink out of `addons/` dangles the moment the directory moves — every `dot-*` class unresolved at once, which reads as a broken project rather than a broken link.

The browser target has its own check, because it is the one thing a headless Godot run cannot see — the WASM loading, the WebSocket handshake a browser performs, and whether anything is actually drawn:

```bash
./server &
(cd web/build && python3 -m http.server 8099) &
node tools/browser_check.mjs 'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6064' shot.png
```

## Known limits

- **One transport at a time.** A server listens on WebSocket *or* ENet, so a desktop client on UDP and a browser client on TCP cannot share a match yet. See [PLATFORM.md](../../PLATFORM.md).
- **`cfg/permissions.yml` does nothing without authentication.** `DotAdminManager` refuses permissions to any unauthenticated session — a guest uid is a random per-device string, so granting anything to one grants it to anyone. Correct, and it looks exactly like the file being ignored.
- **No game has been delivered as a pack yet.** The lobby ships inside the build. See CLAUDE.md for the constraint that decides what a delivered game may look like.
- **No TLS.** A page on HTTPS cannot open `ws://`. Certificates and a reverse proxy are deployment, not code.

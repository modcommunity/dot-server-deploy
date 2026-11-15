Everything a server owner needs to run a game on the [Gamespice](https://gamespice.net) platform with one command. It is a Godot project that boots a [dot-server](https://github.com/gamespice-platform/server), reads its settings from `cfg/*.yml`, loads games from `content/` and serves a browser client. It ships no game of its own: games are fetched as signed packs.

## Install and run

```bash
git clone https://github.com/gamespice-platform/server-deploy && cd dot-server-deploy
./setup.sh                      # fetches a Godot runtime, links the addons, writes ./server
./server --games fatalcontact   # installs the game if needed, then starts the server
./server --help                 # every command and option
```

On a machine with no Godot, `./setup.sh` downloads a pinned, checksum-verified one (`--no-download` refuses, `--godot PATH` uses yours). On Windows run `setup.bat`, then `.\server.ps1`; it takes the same options. In a container, use `docker compose up -d`.

For a full public server on a fresh Linux box, `./setup.sh --full` asks about ten questions (name, game, slots, port, hostname, nginx with a certificate, a systemd service), prints the plan and does nothing until you confirm. `--yes` takes every default.

## Try a game on your own machine

```bash
./play.sh              # a server and the browser client on the loopback; prints a link
./play.sh playlot      # start on a particular game
./play.sh games        # what else is in content/
./play.sh status
./play.sh down
```

## What to edit

| Edit | Never edit |
| --- | --- |
| `cfg/server/addon/<addon>/` and `cfg/server/game/<game>/` (your settings) | `addons/`, `content/`, `games/`, `dist/` (replaced by an upgrade) |
| `cfg/content/addons.yml` and `games.yml` (what gets downloaded) | `cfg.example/`, `content-lists/` (the shipped defaults) |
| `cfg/server/content/overrides.yml` (per-game cvars and maps), `cfg/packs.yml` (extra packs) | `./server` (generated: re-run `./setup.sh` after changing `tools/server.in`) |

`setup.sh` copies `cfg.example/` into `cfg/` only for files you do not have, and never overwrites one. `data/from_yaml.cfg` is written on every boot and shows what your YAML became, so read it when a setting seems ignored. Unknown keys are reported, never fatal.

## Commands

| Command | Does |
| --- | --- |
| `./server` | Start the server. |
| `./server check` | Boot, load the game, shut down. Exit 0 if it worked. |
| `./server config` | Show the resolved configuration. |
| `./server games` | List what is in `content/`. |
| `./server install-games` | Fetch the games named in `--games`. |
| `./server pack <id>` | Turn a directory in `content/` into a signed pack in `dist/`. `--all` does every one and `./server verify <id>` checks the signature. |
| `./server export-web` | Build the browser client. One export serves every server (the address comes from `?server=`). |
| `./server export-native` | Build the native client for Linux, Windows and macOS. |

Options include `--port`, `--bind`, `--name`, `--max-players`, `--game`, `--map`, `--config`, `--content`, `--data`, `--verbose` and `--dry-run`. Pass console commands after `--`, for example `./server -- +sv_cheats 1`. Secrets such as `--rcon-password` are refused on the command line.

| Exit code | Meaning |
| --- | --- |
| 2 | Usage error |
| 3 | No runtime |
| 4 | No project |
| 5 | Bad config |
| 6 | Port in use |
| 7 | Bad content |

## What a server owner gets

| Feature | Where to set it |
| --- | --- |
| Roles such as `admin: [kick, ban, mute]` | `cfg/addon/dot_server/groups.yml` |
| Bans, kicks, mutes, votes and an audit log | Console or RCON. RCON listens on loopback until you widen `rcon_allowed` in `cfg/addon/dot_console/rcon.yml`. |
| `/admin` menu for kicks, bans, warnings and game-specific powers | `cfg/addon/dot_menu/admin_menu.yml` |
| Loading screens (picture, music, tips) during game or map changes | `cfg/addon/dot_core/loading.yml` |
| Players voting for the next game (`!game_nominate`, `!game_rtv`, `!game_vote`) | `cfg/addon/dot_vote/vote.yml` |
| Party bookings | `cfg/addon/dot_party/party.yml` |
| "Save that" clips and evidence with every ban | `cfg/addon/dot_replay/replay.yml` |
| Shared radio (off by default; add `- repo: dot-radio` to `cfg/content/addons.yml`) | `cfg/addon/dot_radio/radio.yml` |
| Matchmaking queue (off by default) | `cfg/addon/dot_matchmaking/matchmaking.yml` |
| Games swapped at runtime with players connected | `sv_game` and `sv_map` in `cfg/server/server.yml`, or `--game` and `--map` |

## Known limits

- nginx does not carry UDP. A server listens on both WebSocket (TCP, for browsers) and ENet (UDP, for the desktop client). Behind nginx only WebSocket goes through the proxy, so open the ENet port (`net_enet_port`) on the firewall, or desktop clients fall back to TCP after 2.5 seconds.
- `cfg/addon/dot_server/permissions.yml` does nothing until `cfg/addon/dot_auth/auth.yml` is turned on, because guests never receive permissions.
- A connecting player is a guest until the server can prove who they are. Details of the ticket sign-in are in [docs/reference.md](docs/reference.md#known-limits).
- The server itself has no TLS. `deploy/issue-letsencrypt.sh` and `deploy/install-server-tls.sh` set up a certificate and an nginx proxy for `wss://`.

## More

| Document | Covers |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Install in detail. |
| [docs/operator-config.md](docs/operator-config.md) | Changing a setting, and the config layers. |
| [docs/content-lists.md](docs/content-lists.md) | Choosing games and addons. |
| [docs/releases.md](docs/releases.md) | Releasing addons, games and the web shell. |
| [docs/reference.md](docs/reference.md) | Guided install, layout, packs and signing, upgrading, Docker, TLS. |
| [docs/README.md](docs/README.md) | Every other document. |

## Status and licence

Part of the [Gamespice](https://gamespice.net) platform: a family of Godot addons. Written with Claude Code and maintained by `gamemann`. Every addon has headless tests, but little of this has been played by real users yet, so expect rough edges and please [open an issue](https://github.com/gamespice-platform/server-deploy/issues) when you hit one.

MIT licence, see [LICENSE](LICENSE). The only closed part of the [Gamespice](https://gamespice.net) platform is the web back end; you can use your own instead of Gamespice's.

# dot-server-deploy

TMC's server tool: boots a dot-server from `cfg/` and `content/`, serves games as signed dot-cloud packs, and exports the client shell for the browser and the desktop. **It ships no game.** It is also the release machinery: `addons.lock`, the shell builds, `setup.sh`, the Pterodactyl egg.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is what is specific to here. The operator's view of every feature is the [README](README.md); the reasoning is in [docs/](docs/README.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/delivery-constraint.md](docs/delivery-constraint.md) | anything about how a game is packed, mounted or referenced; a new game in `content/` |
| [docs/configuration.md](docs/configuration.md) | `cfg.example/`, a new setting, `TmcConfig`, `TmcAdmins`, `cfg/content.yml` |
| [docs/installing-games.md](docs/installing-games.md) | `install-games`, `index`, `TmcContent`, `TmcGameRef`, a game's pack lists |
| [docs/setup.md](docs/setup.md) | `setup.sh`, `setup.ps1`, `tools/server.in`, the addon or game lists, the runtime fetcher |
| [docs/pterodactyl.md](docs/pterodactyl.md) | the egg, anything run non-interactively |
| [docs/releases.md](docs/releases.md) | any release: addon, game or shell; `addons.lock`; `web/shell-build`; exporting |
| [docs/addon-packs.md](docs/addon-packs.md) | `client/boot.tscn`, `_advertise_addons`, the update-and-restart path |
| [docs/native-client.md](docs/native-client.md) | `export-native`, launch arguments, presets |
| [docs/web-client.md](docs/web-client.md) | `client/shell.gd`, sign-in, clearing downloads, TLS |
| [docs/game-vote.md](docs/game-vote.md) | `host/tmc_vote.gd`, `cfg/vote.yml`, the notice overlay |
| [docs/admin-menu.md](docs/admin-menu.md) | `/admin`, `cfg/admin_menu.yml`, the loading screen |
| [docs/operator-services.md](docs/operator-services.md) | logging, the security guard, party, matchmaking, replay, friends |
| [docs/enrollment.md](docs/enrollment.md) | `host/tmc_enroll.gd`, `data/listing.json` |
| [docs/testing.md](docs/testing.md) | adding or trusting a suite |
| [docs/history.md](docs/history.md) | a deployment bug that "cannot be happening" |
| [docs/not-yet.md](docs/not-yet.md) | planning: what is not built, published or verified yet |

## Layout

| Path | What |
| --- | --- |
| `host/` | the server: boot, cfg, content, the game vote, admin menu, enrollment and the rest. **Not in the client build**. [files](docs/README.md#where-the-code-is) |
| `client/` | the shell: `boot.tscn` (main scene; mounts an addon overlay), `shell.gd`, the notice overlay, admin menu, loading screen, friends, `locales/` |
| `cfg.example/` | the tracked config templates; `cfg/` is written from them once and gitignored |
| `content/<id>/` | descriptors (`game.yml`, `pack.json`) for first-party games and map packs; installed games land in `content/<owner>/<name>/` |
| `tools/` | `server.in` (generates `./server`), the installer, indexer and packer, the check scripts, `addons-lock.sh`, the runtime fetchers |
| `examples/` | every suite, `enet_relay` and `burst_probe` (every game), and one `*_client` per delivered game |
| `addons/`, `addons.lock` | linked addons (`addons/.repos/` holds clones) and the tag each is locked to |
| `games/` | game repositories (links on a developer box), `.gdignore`d |
| `dist/`, `data/`, `keys/` | published packs, runtime state, the signing key (all gitignored) |
| `web/` | `README.md` (publishing), `embed.html`, `tmc-loader.js`, `shell-build` (tracked) |
| `deploy/` | `pterodactyl-egg.json`, TLS and nginx scripts, systemd, S3 publish |
| `games.list` | every game and maps pack `setup.sh` publishes, `<repository> <content directory>` |
| `setup.sh`, `setup.ps1`, `Dockerfile`, `demo.sh`, `play.sh`, `upgrade.sh` | installers and front doors |

## Running and testing

```bash
./setup.sh                    # runtime, addons, games, packs, ./server
./server                      # start it;  ./server check  boots, loads the game, exits 0
tools/check.sh                # parse, every suite, a real boot;  --long  adds every game on ENet through a lossy relay
tools/check_boot_failures.sh  # ./server check must refuse a game that cannot compile
tools/voice_all_games.sh      # voice between two real clients, in every delivered game
tools/package_check.sh        # the shipped (vendored) shape
node tools/browser_check.mjs  # the only check that sees a browser
```

Exit codes: `2` usage, `3` no runtime, `4` no project (`install-games`: addons behind), `5` bad config, `6` port in use (game or RCON port), `7` bad content or a script error during `check`. [testing](docs/testing.md)

## Rules that bite

**Delivery**

- The shell's `project.godot` keeps `audio/driver/enable_input=true`, or no delivered game can open a microphone. [web](docs/web-client.md#the-shells-projectgodot)
- The shell's `project.godot` carries no comments (the editor drops them); its reasons are in [web](docs/web-client.md#the-shells-projectgodot).

- Both web pages load dot-audio's `dot_audio_ceiling.js` before `index.js`, the browser player's only limiter; a change needs a new shell. [web](docs/web-client.md#the-browsers-audio-ceiling)
- A delivered game references its own files by relative path; no `class_name`, and every `res://` string through `<Game>Paths.rebase()`. [delivery](docs/delivery-constraint.md#rules-that-follow)
- `rebase()` is one line over `rebase_onto(path, root)`, so a suite can test with a mount prefix; tested against `res://` it passes with the bug in. [delivery](docs/delivery-constraint.md#rules-that-follow)
- A form of the mount constraint is closed when every game closes it. [delivery](docs/delivery-constraint.md#rules-that-follow)
- A pack is named for its content id; packs are imported (`--import`) before publishing; `pack.json`'s `exclude_dirs` matches at any depth. [delivery](docs/delivery-constraint.md#publishing-a-pack)
- `tools/pack.gd` derives `requires.json` in the source project and adds it without touching the checkout. [delivery](docs/delivery-constraint.md#publishing-a-pack)
- A delivered module may only name base classes this build carries. [delivery](docs/delivery-constraint.md#rules-that-follow)

**Configuration**

- `cfg/` is never overwritten and never tracked; change a default in `cfg.example/`, and remember existing boxes keep their copy. [config](docs/configuration.md#cfg-is-written-by-setup-cfgexample-is-tracked)
- Layers: defaults < `cfg/*.yml` < `DOT_SERVER_*` < argv. `TMC_*` become arguments, so they outrank the YAML. [config](docs/configuration.md#layers)
- `cfg/*.yml` reaches dot-server as console lines; a setting whose cvar does not exist yet at that point is a config field the host applies. [config](docs/configuration.md#the-configuration-is-a-surface-not-a-second-parser)
- `TmcYaml` reads `on`/`off` as bools; a word-valued setting must accept a bool. [config](docs/configuration.md#the-configuration-is-a-surface-not-a-second-parser)
- The game vote's prefix is `DOT_GAME_VOTE_*`, never `DOT_VOTE_*` (the loaded game's map vote). [config](docs/configuration.md#prefixes-that-keep-two-copies-of-an-addon-apart)
- `cfg/content.yml` refuses identity keys and unknown keys by name; unpinned maps resolve per start into `data/content-maps.json`, never per join. [config](docs/configuration.md#a-server-owners-settings-per-game-cfgcontentyml)
- Admin roles grant nothing to an unauthenticated session, by design. [config](docs/configuration.md#roles-in-flags-out)

**Games and installing**

- On a box that installs games at runtime use `setup.sh --no-games`, never `--only-games` (it unlinks addons a later game needs). [install](docs/installing-games.md#a-server-that-installs-its-games-must-build-none-of-them)
- `TmcGameRef` is the one parser of a games list; descriptors are keyed by directory id, prefetch by content id. [install](docs/installing-games.md#names-and-ids)
- Every pack list is pinned at install; `TmcContent` refuses an unpinned entry. Publish a dependency before the game that names it. [install](docs/installing-games.md#three-lists-of-packs-beside-the-games-own)
- `install-games` keeps manifests in `data/manifests/`; test offline boots with `dist/` moved aside. [install](docs/installing-games.md#rules-of-the-installer)
- `fetch_manifest`/`verify_manifest` need a started `DotCloudClient`. [install](docs/installing-games.md#a-game-is-two-halves)
- Nothing an operator wrote is deleted or overwritten: `--games-mode remove` prunes only what it installed, `game.yml` needs `--refresh`. [install](docs/installing-games.md#rules-of-the-installer)

**Setup and the egg**

- One fact, one place: `games.list` (every game and maps pack; `setup.sh` builds `GAMES` from it), `ADDONS_ALL`, `addon_repo()`, `repo_url()`, `tools/game_source.sh`. Other scripts read them; never copy a list. [setup](docs/setup.md#one-fact-one-place)
- `setup.ps1`'s addon list and `Get-AddonRepo`, and the zee exception in `addons-lock.sh`/`package_check.sh`, are copies; `tools/check_lists.sh` fails when they drift or a game has no `games.list` line. [setup](docs/setup.md#one-fact-one-place)
- `./server` is generated from `tools/server.in`: re-run `setup.sh` after editing the template. [setup](docs/setup.md)
- No git, unzip or other tool this project drives may prompt: `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`, `BatchMode`, `< /dev/null`, `timeout`. [egg](docs/pterodactyl.md#no-git-may-ask-anything)
- `safe.directory '*'` belongs in the egg's install script only, never in `setup.sh`. [egg](docs/pterodactyl.md#a-reinstall-is-root-looking-at-somebody-elses-checkout)
- Paths baked at install must be project-relative (the volume moves from `/mnt/server` to `/home/container`). The startup line uses `{{SERVER_PORT}}`; old servers keep their own copy of it. [egg](docs/pterodactyl.md)
- The runtime is pinned and checked against digests in the script; a mismatch deletes and exits. Stage downloads on the destination filesystem, not `/tmp`. [setup](docs/setup.md#the-runtime-toolsfetch-godotsh)
- `setup.ps1` and `server.ps1` have never been run on Windows; `server.ps1.in`'s `pack` still names a scene that does not exist. [setup](docs/setup.md#windows)

**Releases and shells**

- Addon release: tag → site publishes the pack → `tools/addons-lock.sh write`, push → restart. Push the lock only after the packs are on the origin. [releases](docs/releases.md#the-release-orders)
- Game release: tag the addons → lock here → release this repo → tag the game. [releases](docs/releases.md#the-release-orders)
- A new shell is needed for the engine, the boot stage, `client/` code, a signon change, or addon files outside `addons/<dir>/`. [releases](docs/releases.md#what-needs-a-new-shell)
- `tools/addons-lock.sh check` before any export; check against the tags, not the sibling checkouts. [releases](docs/releases.md#addonslock)
- `setup.sh` moves only its own clones to the lock, never a developer's checkout. [releases](docs/releases.md#addonslock)
- `web/shell-build` must name a build that is uploaded and registered, or players get the shared build. [releases](docs/releases.md#webshell-build-and-sv_web_build)
- `export-web` publishes nothing; check the deployed bytes before believing a client conclusion. Content before build. [releases](docs/releases.md#publishing-the-web-build)
- Native launch arguments come after a bare `--`; Godot silently ignores what it does not know. [native](docs/native-client.md#the-launch-arguments-need-the-bare---)

**Host and shell**

- `host/` is not in the client build: what both sides need is written twice, and a suite checks the copies agree. [vote](docs/game-vote.md#on-the-hud), [admin](docs/admin-menu.md#the-loading-screen-covers-a-change-never-the-first-join)
- The game vote's commands keep the `game_` prefix and its director `register_service = false`; one game on offer means no game vote. [vote](docs/game-vote.md)
- The notice overlay draws nothing at the top centre: lines then ballots in one right-hand column; a ballot hides the line it names; ballots are opaque. [vote](docs/game-vote.md#on-the-hud)
- The game vote and a game's own vote never show a ballot together (`TmcVote` chains every director's `busy_fn`). [vote](docs/game-vote.md#the-games-own-vote-and-this-one-take-turns)
- A module's unload runs AFTER its game's scene is freed: guard every world reference in `_module_unload` with `is_instance_valid`. [vote](docs/game-vote.md#the-games-own-vote-and-this-one-take-turns)
- An admin menu leaf is a console line run with the admin's context; never act directly. Notice payloads are measured in bytes with `var_to_bytes`. [admin](docs/admin-menu.md#the-menu-is-a-way-of-typing-a-command)
- A new client-to-server feature is a new envelope kind, not chat (chat has a flood limit) and not a handshake key (a signon change). [admin](docs/admin-menu.md#the-menu-is-a-way-of-typing-a-command)
- Solo (`--solo`, `?solo=`) mounts a pack as a join does and starts its `client_scene` with NO client link; a game reads its solo map packs from `DotRegistry` `dot_solo` by name, and `client/solo.json` must match `cfg.example/content.yml`. [web](docs/web-client.md#solo-play)
- The shell signs in only by `try_web_handoff()`; `client/auth.json` names the site origin, never the game origin. [web](docs/web-client.md#what-the-web-player-signs-in-against)
- Anything chained onto a `DotRegistry` service a game registers must re-chain after every game change (registry is last-wins). [services](docs/operator-services.md#party-matchmaking-and-locale)
- An addon in the list is not an addon in use: something must construct it. [services](docs/operator-services.md)
- The security guard ships in dry run with movement thresholds at 0. [services](docs/operator-services.md#the-guard-dot-server-security)
- Only a command-line boot enrolls with the site; suites never do. [enrollment](docs/enrollment.md#rules)
- One game port for WebSocket and ENet (A2S and DQP on its UDP), RCON one up; behind TLS the game binds 127.0.0.1; on a panel set every port. [web](docs/web-client.md#ports-and-transports)

**Testing**

- A delivered-client suite is the only proof a delivery change works; a game's own suites cannot see the mount. [testing](docs/testing.md#a-real-client-in-a-delivered-game)
- `template_client` packages the template's HEAD: commit it first. [testing](docs/testing.md#a-real-client-in-a-delivered-game)
- A server and a client in one process: the server gets its own World3D (`ServerWorld.add`); a scratch copy of the project its own user folder and port. [testing](docs/testing.md#server-side-suites)
- A client "in" a game is not its netcode working: after a game change, probe the game's own link (`return_to_game`). [testing](docs/testing.md#server-side-suites)
- Arm every new check, and read the exit code even when every check passed. [testing](docs/testing.md#arming)
- ENet's packet throttle must stay at 32 at both ends of every game's client; `enet_relay -- --stock-throttle` is the control and must fail. [testing](docs/testing.md#a-real-client-in-a-delivered-game)
- No game may send a browser more than 48 KiB in one frame (its WebSocket peer drops what overflows 64 KiB); `tools/burst_all_games.sh` measures every game. [testing](docs/testing.md#a-real-client-in-a-delivered-game)

## Deliberately not here

- **A package** (.deb/.rpm): `./setup.sh --full` is the installer, because the engine is pinned per checkout and two servers on a box should be two clones.
- **A server browser**: dot-server-query answers both query protocols; nothing here asks. `sv_query_app` is display only.
- **TLS in the host or client**: it is deployment, in `deploy/`.

# dot-server-deploy docs

**Start with** the [README](../README.md) (install, quick start, what to edit). Operators: [setup.md](setup.md), [operator-config.md](operator-config.md), [content-lists.md](content-lists.md), [releases.md](releases.md). Editors of this tool: the rest.


The reasoning behind [../CLAUDE.md](../CLAUDE.md)'s rules. The operator's view of every feature is the [README](../README.md); publishing the web shell is [web/README.md](../web/README.md).

| File | Subject |
| --- | --- |
| [delivery-constraint.md](delivery-constraint.md) | Why every game is a pack, the seven forms of the mount constraint, `rebase()`, publishing and stale packs |
| [configuration.md](configuration.md) | `cfg/` vs `cfg.example/`, the layers and `TMC_*`, YAML as a console surface, config fields, prefixes, roles to flags, `cfg/server/content/overrides.yml`, `cfg/packs.yml` |
| [operator-config.md](operator-config.md) | the operator's guide to `cfg/`: layers, worked examples, which layer wins |
| [content-lists.md](content-lists.md) | `cfg/content/addons.yml` and `games.yml`: the download lists, their schema and layers |
| [installing-games.md](installing-games.md) | `install-games` and `index`, descriptors, `owner/name@version`, `@latest`, the three pack lists, `--no-games` |
| [setup.md](setup.md) | `setup.sh`: one fact one place, addons and games inside the tree, `--only-games`, the runtime fetcher, Windows |
| [deploy-modes.md](deploy-modes.md) | `./setup.sh --mode compose` or `--mode pterodactyl`: files for Docker Compose or a panel, with a worked example each |
| [pterodactyl.md](pterodactyl.md) | The egg, and every way a panel install hung or died |
| [releases.md](releases.md) | Release orders, what needs a new shell, `addons.lock`, self-update, `sv_web_build`, `sv_web_requires`, `sv_web_loader`, publishing the web build |
| [addon-packs.md](addon-packs.md) | Addon releases reaching players by a restart, and the end-to-end proof |
| [native-client.md](native-client.md) | `export-native`, the bare `--`, presets, macOS |
| [web-client.md](web-client.md) | The shell: sign-in, refusals, clear downloaded content, TLS |
| [game-vote.md](game-vote.md) | The vote for the next game, on the HUD and as a ballot |
| [admin-menu.md](admin-menu.md) | `/admin`, `warn`, game menu layers, the loading screen |
| [operator-services.md](operator-services.md) | Log router, security guard, party/matchmaking/locale, replay ring, friends |
| [enrollment.md](enrollment.md) | A server proving its address to get its own site credential |
| [testing.md](testing.md) | The check scripts, every suite, the delivered-client suites, arming |
| [history.md](history.md) | Bug stories worth keeping |
| [not-yet.md](not-yet.md) | What is not built, published or verified yet |

## Where the code is

The files of [CLAUDE.md](../CLAUDE.md)'s layout table, one by one.

| Path | What |
| --- | --- |
| `host/` | the server: `tmc_host.gd` (boot, game loading, cvars), `tmc_config.gd` + `tmc_yaml.gd` (cfg), `tmc_content.gd` + `tmc_game_ref.gd` + `tmc_game_config.gd` (games), `tmc_admins.gd`, `tmc_vote.gd`, `tmc_party.gd`, `tmc_replay.gd`, `tmc_admin_menu.gd`, `tmc_loading.gd`, `tmc_enroll.gd`, `tmc_report.gd` (site listing), `tmc_script_watch.gd`. **Not in the client build** |
| `client/` | the shell: `boot.tscn` (main scene; mounts an addon overlay), `shell.tscn`/`shell.gd`, `notice_overlay.gd`, `admin_menu_panel.gd`, `loading_screen.gd`, `tmc_friends.gd`, `locales/`, `auth.json` + `content.json` (shipped, gitignored) |
| `tools/` | `server.in` (generates `./server`), `server.ps1.in`, `install_games.gd`, `index.gd`, `pack.gd`, `check.sh`, `check_lists.sh`, `check_boot_failures.sh`, `enet_relay_all_games.sh`, `burst_all_games.sh`, `package_check.sh`, `browser_check.mjs`, `browser_update_check.mjs`, `addons-lock.sh`, `fetch-godot.sh`, `fetch-export-templates.sh`, `game_source.sh`, `rcon.mjs`, `progress_shot.gd` |
| `examples/` | every suite: `selftest`, `multigame`, `game_vote_all`, `game_vote_rounds`, `live_switch`, `reconnect`, `return_to_game`, `shell_notice`, `party_live`, `pack_requires`, `admin_*`, `enet_relay` and `burst_probe` (every game), and one `*_client` per delivered game |

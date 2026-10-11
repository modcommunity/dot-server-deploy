# Testing

```bash
tools/check.sh                # parse, shell syntax, every suite, then a real boot (./server check)
tools/check_boot_failures.sh  # two boots whose game cannot compile; ./server check must refuse both
tools/package_check.sh        # the same in the shape an operator unpacks
node tools/browser_check.mjs  # the export in a real Chromium against a real server
```

## What each layer proves

- **`examples/selftest.tscn`**: the YAML reader, config translation, permission translation, content index, the game vote's HUD cues, the per-game owner settings, the sink layer, the guard, the replay ring and the friends client, against fixtures in `examples/fixtures/`. The fixtures are asserted value by value, so changing one changes a check: they are the exact keys an operator writes checked against the settings they must reach.
- **`./server check`**: a real `DotServer`, a real listener, the default game loaded and its module in it. It also asserts the operator's console (`log`, `sec_status`, `sec_why`, `party_status`, `mm_status`, `replay`), runs `party_status`, fails if the replay ring is not recording, and checks `sv_web_build` and `sv_web_loader` are NOTIFY. An absent command is invisible otherwise: nothing errors until an admin types it during an incident.
- **`./server check` fails on any script error** (exit 7). `TmcScriptWatch` is a `Logger` on the engine's log for the length of a selftest and fails on `Parse Error` / `Could not find base class` / `Failed to load script`, which also catches a broken script that is not the module. dot-server's `load_module` refuses a script that cannot instantiate. A script that fails to parse takes no exit path in Godot, which is how `selftest ok` once printed over a module that never compiled. It cannot catch a parse failure in `host/tmc_host.gd` itself (the scene then never quits), which is why `check_boot_failures.sh` caps each case with `timeout`.
- **`tools/package_check.sh`** exports the tracked files only, runs `setup.sh --vendor`, moves the result away from the siblings, and checks nothing points out of the tree, `addons/` holds real directories, and it boots. It reaches the branch of `check.sh` a developer checkout cannot: no sibling to compare against, so the staleness check reports `--` and must still pass. It does not build the container (needs a Docker daemon).
- **`tools/browser_check.mjs` is the only one that can see the browser**: WebSocket, console and a screenshot. Several of this project's bugs were reachable no other way. A local page cannot fetch game content from the CDN (CORS); see the family notes on local browser testing.

## Server-side suites

- `examples/multigame.tscn`: boots buses and switches games; the game vote's rules (`begin_on_apply`, one game = no vote) and its notices at the server.
- `examples/live_switch.tscn`: `changelevel` between games under live players. It names any game it cannot list, offer or vote for.
- `examples/reconnect.tscn`: a client in `PLAYING` is not proof of a join. `DotClientLink` enters `PLAYING` itself after sending `loaded`; the suite also waits for the server session in `SPAWNED` on both connects.
- `examples/game_vote_all.tscn`: the game vote through EVERY game with a real shell attached, each switched into and out of by a click: rock the vote, the game's own ballot waiting and following, the time limit, one entry per game, never two ballots in a frame, the last game's modules gone. Needs every game published in `dist/` (it names any that is not); `-- --shot=<png>` under `xvfb-run` renders the drawn ballot instead. About four minutes.
- `examples/game_vote_rounds.tscn`: the game vote's `time_up: finish_round` through real round ends. Smash and Prop Hunt on rounds shortened by their own cvars (`fixtures/game_vote_rounds/content.yml`), a real shell votes the other game in, the clock runs out while the match is LIVE, and the change must wait for that round's `round_ended` and follow it within three seconds. Needs `dist/tmc/smash`, `dist/tmc/prophunt` and its maps. About two minutes.
- `examples/shell_notice.tscn`: the game vote on a real shell's HUD over a real socket, menu and click included, plus clear-downloaded-content.
- `examples/party_live.tscn`: the party booking seam before and after a real `changelevel`.
- `examples/admin_loading_selftest.tscn`, `examples/admin_live.tscn`: [admin-menu.md](admin-menu.md#testing-it).

## A real client in a delivered game

Each `*_client` suite publishes a game from its sibling repository, boots a real `TmcHost`, joins a real client, and asserts the delivery path from the operator's end. The game's own suites cannot reach any of this: there its files are at `res://` and its `class_name` globals are registered. Each says "skipped" and exits 0 when its sibling is absent.

| Suite | What it adds |
| --- | --- |
| `smash_client` | a 3D game whose map is rebuilt every round from the pack; the module script is the mounted copy; client and server as two builds with different envelope kinds; a client whose game schema cannot play is disconnected with `CODE_VERSION` |
| `template_client` | a stranger's game shipped the way a stranger ships it: dot-game-template's HEAD packaged by `../dot-ci/scripts/package.sh --pack --name dot-game-template`, signed under `someone/dot-game-template@0.0.1` with a run key, stamped by `stamp_identity`, played to a scored coin. **It packages HEAD, so commit the template before believing it**; pass `--name`, or the artifact is named after the checkout directory |
| `wipeout_client` | a game whose courses are a second pack, now via `cfg/content.yml` (`examples/fixtures/wipeout/content.yml`); the client builds the same course from the STAGE document; `net_stat` at the delivered game's console reads the link's meter |
| `deathrun_client`, `prophunt_client` | the same with `server_dependencies` in the descriptor: **keep at least one suite on that back-compat path**. prophunt also reads the prop catalogue and taunts from inside the mount |
| `hideseek_client`, `lookatme_client`, `delivery_client` | the later minigames, the same way |
| `zombiezone_client` | both weapon packs on the server's catalogue (needs `addons/zed_weapons`, see [releases.md](releases.md#pending-zed_weapons)); the first map is a delivered one; the client draws the server's replicated zombies |
| `playground_client` | the family's first client `dependencies` (game-playground-maps): both catalogues list the map from the mount, the client builds every static box and the server's props |

The five games with team combat (`zombiezone`, `prophunt`, `deathrun`, `smash`, `wipeout`) also set the server's `mp_teammate_passthrough` to 2 and 0 live and assert the delivered client's `game.combat.rules` follows it (the game's client calls `combat.follow_cvars(link)`; the game's own suites only see the cvar flagged replicated).

Rules these suites taught:

- **Turn the stdin console off in a fixture.** dot-server's reader is a thread blocked in a read the engine cannot cancel; a suite that shuts the server down with stdin open leaves it destroyed unjoined (one "Thread object is being destroyed" warning).
- **A delivered client needs every addon its game links, linked and imported here.** A checkout that missed a `setup.sh` run (a new addon in the list) or an `--import` after a new `class_name` fails delivered clients in ways that look like the game's bug.
- **A suite must load the game's server scene.** A SCRIPT ERROR in a server scene no game suite loads is invisible to the game's own suites.
- **Check the exit code even when every check passed**: zombiezone's run aborted at exit (`double free or corruption`) because lambdas registered in a static registry outlive their script at engine teardown. Register static-method callables.
- Teardown prints one engine `ERROR: Condition "ready_state != STATE_OPEN"`, from dot-net sending a snapshot in the tick its peer closed. It is dot-net's.

## Arming

Every check added here is armed: the bug is put back and the check must fail, and fail alone. Several first versions passed with the bug in place (comparing two identical clips, a patched PNG failing its own checksum, a CJK name too short to cross the limit). If arming means removing a registration, remove the one the code actually consults.

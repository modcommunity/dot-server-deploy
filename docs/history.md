# History

Bug stories worth keeping because the bug could come back. The live rule from each is in [../CLAUDE.md](../CLAUDE.md) or the topic doc. This project was the first place the whole family was deployed rather than run, and the first place the browser target was actually loaded; loading it found three bugs in three repositories, each of which made the browser target impossible.

## The mount constraint

- **The fourth form was found by accident**: a const collision made somebody open an NPC script whose own comment said it extended a path rather than a class "because it is the shape an entity delivered in a dot-cloud pack must have", and the path was absolute. The intent was right and the form was not, in eleven files.
- **The sixth was found by publishing the first game that vendors art** (mg-buses-from-hell) and looking at a screenshot: crates arrived as white boxes. No suite could have seen it. See dot-cloud's [docs/history.md](../../dot-cloud/docs/history.md).
- **The seventh was found by booting a server that mounted mg-smash-copter**: the cannon fired, the prop spawned, and the prop body could not load its model. It was then written up as closed everywhere while six games still had the unguarded `rebase()`; the suite that should have caught it asserted against the real root, put the bug back, and still passed.
- **The first boot of a 3D delivered game against a real server** found four things unreachable from the game's own project: the double rebase, a combat manager set up twice, lag compensation reporting as unwired where it worked, and dot-match warning per player per round about a game that places its own players. Its two-build section found that a kick from outside an RPC handler never delivered its reason (dot-server's `_close_peer`).

## Bugs found by deploying

- **The web export shipped every imported map's textures and none of its geometry.** The `.json` manifest had a loader and went into the pack; the `.bin` did not. The browser client connected, signed on, spawned and drew sky in every direction, because the only maps anybody had loaded in a browser were built in code. `export-web` now refuses a pack missing any `.bin`.
- **dot-net: `Array.sort()` on a `StringName` sorts by interned pointer**, so two peers gave one message type two wire ids. Invisible to every suite that ran both ends in one process (one intern table). See [bugs-found.md](../../../docs/bugs-found.md).
- **dot-core: `isSecureContext` is not "the page is HTTPS".** It is true on `http://localhost`, so every development page's `ws://` was upgraded to `wss://` and failed. `DotWeb.is_https_page()` is the right question.
- **dot-server: the audit log never opened.** A `DotNodeRef` created node runs `_ready()` before `DotServer` assigns its config; the audit log took the "no path" branch and nothing opened it later. It warned on every boot, which read like an unfilled setting.
- **RPC routing: Godot addresses an RPC by the receiver's path relative to its `MultiplayerAPI` root.** Both ends now scope an API to their own subtree, so neither needs to know the other's scene names.
- **A symlinked addon dangles when the directory moves**, and every `class_name` goes unresolved at once (the reason for `--vendor`, and later for links inside the tree).
- **Godot headless still links `libfontconfig`**, so a minimal container died before running any GDScript.
- **A container running as an arbitrary uid has no passwd entry**: `$HOME` is `/`, `user://` cannot be created, and Godot crashes with signal 11 several errors later.
- **A builtin game must name no client scene**: a client that never reports loaded is timed out for idling with no hint why. `TmcContent` refuses one.
- **`./server` documented exit 6 for "port in use" and never returned it**, so a supervisor restarted it for ever against a port somebody else owned. Both launchers check now, including the RCON port (game port plus one), where two servers a port apart collide.
- **`demo.sh switch` could reach one of its five servers**: it hard-coded one port while `rcon.mjs` had always taken `--port`. It also had no way to change a map, because each game registers its own map command under its own prefix.
- **The Windows launcher was a nine-line batch file** while the README described the Bash one: every option existed on one platform only, and nothing could report it.
- **`./server check` printed `selftest ok` over a game module that never compiled** (an `--only-games` build that left `addons/dot_game` unlinked). Fixed by `TmcScriptWatch` and dot-server's `can_instantiate()` check ([testing.md](testing.md)).
- **Nothing checked the server side of a join.** A probe once saw the client in `PLAYING` and the server session in `LOADING` for ever, in one process. On current code it passes; why the old per-method RPC was lost in one process was never established. `reconnect` now waits for `SPAWNED` on the server.
- **`warn` was called twice in the launcher and defined nowhere**, so a rare warning printed `warn: command not found`.
- **The PowerShell map check asserted the opposite of the bash one's**, from when the build was meant to contain map geometry. Both call one function now.

## Lists that went stale

This project's most repeated bug is two copies of one list ([setup.md](setup.md#one-fact-one-place)).

- `setup.sh`'s games list named a repository renamed months earlier. It wiped the vendored games first, then died with "No games were found", having made that true. `check.sh`, the guard against exactly that, repeated the same list under a comment saying it must not, and printed the release-tarball "staleness not checked" line on a developer machine. Un-staling it exposed a module declaring stats through `DotStatsSchema` with `dot_stats` missing from the addon list: `changelevel` swapped the world and left the previous game's module driving it.
- The addon list went stale three times; the symptom is always dozens of "not declared in the current scope" errors in files nobody touched, which reads as a broken project rather than one missing folder.
- `content/` was one hungario mode short; `live_switch` caught it as "7 of 6" and said nothing else. It names the games now.
- `resolve_addons` spelled out the name-to-repository rule a second time without the `zee` exception, so a fresh install asked GitHub for `zee-weapons`. On a developer box the first copy always answered, so the second was never exercised.
- `tools/package_check.sh` read the addon list by the pattern `^ADDONS=(` after the array was renamed `ADDONS_ALL`, so it staged nothing and cloned every addon from GitHub. It surfaced only because three addons were not pushed yet. The same run found its pack count assuming `dist/<id>/` when packs had moved to `dist/<owner>/<name>/`.
- While games were vendored into one `game/`, one game added a `game/prop.tscn` that game-playground already had (the collision check refused the build), and a game's `content/` directory was not vendored at all, so its NPC data would have been absent in deployment. Both ended with delivery.

## Addons installed and never built

`dot_server_security` was linked and compiled against for every game and nothing constructed one; dot-log was not in the list while `cfg/log.yml` documented its settings. Then dot-party, dot-matchmaking and dot-locale arrived with suites and READMEs and no caller; then an audit found dot-replay and dot-friends constructed nowhere in the family. All are built here now ([operator-services.md](operator-services.md)). Building the guard found three bugs: a `server_ref` of `"../Server"` for a child of the server; `./server check` asserting nothing about the console; and, in dot-server-security, the guard latching the moderation store at attach and never finding it on this deployment.

## Installs on a real panel

In order, each found only after the previous was fixed ([pterodactyl.md](pterodactyl.md)): every reinstall died on git's dubious-ownership check; an install cloned a repository by a doubly-derived wrong name; a fresh install hung on a credential prompt for a repository under the wrong owner; the next filled a 100 MiB tmpfs `/tmp` and `unzip` asked what to do; the egg baked an install-time absolute path into `./server`; and the startup line used the configuration-file form of the port variable. Earlier, a box that installs its games at runtime was found cloning and publishing every game ([installing-games.md](installing-games.md#a-server-that-installs-its-games-must-build-none-of-them)).

## The admin menu and loading screen

Running them found the chat flood limit (the one design error, which no stand-in could see), `(x as PackedStringArray).append()` appending to a copy, compact durations unfit for a menu, the panel jumping width between pages (only a frame showed it), and client tests fetching real URLs. An independent review then found no injection or permission bypass and eight defects: sizes counted in characters against a byte limit; a no-flash delay that the second call defeated; a decode-size gap (a 1 MB PNG can declare 16384×16384) and private-host probing; a prefetch budget that counted failures and never reset; Back history never truncated; commands never unregistered; a category flag checked only when drawing; and `reset()` keeping the last server's game name. In a browser, the frames found the menu left open across a game change.

## Delivery packing

Writing `playground_client` found two packing bugs in `content/playground/pack.json`: `exclude_dirs: ["tools"]` also dropped the game's `game/tools/` (the tool gun broken in every delivered playground until the directory was renamed `game/toolgun/`), and the game pack followed the `maps/custom` link and shadowed the maps pack on both ends. Writing `zombiezone_client` found the first map always being the built-in practice street, a server-scene SCRIPT ERROR no game suite loaded, and an abort at exit from lambdas in a static registry.

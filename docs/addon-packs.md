# Addon releases reach players by a restart

**What this platform wants:** a fix to an addon reaches every player by a server restart; a new shell is needed only for the engine, the boot stage or security. Every addon tag is already a signed pack on the content origin (`modcommunity/<repo>@<version>`, published by the site's release sync). This is the client side that takes one. dot-cloud's [docs/addon-packs.md](../../dot-cloud/docs/addon-packs.md) has why each dot-cloud piece is shaped the way it is.

## How it works

1. `TmcHost._advertise_addons` reads `addons.lock` and puts one `{dir, repo, id, version}` per installed addon into dot-server's `addon_set`, which rides the signon challenge with `content_base_urls` (so a desktop client knows where to look).
2. The shell's `_on_server_info` asks `DotCloudAddonSet.plan_for` what is newer than this build's own `res://addons.lock` (every export carries it) and than the overlay it already runs.
3. If anything is: it leaves the server quietly, fetches the packs, builds one overlay, writes a plan naming where it was going and who was signed in, and restarts (`_restart`).
4. The main scene `client/boot.tscn` (dot-cloud's `dot_cloud_boot.gd`, which names no addon class) mounts the overlay before anything is compiled and hands over to `client/shell.tscn`.
5. The shell confirms the start, goes back to the server and joins on the newer addons.

## Rules

- **A desktop relaunch passes both halves of the command line.** `OS.get_cmdline_args()` stops at the bare `--`, and everything this shell reads is after it ([native-client.md](native-client.md#the-launch-arguments-need-the-bare---)).
- **A browser reload repeats the filesystem sync first.** The engine drops a sync requested while one runs, so the plan and overlay were lost and the page looped; a `sessionStorage` counter also stops any loop at two.
- **A signed-in browser player's stored session is restored after an update restart**, and only for the member the update recorded, because the page's sign-in code is single-use.
- **No downgrades**: an addon whose version is not newer than the build's is never taken. A server whose lock is older than a player's build leaves them on the newer one, which envelope negotiation handles.
- **An addon pack carries only its own `addons/<dir>/`.** Anything outside it (the weapons pack's art in `res://assets/`) still needs a shell.
- **An addon whose pack is not on the origin is the same as one with no release**: clients keep the build's copy.
- **Mobile cannot restart itself**: the overlay is written and applies at the next launch.
- **A client exported before this feature has no boot scene** and takes nothing; the first shell carrying it had to be exported the old way.

**One engine line is expected.** A release build logs `ERROR: Attempt to disconnect a nonexistent connection from 'Server' ... 'tree_exited'` once when it leaves a server at the challenge to update. It is the engine's multiplayer cache on an ENet peer closed straight after the first message; deferring the drop does not change it, a debug build does not print it, and the update and rejoin complete.

## The end-to-end proof

dot-cloud's own suite proves the overlay with a run key and separate processes. **The end-to-end proof, an old exported shell meeting a newer server and relaunching onto site-signed addon packs, was done from here:**

- **Desktop**: an exported Linux client whose lock said dot-ui v0.1.4 and dot-audio v0.1.2, against a local `./server` on a newer lock, fetched `modcommunity/dot-ui@0.1.5` and `dot-audio@0.1.3` from the production origin, relaunched, mounted the overlay (2 addons, 29 uids), passed the "the overlay copy is what runs" probe, rejoined by itself and spawned in the arena match.
- **Browser**: the same build in headless Chromium against a local mirror of the two packs: page 1 updated and reloaded, page 2 mounted, confirmed and rejoined, in exactly two loads. A local page cannot fetch game content from the CDN (CORS), so the browser run stops at content sync; that is the known local limit.

Running it found: the launcher in use was the old generated `./server` (regenerate after editing `tools/server.in`); a desktop relaunch lost `--connect`; the browser reload loop above; a signed-in player returning as a guest. All fixed.

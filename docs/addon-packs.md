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
- **A browser reloads only once IndexedDB holds what the next load reads**: the plan, the overlay and, for a member, the stored session (`_restart(keep)` over dot-cloud's `DotCloudAddonSet.persisted`). One `FS.syncfs` takes seconds and grows with the player's cache, and a reload inside one loses it: the old fixed three-second wait reloaded 2.9 s after the plan was written and came back without it, re-downloaded, restarted again, and joined on the old addons as a guest at the third load. If the files are not there within `PERSIST_TIMEOUT_SEC` (60 s) the shell does not reload, joins on the build's addons and leaves the update for the next start. A `sessionStorage` counter also stops any loop at two.
- **A signed-in browser player's stored session is restored after an update restart**, and only for the member the update recorded, because the page's sign-in code is single-use: the site's loader posts the same, now spent, code to the reloaded frame. That depends on the plan (which records the member) and the token store surviving the reload, which is why both are in what the restart waits for.
- **The server box shows where the start is going before sign-in is awaited**, from the page's `?server=` or the plan, so it no longer shows the placeholder for the length of a refused redeem and a restore.
- **No downgrades**: an addon whose version is not newer than the build's is never taken. A server whose lock is older than a player's build leaves them on the newer one, which envelope negotiation handles.
- **An addon pack carries only its own `addons/<dir>/`.** Anything outside it (the weapons pack's art in `res://assets/`) still needs a shell.
- **An addon whose pack is not on the origin is the same as one with no release**: clients keep the build's copy.
- **Mobile cannot restart itself**: the overlay is written and applies at the next launch.
- **A client exported before this feature has no boot scene** and takes nothing; the first shell carrying it had to be exported the old way.

**One engine line is expected.** A release build logs `ERROR: Attempt to disconnect a nonexistent connection from 'Server' ... 'tree_exited'` once when it leaves a server at the challenge to update. It is the engine's multiplayer cache on an ENet peer closed straight after the first message; deferring the drop does not change it, a debug build does not print it, and the update and rejoin complete.

## Whose packs may replace the build's addons

`ADDON_NAMESPACES` in `client/shell.gd` (`modcommunity/` and two first-party packs) is the `namespaces` list `DotCloudAddonSet.plan_for` takes an overlay from. It decides only whose pack may **replace** the shell's own `addons/<dir>`, which then runs for every game the shell plays, from the boot scene, before sign-in. That is shell code, so it stays first-party.

It is not what a creator needs. A pack a server owner adds (`cfg/content/addons.yml`, `defaults: add:`) arrives as `content_extra`, is mounted under `res://dot_cloud/<id>/<version>/`, and its `entry` scene is started by `TmcAddonEntry` on the `side` its signed manifest names, with no namespace check: a creator's approved, signed pack already runs in the browser without the shell trusting its owner. Proven on dev with `sp-creator/probe` (`an extra pack started ... side=client`).

If a creator ever needs to replace a shared addon itself, the options are:

- **(a) The site's signed index names the owner of each addon dir.** The site already approves claims per owner; it would sign a `{dir: owner}` list (as it signs packs), and the shell would take an overlay for `addons/<dir>` only from that dir's approved owner. No owner could replace another's addon, and approving a claim stays the one gate. This is the right shape if it is ever wanted.
- **(b) Per-player opt-in** to a third-party overlay. It moves the trust decision onto players, who cannot judge shell code.
- **(c) Keep the first-party list** (current). Nothing a creator ships today needs it.

Deriving the list from the pack's own manifest is not an option: the pack would vouch for itself, so any approved creator could replace any addon by naming its dir.

## The end-to-end proof

dot-cloud's own suite proves the overlay with a run key and separate processes. **The end-to-end proof, an old exported shell meeting a newer server and relaunching onto site-signed addon packs, was done from here:**

- **Desktop**: an exported Linux client whose lock said dot-ui v0.1.4 and dot-audio v0.1.2, against a local `./server` on a newer lock, fetched `modcommunity/dot-ui@0.1.5` and `dot-audio@0.1.3` from the production origin, relaunched, mounted the overlay (2 addons, 29 uids), passed the "the overlay copy is what runs" probe, rejoined by itself and spawned in the arena match.
- **Browser**: the same build in headless Chromium against a local mirror of the two packs: page 1 updated and reloaded, page 2 mounted, confirmed and rejoined, in exactly two loads. A local page cannot fetch game content from the CDN (CORS), so the browser run stops at content sync; that is the known local limit.

Running it found: the launcher in use was the old generated `./server` (regenerate after editing `tools/server.in`); a desktop relaunch lost `--connect`; the browser reload loop above; a signed-in player returning as a guest. All fixed.

**The browser check, `tools/browser_update_check.mjs`.** Export the Web preset from a doctored, older `addons.lock` into a scratch directory (put the lock back), copy `web/embed.html` and dot-audio's `dot_audio_ceiling.js` beside it, start a local `./server run --content-url http://127.0.0.1:8099/content`, and run `node tools/browser_update_check.mjs --build <dir> --server ws://127.0.0.1:<port>`. It serves the build under a host page that hands the frame a single-use sign-in code on every `tmc.auth.ready` (as the site's loader does), a mock redeem endpoint that accepts it once, and `/content` proxied to the CDN. It asserts exactly two loads, the overlay mounted at boot on load 2 with the versions load 1 built, no addon pack downloaded on load 2, the same member signed in on both loads with one accepted redeem, and a join. Armed: a shell from the previous `client/shell.gd` and dot-cloud fails 6 of 8 (three loads, a guest on load 2) on every run; the fix passes 8 of 8.

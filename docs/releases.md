# Releases: the lock, the shells and the order

**For**: whoever releases an addon, a game or the web shell. **Quick start** (an addon):

```bash
git -C ../dot-vote tag v0.2.1 && git -C ../dot-vote push origin v0.2.1   # 1. tag the addon
tools/addons-lock.sh write                                               # 2. lock it here (check the pack is on the origin first)
git add addons.lock && git commit -m "Lock dot-vote v0.2.1" && git push  # 3. the web-shell workflow does the rest
```

**Never** export, upload or pin a web shell by hand while the workflow is up; the order for a game is in the table below.


This repository is where an addon release, a game release and a shell release meet. The family's release checklist is in the `release-rules` memory; this is what the code here enforces and why.

## The release orders

| Releasing | Order |
| --- | --- |
| an addon | tag the addon → the site publishes its pack (hourly, or "Pull now") → bump `addons.lock` here (`tools/addons-lock.sh write`) and push → restart the servers |
| a game | tag every addon it needs → lock them here and push → wait for the web-shell workflow's tag → tag the game |
| a new shell | nothing by hand: push the lock (or the `client/` change) and the web-shell workflow exports, uploads, pins and tags ([below](#publishing-the-web-build)) |

- **Push the lock only after the packs are on the origin.** A client that cannot fetch an addon pack joins on its own addons and does not retry that server this session. Check with `curl <origin>/<owner>/<repo>/<version>/manifest.json`.
- **Each skipped step in the game order fails in CI**, not on a box: this repository's CI parses every script against `addons.lock` at the locked refs (dot-ci resolves a project that has a lock from the lock), and a game's release refuses a pack no released dot-server-deploy can run (dot-ci `scripts/server-compat.sh`).
- **Publish content before the build that needs it.** A build published without its packs is a client that can mount no game; in the other order every player on the new build is briefly on a client that can reach nothing.

## What needs a new shell

An addon release reaches players by a server restart ([addon-packs.md](addon-packs.md)). A new shell (web and native) is still needed for:

- the engine version;
- the boot stage (`client/boot.tscn`, dot-cloud's `dot_cloud_boot.gd`);
- the shell's own `client/` code (the admin menu, loading screen, notice overlay, party and friends UI);
- a dot-server signon revision change (an older shell is refused with "This server needs a different build of the game client");
- an addon release that adds or changes files outside its own `addons/<dir>/` (the weapons pack's art is in `res://assets/`).
- a change to the page the engine runs in (`web/embed.html`, or an addon's page script such as dot-audio's `web/dot_audio_ceiling.js`, which `export-web` copies beside the build): an overlay lays files under `res://`, never next to `index.html`.

An older shell ignores notice topics and `data` it does not know, so a server ahead of the shell degrades rather than breaks for the HUD features; the signon revision is the hard line.

## `addons.lock`

`addons.lock` names a ref (a release tag) per addon repository. `setup.sh` clones at it and moves its own clones there on `--update`, which the egg passes on every reinstall. Before the lock, every install took each addon's `main` on the day while the shells were exported whenever, and a server ahead of the shell refused the join.

- **Only what `setup.sh` owns is ever moved**: a fresh clone, or a clone under `addons/.repos/`. A developer's sibling checkout or a shared `--addons-dir` is never detached onto a tag. On a developer box the lock is a statement, not an action.
- **`tools/addons-lock.sh check` before `./server export-web` or `export-native`**: a shell exported from a tree that is not at the lock is a shell no locked server matches. Check against the tags, not only the sibling checkouts, which are usually ahead.
- `tools/addons-lock.sh write` re-locks every repository to its newest `v*` tag (by `sort -V`, not by date), `write v0.1.3` to one tag, and **refuses to write a lock with a hole in it**: a missing entry would install that addon at `main`. `TMC_ADDONS_LOCK=off` restores the old behaviour.
- **Compare commits, not tag names.** A tag can be re-pointed after it is cut, and an annotated tag lists twice in `ls-remote` (the tag object, then `^{}`), so `check` peels to the commit.

## A game that needs newer addons

A box's addons used to move only when somebody reinstalled, so a game released against a newer addon API level installed on restart and then refused to boot.

- **`install-games` will not install a pack the addons cannot run** and exits 4 (`EXIT_ADDONS_BEHIND`) ([installing-games.md](installing-games.md#rules-of-the-installer)).
- **On 4 the launcher updates itself and runs again, once** (`self_update` / `update_and_restart` in `tools/server.in`): fetch this checkout's branch and reset to it, `setup.sh --no-games --update`, then `exec ./server` with the original arguments and `TMC_AUTO_UPDATED=1` so a lock that still cannot run the game does not loop.
- **`TMC_AUTO_UPDATE` / `--auto-update`** (the egg's "Update addons automatically"): `when-needed` (default) also updates on start when what the channel follows has moved (`lock_moved`: one shallow fetch): **any new commit of the host itself**, or the lock or `web/shell-build` (before 2026-10-15 a shell pinned without a lock bump reached no box; before 2026-10-25 a fix under `host/` that changed neither reached no box on restart); `always` updates every start; `never` does not.
- **`TMC_CHANNEL` / `--channel`** (the egg's "Update channel"): `latest` (default, what every box did before the setting) follows the branch head; `stable` (also written `@stable`) follows the newest `v*` tag of the host (`sort -V`), reset onto the tag with the branch name kept, and the addons follow that tag's `addons.lock`, whose entries are release tags. Commits after the newest tag are not a move on `stable`; a box with no release tag stays where it is. The pinned-shell gate applies to both. It is read by the launcher, so **a box installed before 2026-10-25 needs one reinstall** to get both this and the host-commit trigger: its old `./server` has neither. Checked by `tools/check_channels.sh`.
- It resets only a deployment (a shallow clone, or a checkout whose HEAD origin already contains), and needs `git` in the runtime. **Local changes no longer stop it**: file modes are ignored (`core.fileMode false`), the built-in `content/` descriptors the panel installer prunes are put back, and any other edit to a tracked file is set aside with `git stash` and listed in the log. The same goes for the addon clones under `addons/.repos/` on `setup.sh --update`, where untracked files never count. Before 2026-10-14 a dirty checkout made every panel box refuse its own update, silently, so no box moved past the addons it was installed with ([history](history.md)). Any remaining reason not to (no git, a developer's own commits, no network) means "start on what you have" and is printed.

## `sv_web_build`, `sv_web_requires` and `web/shell-build`

**A server uses the site's newest compatible shell by default, and moves to a new one with no update and no restart.** `sv_web_build` is a NOTIFY cvar registered on every server and EMPTY unless the operator pins a build: the pin is a decision (a server deliberately held on an older shell), so it comes from the layered config like `sv_web_loader`: `sv_web_build` in `cfg/server/server.yml`, `--web-build`, `TMC_WEB_BUILD` (the egg's "Web shell build (pin)"), or `sv_web_build <id>` over rcon. It is a config field (`TmcConfig.web_build`), not a console line ([configuration.md](configuration.md#the-configuration-is-a-surface-not-a-second-parser)). A value that is not one path segment is warned about and reported empty. `./server check` asserts the cvar is NOTIFY and equals the configured pin.

- **Why it changed**: the cvar used to report the tracked `web/shell-build` for every server, so a server pinned whatever shell its checkout shipped and needed an update plus a restart to move, while the site had already published a newer one.
- **`sv_web_requires`** is the other half: a NOTIFY cvar holding compact JSON of the addon API levels the loaded game's pack needs (`{"dot_net":3}`, the highest per addon over the game's pack and its dependencies, read from each mounted pack's `requires.json`, dot-cloud [mounting.md](../../dot-cloud/docs/mounting.md)). Empty when the pack has none. The host republishes it each time a game loads. The site picks the newest ACTIVE shell whose API levels satisfy it.
- **The site honours a pin only for a build it has a row for** (website-city `WebGameBuild`, Admin → Game) that is ACTIVE or DEPRECATED; a DISABLED or unknown pin falls back to the automatic choice. The admin panel lists pins with no row under "Pins being ignored".
- **`web/shell-build` is only the checkout's record** of the shell exported from its `addons.lock`; the web-shell workflow still writes it, and auto-update still waits for it to be pinned before adopting a new lock. No server reads it as a pin. `web/shell-build.inputs` says which tree it was exported from: `lock` (sha256 of `addons.lock`) and `inputs` (sha256 over the lock, the tracked `client/`, `project.godot`, `export_presets.example.cfg`, `web/embed.html` and the engine pin; `tools/shell-inputs.sh paths`).
- **How a build is registered**: the site's `web-build-register` job (every minute) registers a build from `game/<app>/latest.json` (written by `publish-web-shell.sh --pin`) or one a server reports as `sv_web_build`, once its entry answers on the content origin. A shell is therefore registered within a minute of publishing, with no server involved.
- **The shell's API levels** are written by `export-web` into the build as `shell-api.json` (`{"dot_net":{"level":3,"oldest":1},...}`), which the site reads at registration to answer "does this shell satisfy this game".
- **The site caches the release list for 60 s**: after changing a build's status or a server's pin, wait a minute before testing what a launch resolves.

### Proving it on the dev site (games.tmcdev.net)

The route that was run end to end on 2026-10-31; everything here is dev only.

1. **A shell with its API**: `heavy -- tools/dev-shell.sh --backbone https://games.tmcdev.net`. It regenerates a stale `./server` (an old one exports no `shell-api.json`), and `dev-shell-publish.sh` registers the row with `api` filled from `web/build/shell-api.json`.
2. **The loader**: the dev site's shared loader must be the current `web/tmc-loader.js`, or Play solo opens the connect form (only its `soloParams()` passes `?solo=` to the shell). POST it as in "The shared loader publishes itself" below, with a dev key from the dev site's Admin → Game; the launch answer's `loaderUrl` then names `loaders/git-<sha>`.
3. **Solo**: website-city's `prisma/seeds/dev-games.ts` (`seedSolo`) gives app 101 a `contentAssetId` and `directPlay`. Play solo on `/arena` frames the newest ACTIVE shell with "Playing solo, with no server" and it starts the game pack (`solo game started`): on a GPU box's Chrome the 0844 shell played `gamemann/game-arena@0.1.33` against bots. A headless browser under `heavy`'s 1 GB cap runs out of memory before the game starts, so do this on a GPU box.
4. **The pin**: a server's `sv_web_build` reaches the site as a `ServerVar` row. The dev site has no worker, so set the row by hand. Then `POST /api/app/v1/play/launch {"appId":N,"mode":"web","serverId":S}` answers `boot.game.build`: the pin for an ACTIVE or DEPRECATED row, the newest ACTIVE for a DISABLED pin or none.
5. **A creator's pack on a server**: publish with `dot-cloud/tools/publish_pack.sh --site https://games.tmcdev.net --id <repo> --meta entry=entry.tscn --meta side=both` and a `licence.json` at the source root. A creator's first release is HELD until approved. List it under `defaults: add:` in the server's `cfg/content/addons.yml` and restart. The console then says `an extra pack started`, and a browser that joins logs the same line with `side=client`: an extra pack's entry is started by `TmcAddonEntry` from its signed manifest, whatever its owner (`ADDON_NAMESPACES` gates only overlays that replace the build's addons, see [addon-packs.md](addon-packs.md#whose-packs-may-replace-the-builds-addons)). Both the unpinned and the pinned shell joined game-playground this way and showed the creator pack's label in game. A scripted browser join needs a GPU box: `tmcdev.net` resolves to a private address, so Chrome blocks the WebSocket from the public `dev.dotgames.org` page (`ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS`) and refuses the dev CA. Start Chrome there with `--ignore-certificate-errors --disable-features=LocalNetworkAccessChecks,LocalNetworkAccessChecksWebSockets,BlockInsecurePrivateNetworkRequests` and a `--remote-debugging-port`, tunnel the port, and drive it with Playwright's `connectOverCDP`.

## `sv_web_loader`

Names a version of the site's shared web game loader (the JavaScript that frames the shell). The site serves the newest active loader by default; a server reporting `sv_web_loader <version>` gets that one while it is not disabled. It can hold a server back but never turn a launch into an error.

- **It is the operator's decision**, like `sv_web_build`, so it comes from the layered config: `sv_web_loader` in `cfg/server/server.yml`, `--web-loader`, `TMC_WEB_LOADER`. It is a config field (`TmcConfig.web_loader`), not a console line ([configuration.md](configuration.md#the-configuration-is-a-surface-not-a-second-parser)).
- `TmcHost._register_web_loader` always registers the NOTIFY cvar, empty unless configured, so it can be set over rcon. A value that is not one path segment is warned about and reported empty. `./server check` asserts it.
- **The desktop client has no equivalent yet**: it installs one build per platform, so a server ahead of or behind it is refused at signon.

## Publishing the web build

**The web-shell workflow does it** (`.github/workflows/web-shell.yml`). Nobody exports, uploads, pins or registers a shell by hand:

1. A push to `main` that touches a shell input (`addons.lock`, `client/`, `project.godot`, the presets, `web/embed.html`, the engine pin) starts it. It checks out `main` and compares `tools/shell-inputs.sh print` with `web/shell-build.inputs`; equal means the pinned shell is this tree's and it stops.
2. Otherwise: `./setup.sh --no-games` (fresh addon clones at the lock, so `tools/addons-lock.sh check` passes), `client/auth.json` from the `WEB_SHELL_BACKBONE_URL` variable, `./server export-web --zip`. The export writes `shell-inputs.txt` into the build: the fingerprint, plus `addons off-lock` when the linked addons are not at the lock.
3. `tools/publish-web-shell.sh --pin` uploads it to `game/<app>/<build id>/` in the bucket (brotli, one content type per file, immutable), reads the entry and `shell-inputs.txt` back through `WEB_SHELL_ORIGIN`, writes `web/shell-build` and `web/shell-build.inputs`, commits "Pin the web shell <id>", tags the next `v0.1.x` and pushes both in one atomic push (rejected because somebody pushed meanwhile: it replays the pin on origin and retries with the next tag, unless origin changed a shell input, when it stops and that push's run builds). It refuses a build whose record is off-lock or is not this checkout's (a lock pulled between export and pin).
4. It dispatches `release.yml` on that tag (and a later run that finds a matching record but no `v*` tag at or after the pin commit tags main and dispatches it, so a pin is never left unreleased), because a push made with the workflow's own token starts no workflow. The pin commit touches no input, so nothing loops; runs queue one deep and the next one finds the record matching.
5. Servers on `TMC_AUTO_UPDATE=when-needed` move on their next start, and the site registers the build itself (below): from `game/<app>/latest.json`, or when the first server reports it.

**A shell no server runs is registered from a pointer.** With `--pin`, after the upload is read back, `publish-web-shell.sh` writes `game/<app>/latest.json` (`{build, entry, notes, lock}`; `lock` is the sha256 of the build's `shell-inputs.txt`; short cache, same bucket and credentials) and the site's `web-build-register` job reads it every minute: when `build` is newer than the app's newest registered build, matches the publish timestamp shape and its entry answers on the origin, it writes the `WebGameBuild` row (notes say `manifest`), so solo play stops serving the previous shell. A malformed pointer is logged and ignored; the server-reported path is unchanged. `--manifest-only` prints the pointer; `tools/check_publish_manifest.sh` tests its shape (part of `tools/check.sh`).

**The shared loader publishes itself too.** `web/tmc-loader.js` is not part of the shell: the site serves it to every page that frames one. The workflow's `loader` job POSTs it to the site's `/api/app/v1/web/loader` on every run, labelled `git-<12 hex>` after the last commit that touched the file. The site answers a label it already has with the same bytes as "unchanged" (HTTP 200) and writes nothing, so posting on every run is what makes an overtaken run or a manual dispatch unable to lose a loader change; a label it has with different bytes is refused (409). It needs the secret `TMC_LOADER_PUBLISH_KEY`, issued in the site's admin panel (Admin → Game → **Loader publish key**: generate, copy once, `gh secret set TMC_LOADER_PUBLISH_KEY --repo modcommunity/dot-server-deploy`). That key opens only this endpoint and acts as nobody; rotating it in the panel stops the old one at once. Unset, the job skips with a notice and the loader is uploaded by hand as before ([web/README.md](../web/README.md#letting-the-site-publish-it)). A non-2xx fails the job and prints the site's answer. **Disable a bad version in the panel rather than deleting it**: deleting frees its label, and the next run publishes the same bytes again.

**What it needs** (repository settings → Secrets and variables → Actions): secrets `GAMES_S3_ACCESS_KEY`, `GAMES_S3_ACCESS_SECRET`, `GAMES_S3_BUCKET` and optionally `GAMES_S3_REGION` (default `us-east-1`); variables `WEB_SHELL_BACKBONE_URL` (what `client/auth.json` names; the first-party server list is not a variable, the shell asks the site), `WEB_SHELL_ORIGIN` (the content origin whose `/<app>/<build>/` is the bucket's `game/<app>/<build>/`) and optionally `WEB_SHELL_APP` (default `godot`). For the loader job: secret `TMC_LOADER_PUBLISH_KEY` and optionally the variable `TMC_SITE_URL` (the site to publish to, default `WEB_SHELL_BACKBONE_URL`); both are optional and skip with a notice. Workflow permissions must allow `GITHUB_TOKEN` to write, and nothing may block it from pushing to `main` or creating `v*` tags. `DOT_DEPS_TOKEN` is used for the addon clones when set. A missing setting fails the run by name before anything is built. `workflow_dispatch` with `force` re-exports when the record matches (a new backbone URL, a broken upload).

**No release goes out with a shell that is not its own.** `release.yml`'s `shell-pin` job refuses a tag whose tree does not match `web/shell-build.inputs`, and, with `WEB_SHELL_ORIGIN` set, whose build on the origin carries a different record. dot-ci's `server-compat.sh`, which every game release runs against the newest dot-server-deploy tag, skips a tag whose recorded lock hash is not its lock's, so a game can only be released against a lock whose shell is live. And `./server`'s auto-update does not adopt a lock pushed on the branch until its shell is pinned (`lock_moved`), so a box never serves new addons to players framed in the old shell. **Do not tag a lock bump by hand**; push it and release the workflow's tag.

**By hand, the fallback** (the workflow is down, or a box that is not CI). **It needs a checkout whose addons are exactly at the lock**: a developer box's `addons/` links sibling checkouts, usually ahead of their tags, and `export-web` marks such a build off-lock, which `--pin` refuses. Use a separate clone set up with `./setup.sh --no-games` (its own clones, at the lock), or check every sibling out at its locked tag. Then: `tools/addons-lock.sh check` (must pass), `./server export-web --zip`, then `tools/publish-web-shell.sh --zip web/build.zip --pin --app godot --origin <origin> --env <file with GAMES_S3_*>`. On the developer box `~/godot/deploy-web-shell.sh` is a wrapper that runs this with the `.env` beside it. `--dry-run` uploads nothing, `--no-push` commits and tags without pushing. `--wait-registered [SEC]` then polls read-only until the origin serves the build (and, with `SHELL_REGISTERED_URL`, a page lists it), exiting 1 with what is missing. The site registers a build itself (the `web-build-register` cron job, every minute) from a game server's `sv_web_build` or, for a `--pin` publish, from `latest.json`, so a pinned shell goes live within a minute or two without a server.

`./server export-web` writes `web/build/` and **publishes nothing**. An export that was never published is indistinguishable from a fix that did not work, because the browser runs the previous build and prints the previous errors byte for byte. There are three deployment shapes and they publish differently; [web/README.md](../web/README.md) opens with the table and a ten-second check for which shape you are on. Check the deployed bytes before believing any conclusion about client behaviour.

**`export-web` refuses to finish if any imported map's `.bin` geometry is missing from the pack.** The Web preset exports `all_resources`, which carries the `.json` manifest (Godot has a JSON loader) and not the `.bin` (nothing loads it); `include_filter` is the only thing that carries it. The bash and PowerShell launchers share one check.

**The presets exclude `cfg/*` on purpose, and that also drops `cfg/addons/**`.** Godot 4.7.2 lets `exclude_filter` win over `include_filter`, and `*` matches `/`, so the `include_filter` entry `cfg/addons/*` ships nothing here. That is the decision: the shell is not a game and has no `cfg/addons/` of its own (`cfg/` holds the operator's secrets, `rcon.yml` and `auth.yml`, and narrowing the exclude would risk shipping one), so the exclude stays whole. Games ship their own addon defaults in their own exports. The `dot-ci` filter check prints a WARN (not a failure) for this exclude, which is expected here.

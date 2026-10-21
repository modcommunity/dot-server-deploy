# Releases: the lock, the shells and the order

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
- **`TMC_AUTO_UPDATE` / `--auto-update`** (the egg's "Update addons automatically"): `when-needed` (default) also updates on start when the lock or `web/shell-build` on the branch has moved (`lock_moved`: one shallow fetch; before 2026-10-15 a shell pinned without a lock bump reached no box); `always` updates every start; `never` does not.
- It resets only a deployment (a shallow clone, or a checkout whose HEAD origin already contains), and needs `git` in the runtime. **Local changes no longer stop it**: file modes are ignored (`core.fileMode false`), the built-in `content/` descriptors the panel installer prunes are put back, and any other edit to a tracked file is set aside with `git stash` and listed in the log. The same goes for the addon clones under `addons/.repos/` on `setup.sh --update`, where untracked files never count. Before 2026-10-14 a dirty checkout made every panel box refuse its own update, silently, so no box moved past the addons it was installed with ([history](history.md)). Any remaining reason not to (no git, a developer's own commits, no network) means "start on what you have" and is printed.

## `web/shell-build` and `sv_web_build`

`web/shell-build` is one line: the build id of the web shell exported from this checkout's `addons.lock`. `TmcHost._register_web_build` reports it as the NOTIFY cvar `sv_web_build`; the site reads it from the query rules and frames that build for any launch into this server. A server that reports nothing gets the site's shared build.

- **Why**: one shared shell broke one side of every addon release, because servers are reinstalled on their owners' schedule while the shared build is switched on ours.
- **The site honours a pin only for a build it has a row for** (website-city `WebGameBuild`, Admin → Game) and that row is not disabled; otherwise the players get the shared build, which is the wrong shell for this server's addons. A row also keeps the build out of the site's prune. The admin panel lists pins with no row under "Pins being ignored".
- **The site writes that row itself**: its `web-build-register` job (every minute) registers any build id a server reports as `sv_web_build` once the build's entry answers on the content origin under the engine app's folder. So a pinned build is registered within a minute of the first server restarting onto it, and the INSERT `tools/publish-web-shell.sh` prints is only for a site where that job is switched off.
- **`web/shell-build.inputs` says which tree the pinned build was exported from**: `lock` (sha256 of `addons.lock`) and `inputs` (sha256 over the lock, the tracked `client/`, `project.godot`, `export_presets.example.cfg`, `web/embed.html` and the engine pin; `tools/shell-inputs.sh paths`). It is written only when a build is pinned, from the record `export-web` put inside that build.
- **It is a tracked file, not an operator setting**, because it is a fact about the checkout. `./server check` fails if the cvar is missing or not NOTIFY.

## `sv_web_loader`

Names a version of the site's shared web game loader (the JavaScript that frames the shell). The site serves the newest active loader by default; a server reporting `sv_web_loader <version>` gets that one while it is not disabled. It can hold a server back but never turn a launch into an error.

- **It is the operator's decision**, unlike `sv_web_build`, so it comes from the layered config: `sv_web_loader` in `cfg/server.yml`, `--web-loader`, `TMC_WEB_LOADER`. It is a config field (`TmcConfig.web_loader`), not a console line ([configuration.md](configuration.md#the-configuration-is-a-surface-not-a-second-parser)).
- `TmcHost._register_web_loader` always registers the NOTIFY cvar, empty unless configured, so it can be set over rcon. A value that is not one path segment is warned about and reported empty. `./server check` asserts it.
- **The desktop client has no equivalent yet**: it installs one build per platform, so a server ahead of or behind it is refused at signon.

## Publishing the web build

**The web-shell workflow does it** (`.github/workflows/web-shell.yml`). Nobody exports, uploads, pins or registers a shell by hand:

1. A push to `main` that touches a shell input (`addons.lock`, `client/`, `project.godot`, the presets, `web/embed.html`, the engine pin) starts it. It checks out `main` and compares `tools/shell-inputs.sh print` with `web/shell-build.inputs`; equal means the pinned shell is this tree's and it stops.
2. Otherwise: `./setup.sh --no-games` (fresh addon clones at the lock, so `tools/addons-lock.sh check` passes), `client/auth.json` from the `WEB_SHELL_BACKBONE_URL` variable, `./server export-web --zip`. The export writes `shell-inputs.txt` into the build: the fingerprint, plus `addons off-lock` when the linked addons are not at the lock.
3. `tools/publish-web-shell.sh --pin` uploads it to `game/<app>/<build id>/` in the bucket (brotli, one content type per file, immutable), reads the entry and `shell-inputs.txt` back through `WEB_SHELL_ORIGIN`, writes `web/shell-build` and `web/shell-build.inputs`, commits "Pin the web shell <id>", tags the next `v0.1.x` and pushes both in one atomic push (rejected because somebody pushed meanwhile: it replays the pin on origin and retries with the next tag, unless origin changed a shell input, when it stops and that push's run builds). It refuses a build whose record is off-lock or is not this checkout's (a lock pulled between export and pin).
4. It dispatches `release.yml` on that tag (and a later run that finds a matching record but no `v*` tag at or after the pin commit tags main and dispatches it, so a pin is never left unreleased), because a push made with the workflow's own token starts no workflow. The pin commit touches no input, so nothing loops; runs queue one deep and the next one finds the record matching.
5. Servers on `TMC_AUTO_UPDATE=when-needed` move on their next start, and the site registers the build when the first one reports it (above).

**The shared loader publishes itself too.** `web/tmc-loader.js` is not part of the shell: the site serves it to every page that frames one. The workflow's `loader` job POSTs it to the site's `/api/app/v1/web/loader` on every run, labelled `git-<12 hex>` after the last commit that touched the file. The site answers a label it already has with the same bytes as "unchanged" (HTTP 200) and writes nothing, so posting on every run is what makes an overtaken run or a manual dispatch unable to lose a loader change; a label it has with different bytes is refused (409). It needs the secret `TMC_LOADER_PUBLISH_KEY`, issued in the site's admin panel (Admin → Game → **Loader publish key**: generate, copy once, `gh secret set TMC_LOADER_PUBLISH_KEY --repo modcommunity/dot-server-deploy`). That key opens only this endpoint and acts as nobody; rotating it in the panel stops the old one at once. Unset, the job skips with a notice and the loader is uploaded by hand as before ([web/README.md](../web/README.md#letting-the-site-publish-it-instead)). A non-2xx fails the job and prints the site's answer. **Disable a bad version in the panel rather than deleting it**: deleting frees its label, and the next run publishes the same bytes again.

**What it needs** (repository settings → Secrets and variables → Actions): secrets `GAMES_S3_ACCESS_KEY`, `GAMES_S3_ACCESS_SECRET`, `GAMES_S3_BUCKET` and optionally `GAMES_S3_REGION` (default `us-east-1`); variables `WEB_SHELL_BACKBONE_URL` (what `client/auth.json` names), `WEB_SHELL_ORIGIN` (the content origin whose `/<app>/<build>/` is the bucket's `game/<app>/<build>/`) and optionally `WEB_SHELL_APP` (default `godot`). For the loader job: secret `TMC_LOADER_PUBLISH_KEY` and optionally the variable `TMC_SITE_URL` (the site to publish to, default `WEB_SHELL_BACKBONE_URL`); both are optional and skip with a notice. Workflow permissions must allow `GITHUB_TOKEN` to write, and nothing may block it from pushing to `main` or creating `v*` tags. `DOT_DEPS_TOKEN` is used for the addon clones when set. A missing setting fails the run by name before anything is built. `workflow_dispatch` with `force` re-exports when the record matches (a new backbone URL, a broken upload).

**No release goes out with a shell that is not its own.** `release.yml`'s `shell-pin` job refuses a tag whose tree does not match `web/shell-build.inputs`, and, with `WEB_SHELL_ORIGIN` set, whose build on the origin carries a different record. dot-ci's `server-compat.sh`, which every game release runs against the newest dot-server-deploy tag, skips a tag whose recorded lock hash is not its lock's, so a game can only be released against a lock whose shell is live. And `./server`'s auto-update does not adopt a lock pushed on the branch until its shell is pinned (`lock_moved`), so a box never serves new addons to players framed in the old shell. **Do not tag a lock bump by hand**; push it and release the workflow's tag.

**By hand, the fallback** (the workflow is down, or a box that is not CI). **It needs a checkout whose addons are exactly at the lock**: a developer box's `addons/` links sibling checkouts, usually ahead of their tags, and `export-web` marks such a build off-lock, which `--pin` refuses. Use a separate clone set up with `./setup.sh --no-games` (its own clones, at the lock), or check every sibling out at its locked tag. Then: `tools/addons-lock.sh check` (must pass), `./server export-web --zip`, then `tools/publish-web-shell.sh --zip web/build.zip --pin --app godot --origin <origin> --env <file with GAMES_S3_*>`. On the developer box `~/godot/deploy-web-shell.sh` is a wrapper that runs this with the `.env` beside it. `--dry-run` uploads nothing, `--no-push` commits and tags without pushing.

`./server export-web` writes `web/build/` and **publishes nothing**. An export that was never published is indistinguishable from a fix that did not work, because the browser runs the previous build and prints the previous errors byte for byte. There are three deployment shapes and they publish differently; [web/README.md](../web/README.md) opens with the table and a ten-second check for which shape you are on. Check the deployed bytes before believing any conclusion about client behaviour.

**`export-web` refuses to finish if any imported map's `.bin` geometry is missing from the pack.** The Web preset exports `all_resources`, which carries the `.json` manifest (Godot has a JSON loader) and not the `.bin` (nothing loads it); `include_filter` is the only thing that carries it. The bash and PowerShell launchers share one check.

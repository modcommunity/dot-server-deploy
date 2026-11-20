# Dot to GS (Gamespice) rename plan

The owner's order (2026-11-16): every "Dot"/"dot" becomes **GS** or **Gamespice**. This plan covers the identifiers. Text that players and admins see is phase 1 and is handled separately.

**What must not happen:**

- No 0.1.x pack already on the content origin may stop mounting.
- No deployed server may stop booting because a name changed under it.

Every rename below therefore goes in one of three ways:

- **Display only.** The new name is printed and the old one still works. Example: log channels.
- **New name plus a shim.** The old name keeps working for 0.1.x packs and old configs.
- **Deferred to 0.2.** These are names baked into published packs, which can only change when 0.1.x packs stop being served.

## Already done

- **GitHub repos** already live in `gamespice-platform/<name-without-dot->` (addons) and `zees-games/...` (games). GitHub redirects the old URLs. Nightly item `gamespice-rename-1` has the history.
- **Pack ids** use the `gamespice-platform/<name>` namespace. `modcommunity/dot-<name>` stays a mirrored alias (`TmcAddonNamespaces` in `client/tmc_addon_namespaces.gd`, and website-city `RetiredPackId.mirror`). Keep the alias for as long as any 0.1.x server announces old ids.
- **Log channels (GameSpice Core API 36).** `DotLog.display_channel` prints and ships a legacy `dot.`/`dot_`/`dot-` channel as `gs.`/`gs_`/`gs-`, in console lines, JSON and every GameSpice Log sink. `set_channel_level` and GameSpice Log gate patterns accept either spelling, and records keep the caller's channel. A source `CHANNEL` constant can therefore move to `gs.*` at any time without breaking a selftest or an operator's filter.

## Phase 2, in order

Each step is one repo at a time, on its own branch, with that repo's suites green, pushed ff-only. Nothing is tagged until the owner releases.

### 1. Environment variables `DOT_*` to `GS_*` (safe now)

There are about 120 distinct `DOT_*` names, in `DotConfig.apply_env` prefixes (e.g. `DOT_SERVER_`, `DOT_RANDOM_`) and direct `OS.get_environment("DOT_...")` reads (29 files).

- **Done (GameSpice Core API 37):** `DotConfig.gs_env(name)` and `DotConfig.gs_env_name(name)` read `GS_<rest>` first, then fall back to `DOT_<rest>`. `apply_env`, per-addon config keys, `DotHttpBase`, `DotShotSeq` and `DotParallel` already use them (`examples/env_rename_selftest`).
- Then, one repo at a time, replace the direct `OS.get_environment("DOT_X")` reads with `DotConfig.gs_env("DOT_X")`.
- Shell scripts and `docker-compose*.yml` in GameSpice Server Deploy follow the same rule: `${GS_X:-${DOT_X:-default}}`.
- The Pterodactyl egg (`deploy/pterodactyl-egg.json`) gains `GS_*` variables. Its startup line passes both until the next egg version.
- Back-compat: old names keep working indefinitely. The fallback costs one extra `has_environment` call at boot.

### 2. ProjectSettings keys `dot/...` and `dot_cloud/...` (safe with a shim)

- Add `DotConfig.setting(key, default)` to GameSpice Core. It reads `gs/<rest>` (or `gs_cloud/...`) first, then the old key.
- Existing `project.godot` files and packs keep the old keys and still work.
- New docs show the `gs/` keys.

### 3. Class names `DotX` to `GsX` (about 1,500 classes, one addon per step)

GDScript allows only one `class_name` per script, and 0.1.x packs reference `DotX` both by name and by script path. The shim per class is:

- The real script keeps its file and becomes `class_name GsX`.
- A new one-line file `dot_x_legacy.gd` holds `class_name DotX extends GsX`. It is only kept for static-only classes and for classes whose instances old code creates itself.
- The catch is `is DotX` checks in old pack code against objects that new code created as `GsX`: those return false.
  - Before converting a class, grep every published pack and every game repo for `is DotX` and `as DotX`.
  - If any exist, keep `DotX` as the real name for that class until 0.2.
- Typed signatures in new code use `GsX`. Because `DotX extends GsX`, objects from old code still pass.
- Order:
  1. Static-only utility classes first (`DotLog`, `DotResult`, `DotJson`, `DotParallel`, `DotRandom`).
  2. Then leaf addons that no pack extends.
  3. GameSpice Core's node and resource classes last.
- Each addon bumps its API level and records the rename in its `docs/addon-api.md`.
- Tool to write: `dot-ci/tools/gs_rename_class.py`. It rewrites the declarations and references in one repo, generates the legacy shims, and refuses any class with an `is`/`as` use in published packs (the scan list comes from the content origin's pack index).

### 4. Addon folders `addons/dot_x` to `addons/gs_x` (deferred to 0.2)

Published packs carry `res://addons/dot_x/...` paths in their `.tscn`/`.tres` `ext_resource` lines. UIDs cover most of these, but not text paths in code (`load("res://addons/dot_core/...")`) or `preload`.

- Do not move the folders while 0.1.x packs are served.
- At 0.2, move each folder. Ship a `res://addons/dot_x` remap through `ProjectSettings` `editor/...`/`ResourceLoader` path remaps (dot-cloud already remaps overlay paths), so `load("res://addons/dot_x/...")` resolves to `gs_x`. Keep the remap for one major version.
- `plugin.cfg` `name=` and `author=` lines are visible in the editor's plugin list. They can say Gamespice now, because nothing reads them programmatically. Check this with `grep -rn 'plugin.cfg' dot-*/addons --include=*.gd`.

### 5. Mount prefix `res://dot_cloud/...` and `user://dot_cloud` (deferred, with an alias)

The prefix comes from `DotCloudManifest.mount_root` (default `"dot_cloud"`, serialized in every manifest) and `DotCloudClient.mount_prefix_for()`. Game `game.yml` entry scenes in `content/*/game.yml` hard-code `res://dot_cloud/<id>/<ver>/...`.

- A manifest's own `mount_root` wins, so old packs keep `dot_cloud`.
- New packs may say `gs_cloud` only after every deployed client understands it. That is a GameSpice Cloud release that maps both roots, followed by the owner deploying it.
- Then:
  - The publisher's default becomes `gs_cloud`.
  - `content/*/game.yml` entries move as each game republishes.
  - `user://dot_cloud` is migrated on first boot by renaming the directory. If both directories exist, the old one is kept read-only.

### 6. Wire and storage names (keep, alias only)

- **Protocol keys** (e.g. `"dot": "dot-inventory"`), the SQL table `dot_log`, the Elastic index `dot-logs-*`, the Sentry client name `gs-log`, and service names (`&"dot_cloud_client"`) are read by deployed servers and the website.
- New readers accept both spellings. Writers keep the old spelling until every reader is on the new release.
- The Elastic index moves by alias (`gs-logs` alias over `dot-logs-*`). The SQL table moves by view.

### 7. Local directories and addons.lock (last)

`/home/gamedev/godot/dot-*` and the `repo` column of `dot-server-deploy/addons.lock` (77 rows) name the local checkouts. `setup.sh` clones from GitHub, where the names are already prefix-free.

- When the local dirs are renamed, `tools/addons-lock.sh` reads both forms for one release.
- `setup.sh` maps `dot-<name>` to `gs-<name>`, or to the bare GitHub name.
- The `addons/` symlink layout in every repo follows.
- This is a fleet-wide flag day, scripted in one pass. Do it after steps 1-3 land, while no agents are running.

### 8. Web shell and web client

- **Page text** is phase 1.
- **Asset and URL paths** (`/dot-shell/...`, if present) keep a redirect.
- **Web client storage keys** (`localStorage` `dot.*`) are read with a fallback and rewritten on first load.

## Nightly items

There is one item per group, each with "done when" set to "suites green, old names still accepted":

- **gs-rename-env:** step 1, across GameSpice Core, then each gs-* repo, then GameSpice Server Deploy and the egg.
- **gs-rename-settings:** step 2.
- **gs-rename-classes-core:** step 3 for GameSpice Core and GameSpice Log.
- **gs-rename-classes-addons:** step 3 for the other gs-* addons, one per branch.
- **gs-rename-classes-games:** step 3 references in the game-* repos.
- **gs-rename-mount:** step 5, with the GameSpice Cloud alias release first.
- **gs-rename-wire:** step 6.
- **gs-rename-dirs:** steps 4 and 7, which wait for 0.2.

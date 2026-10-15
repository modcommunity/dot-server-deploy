# Installing games: `./server install-games` and `./server index`

A deployment that wants two games should not carry ten, and should not need a redeploy to get an eleventh. `TMC_GAMES` (or `--games`) names the games a box runs; `install-games` fetches them from the content origin. The README's "Installing games" section is the operator's view.

## A game is two halves

The pack is the game: scenes, scripts, art, signed, mounted at `res://dot_cloud/<id>/<version>/`. What the server also needs is the descriptor, `game.yml`: which scene the server runs, which module drives it, player counts, cvars.

- **For first-party content**, `tools/index.gd` publishes the descriptors into `dist/` (`games.json` plus `descriptors/<id>/game.yml`), and `tools/install_games.gd` reads the catalogue, fetches the descriptors asked for, then `DotCloudClient.ensure`s each distinct pack.
- **For anybody's game, the descriptor comes out of the pack.** A game's repository has its `game.yml` in it, so the file is in the signed pack, addressed by hash. `install-games` fetches the manifest, verifies its signature against a key this server trusts, downloads that one object and **checks its hash before writing it**, because this file is pulled out early by a different path than dot-cloud's sync and then obeyed as configuration.
- **`fetch_manifest` and `verify_manifest` need a started `DotCloudClient`.** `acquire` and `ensure` start one themselves; these two do not, and an unstarted client has no HTTP client (`Nonexistent function 'get_bytes' in base 'Nil'`) and an unread `config_file`.

## Names and ids

- `TMC_GAMES=gamemann/game-g2gfast@1.2.0`, `@latest`, or no version. `tmc` is just the owner reserved for first-party content.
- **A published game's id is `<owner>/<name>`, and so is its directory** (`content/gamemann/game-arena/`), so a fork and its original, or two people's games with one name, sit side by side. A bare name still works wherever it is unambiguous (`TmcContent.find`, dot-server's `find_game`); a built-in stays `content/<name>/`. An install from before the owner was part of the path is MOVED into its owner's directory by `install-games`, and the egg's prune keeps such a directory for that one run.
- **`TmcGameRef` is the one parser.** `install-games` decides what to FETCH and `TmcHost` what to OFFER from the same `TMC_GAMES` string; two parsers would download a game and then fail to find it (and the prune would delete it on every restart).
- **Descriptors are keyed by directory id, not content id.** Several hungario modes are descriptors over one `tmc/hungry`; keyed by content id they would overwrite each other. Prefetching iterates distinct content ids, or the origin is asked for the same pack once per mode.

## The origin layout

dot-cloud's default template is `{base}/{id}/{version}/manifest.json`, which is what the site publishes. `DotCloudClient.manifest_url_fallbacks` adds the flat `{base}/{id}/manifest.json` as a fallback per base, because an origin holds both (older map packs were published flat) and re-publishing everything is not a precondition for starting a server. S3 answers 403 for a missing key the caller may not list.

**`@latest` is a FILE**, `content/<id>/latest.json`, because a bucket behind a CDN cannot answer a question and listing is not public. Not derived by sorting (that is how `0.10.0` ends up older than `0.9.0`). It is written last, after every object and the manifest, because it is the only mutable document in an otherwise immutable tree. A renamed repository leaves `{"moved_to": "<new id>"}` in the old id's `latest.json`: the installer follows it exactly one hop (a second hop or a loop is an error), logs a WARN naming the id to change to, and installs under the new id and directory.

## Three lists of packs beside the game's own

`game.yml` (inside a pack, or under `content/<id>/`) may name:

| List | Mounted | Sent to clients |
| --- | --- | --- |
| `dependencies:` | on the server at game load | yes, as `content_extra` in the one `content.sync` |
| `server_dependencies:` | on the server only | never (bot data, rulesets, server-side courses) |
| `maps:` | when the server changes to one | as the map changes, not at load |

Each entry is `<owner>/<name>` with optional `@<version>`/`@latest`. **`install-games` pins every list to concrete versions** when it installs or updates the game (`PACK_LISTS`, `_resolve_dependencies`, `stamp_dependencies`) and prefetches `dependencies` and `server_dependencies` but never `maps` (that could be a gigabyte before boot). **`TmcContent` refuses an unpinned entry** rather than resolving one per join, which would hand two players two packs under one game. The fields live in dot-server (`DotGameDescriptor.server_dependencies` / `.maps`, API level 2); a game turns `maps` into dot-map definitions with `DotMapCatalogue.add_delivered`.

- **A game whose dependency cannot be fetched is not loaded at all** (`DotGameManager._acquire_content` abandons the change). So publish a maps pack BEFORE a game whose `game.yml` names it. A clone that fails in `setup.sh`'s `GAMES` is only a warning, which is how a game naming an unpublished pack would reach a box.
- A shell exported before dot-server sent `content_extra` ignores the field and joins without the packs.
- Map lists are now an owner's setting in `cfg/content.yml` ([configuration.md](configuration.md#a-server-owners-settings-per-game-cfgcontentyml)).

## Rules of the installer

- **Keep the manifest.** dot-cloud resolves a manifest before it consults the store, over the network every time, so a box holding every file of a game could not restart while the origin was down. `install-games` keeps each verified manifest under `data/manifests/`, and `TmcHost._build_cloud` searches it. Test this with `dist/` moved aside: `dist/` is in `local_search_dirs` and stands in for the origin.
- **The games list is a filter as well as an installer.** Four things read the set of games (the listing, `changelevel`, the vote, the boot game), so `TmcContent.scan` applies the allow list once, before a descriptor is built.
- **Nothing an operator wrote is deleted.** `--games-mode remove` prunes only ids recorded in `data/installed-games.json` as installed by this tool. The default is `hide`: kept on disk, not offered.
- **A `game.yml` already on disk is never overwritten without `--refresh`**: a startup that re-downloaded it would undo an edit on the following restart. Owner settings belong in `cfg/content.yml` anyway.
- **A pack the addons cannot run is not installed over one they can.** `_check_requirements` applies `requires.json` the way dot-cloud does at mount; the installed version is kept and the tool exits 4 (`EXIT_ADDONS_BEHIND`), which the launcher answers by updating itself ([releases.md](releases.md#a-game-that-needs-newer-addons)).
- `install-games` sets its `DotCloudClient.host_role` to `"server"`, so a refusal says which side is behind.
- **The Windows launcher has no `install-games` and no `TMC_*` layer**, deliberately: every panel and container this exists for is Linux. Add it when a Windows box actually installs games.

## A server that installs its games must build none of them

On such a box `setup.sh` would clone, import and publish every game for nothing, and generate a content signing key on a machine that should only consume signed content.

- **`--only-games` is a trap here.** The addon list is derived from the games being built, so `--only-games g2gfast` links g2gfast's addons and unlinks the rest; the first time somebody adds `arena` to `TMC_GAMES` it downloads, mounts, and fails to compile. A box that decides at runtime which games it runs cannot know at install time which addons they need.
- **`--no-games` is the right flag.** It sets `GAMES=()` plus `PUBLISHED_GAMES=1`, the existing "publish nothing" statement: no keygen, no import, no pack, and the addon derivation falls back to the full `ADDONS_ALL`.
- A map nobody published cannot be found: g2gfast's `maps/imported/` travels as one pack per map, so an origin serving the game and not its maps gives a server that logs `could not fetch the map …` and carries on.

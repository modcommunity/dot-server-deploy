# Configuration

The README's "Configuration" section is the operator's view of each file. This is why it is shaped the way it is.

## `cfg/` is written by setup, `cfg.example/` is tracked

**A file an operator edits in place cannot also be a file git tracks.** When the `cfg/*.yml` were committed, and each setup script carried its own heredoc copy of them:

- `git pull` on a running server refused to merge over an operator's edits, so operators stashed their config or committed a box's port into the repository;
- the three copies drifted in the direction that grants nothing (the setup scripts kept writing group flag names that match no flag, and a tarball install had no `vote.yml` at all);
- a generated RCON password reached a public repository through `git add -A` on a tracked `cfg/addon/dot_console/rcon.yml`. `rcon_allowed: ["127.0.0.1"]` made it a rotation rather than an incident.

So `cfg.example/` is the only copy. `cfg/` is gitignored, written file by file on first run by whichever setup script ran, and **never overwritten**: an upgrade that regenerated a config would throw away the edits on the one run nobody is watching. The cost is that a template which gains a setting is invisible, so both setup scripts finish by naming the keys the templates have that your files do not mention, counting a commented-out key as answered. The template `cfg.example/addons/dot_console/rcon.yml` ships `rcon_password: ""` and setup writes the generated password into `cfg/addon/dot_console/rcon.yml` on the way in, so the tracked file never holds a secret. A flat `cfg/rcon.yml` is still read (with a WARN) until 2026-12-31. The same rule covers `export_presets.example.cfg` ([native-client.md](native-client.md)).

## Layers

```
exported defaults  <  cfg/*.yml  <  GS_SERVER_* (and each addon's GS_<ADDON>_ prefix)  <  command line
```

**`TMC_*` is not a fifth layer.** Each `TMC_*` variable becomes the matching launcher ARGUMENT, so it outranks the YAML. That is for a container or a panel with no `cfg/` to edit; `GS_SERVER_*` is the nudge a `--` argument still beats. `./server --help` has the table. Secrets are refused from argv and the environment (`--rcon-password` is rejected outright).

**Environment names are `GS_*`.** Every `DOT_X` variable is now read as `GS_X` first (`DotConfig.gs_env`, API 37); the old `DOT_X` name still works and logs one WARN line per name (`gs.config`), `GS_QUIET_DEPRECATION=1` silences it in the shell tools. The shell tools (`tools/gs-env.sh`) and the PowerShell scripts do the same. `deploy/env.example` shows the new names. The old names go when 0.2 does.

## The configuration is a surface, not a second parser

`cfg/*.yml` compiles to a `.cfg` that dot-server's own console executes, in dot-server's startup-config slot. The console is the parser, validator, range clamp, permission check and audit trail; a second one here would drift from it silently.

- **It goes through `startup_config`, not a hook.** That slot runs after the console exists and before the listener opens, the only window in which a `FLAG_STARTUP_ONLY` cvar is still settable, and the window in which `sv_tickrate` applies at once rather than waiting for the next map change ([dot-server's boot.md](../../dot-server/docs/boot.md)).
- **`data/from_yaml.cfg` is written on every boot.** It is derived, so overwriting it is right, and it answers "what did my configuration actually become".
- **Some settings cannot be console lines and are config fields instead**: anything whose cvar or command does not exist yet when the startup config runs. `sv_query_app` (registered by the query host later), `game`, `games`, `sv_web_loader` (`TmcConfig.web_loader`; a passed-through console line was dropped as naming nothing) and `map` (`sv_map` is the old spelling of it). There is no `map` command at host level at all, because `map` belongs to whichever game is loaded. So `TmcHost` reads `+map`, `--map` and `TMC_MAP` out of argv itself and applies it after the game is up through a duck-typed `change_to` (`has_method`, not `is DotMapSession`). It loads two maps at boot: the game's own scene picks the first one before anything here can say otherwise, and reaching into an uninstantiated scene to change it is the kind of thing that works until a game builds its session elsewhere. `+sv_web_loader` on argv is read the same way.

`TmcYaml` is deliberately small and refuses everything outside its subset with a file and line: tabs, duplicate keys, anchors, aliases, tags, block scalars, document markers (one-line flow sequences and mappings are accepted). A full YAML parser has a long history of parser bugs and none of that belongs in the file that decides what port a server listens on. **`on`/`off`/`yes`/`no` are bools in its dialect**, so a setting that takes words must accept a bool too (`log_router: on` is what an operator writes). It belongs in dot-core eventually and stays here while it has one consumer.

## Prefixes that keep two copies of an addon apart

- `vote.yml` is the GAME vote's `DotVoteRules` and layers `GS_GAME_VOTE_*` / `--game-vote-*`, **not `GS_VOTE_*`**, which is the prefix of the MAP vote inside the loaded game in the same process. One prefix for both would make one flag change two votes. `TmcConfig._layer_vote_overrides`; selftest asserts the plain prefix does not reach it.
- `party.yml` and `matchmaking.yml` are **by prefix, not by table**: `party_<prop>` lands on `DotPartyConfig`, `party_reserve_<prop>` on `DotPartyReservePolicy`, `mm_<prop>` on `DotMatchmakingConfig`, so a setting the addon gains needs no change here. Plain `Resource`s are coerced through the property's own type by `TmcConfig._set_on_resource`, and enums are read by name. `GS_PARTY_*` / `GS_MM_*` layer on top, because there is only one of each in the process.
- `replay.yml` is the same over `DotReplayConfig` plus this deployment's own switches.
- `bot_record.yml` is the demonstration recorder: `bot_record` and `bot_record_<property>` over dot-bot-record's `DotBotDemoConfig`, registered as the `bot_record_config` service for the game that records; the rules text is in the template.
- `radio.yml` is a plain table of `radio_*` keys (`TmcConfig.RADIO_KEYS`) read by `TmcRadio`, because dot-radio has no config resource of its own; it is off by default and needs the addon. See [operator-services](operator-services.md#the-radio-optional).
- `trail.yml` is a plain table of `trail_*` keys (`TmcTrail.KEYS`) read by `TmcTrail`; off by default and needs dot-trail. See [operator-services](operator-services.md#trails-optional).
- `net_max_bps`, `net_max_pps`, `net_max_update_rate` (and `net_mtu`, `net_max_entities`) are **ceilings on the loaded game's own netcode numbers**, not values: the host hands `TmcConfig.net_ceiling()` to the server as the `dot_net_ceiling` meta and dot-game's `DotGameModule` applies `min(game, operator)` before the netcode starts (0 on either side is no limit; the snapshot rate is also forced to a divisor of the tick rate; `net_interp_buffer` and `net_stagger_snapshots` replace the game's value; stagger spreads the peers' snapshots over the ticks between two, so it pays only when a cap makes the snapshot rate lower than `sv_tickrate`, e.g. `net_max_update_rate 15` at tickrate 30). Defaults: 1000000 bytes per second (8 Mbit/s), packets unlimited (a cap below the update rate starves snapshots), update rate 0 = the game's own. The clamp is logged at INFO on channel `game.module`.
- Everywhere else a table maps operator names to properties because they differ (`net_port` is `port`).

## Roles in, flags out

dot-server's permission model is flags, not roles: operators do not agree on what a "moderator" is, and a game adds `slay` without coordinating. What an operator writes is roles. `TmcAdmins` is the translation and the only place the two vocabularies meet. It is a **source**, not a replacement: `DotAdminManager` merges every source, so a player named here and in a site group gets the union.

**It does nothing without authentication.** `DotAdminManager.resolve` returns before consulting any source when a session is not authenticated, because a guest uid is a random per-device string. That looks exactly like the file being ignored, which is why `cfg/addon/dot_auth/auth.yml` says so at the top.

## A server owner's settings per game: `cfg/server/content/overrides.yml`

**The installer replaces a game's `game.yml` with each new version's**, so an owner's edit there lasted until the next game update and then sat unread in `game.yml.prev`. `host/tmc_game_config.gd` (`TmcGameConfig`) is the owner's half: `cfg/server/content/overrides.yml` holds `defaults:` and `games: <id>:` sections of `name`, `max_players`, `cvars`, `metadata`, `map_owner` and `maps` (`add`, unpinned = newest; `remove`; `game_maps`). `TmcHost._apply_game_config` lays it over each descriptor right after the content scan, on both boot paths, so dot-server, dot-vote and the game see one descriptor.

- **A map may be written bare** (`surf_mesa`, optionally `@version`). Its owner is, in order, the game's `map_owner:`, `defaults: map_owner:`, the game's `sv_map_content_owner` cvar (as the game will run with it, this file's cvars included), then the owner half of the game's content id; none of them refuses the boot (`TmcHost._apply_game_config`, exit 7), naming the game and the entry. **One place decides:** `TmcGameConfig.map_owner_for` and `qualified_rule` over `TmcGameRef.qualify_map`; `install-games` reaches them through `all_map_entries(content)`, so the version it pins in `data/content-maps.json` is under the id the host looks up (two readers resolving `surf_mesa` separately is the drift `TmcGameRef` exists to stop). `remove:` takes either spelling of the same map. Other three-segment ids (`a/b/c`) stay refused.
- **The game's suggested map packs are on by default.** A `game.yml` `suggested:` list (`group=owner/pack`, for example FC's `dm=` and `surf=` packs) is added to the game's map list and pinned to the newest version every start, as if each were in `maps.add`, so a fresh server offers them without an edit here. `suggested_maps: none` (or `false`) turns them off, `suggested_maps: surf` keeps one group, the `sv_suggested_maps` cvar does the same, and `--no-suggested`, `--suggested=<mode>` and `--no-suggested-<group>` on the server command line win over both. `maps.remove` still takes one out.
- **A whole collection: `owner/collection/*`** in `maps.add` (or `maps.remove`) stands for every map pack the collection (a map repository, e.g. `gamemann/airdrift-maps/*`) publishes. A renamed map repository's old collection id stays on the origin as an alias, so a server that lists it keeps its maps (`gamemann/g2gfast-maps/*` is the alias of `gamemann/airdrift-maps/*` until 2027-03-01); write the new id. Exactly that shape: no partial glob (`a/b/bhop_*`, `a/*/*`), and `@version` on it is refused at read time (exit 5) because a version of a collection is not a version of any map; pin a map beside it instead. **Individual entries win:** `owner/map@1.2.0` next to the wildcard keeps its pin, and `remove: owner/map` subtracts that map from the expansion (a `remove` of a wildcard drops the whole collection, also from an earlier `defaults:` list). The origin publishes `{base}/<owner>/<collection>/collection.json` (`{"format": 1, "id", "version", "packs": ["owner/map", ...]}`, unsigned; each pack is signed); `install-games` reads it on every start (`resolve_collections`), resolves each member's newest version like an unpinned `owner/map`, and stores the expansion under `collections` in `data/content-maps.json`. An origin that does not answer keeps the last good expansion (an uncached collection offers nothing and is reported); a `format` above 1 is an error naming the collection. `TmcGameConfig.parse_collection` is the one reader of the document.
- **A renamed game keeps its old id** as `metadata: former_ids:` in its `game.yml` (playlot lists `playground`). That id still finds the game everywhere a deployment names one: `game:`/`TMC_GAME`, `changelevel`, the games list, a `games:` section here (a section under the new id wins) and `vote_exclude`.
- Order: `game.yml` < `defaults` < the game's section. Cvars and metadata merge key by key (metadata recursively); lists replace.
- **Identity keys are refused, not applied** (`scene`, `client_scene`, `module`, `kind`, `content_id`, `version`, the dependency lists): a different value is a different game under this one's name. **Unknown keys are refused by name**, because an override silently ignored is the bug this replaced. The host's own metadata keys (`kind`, `module`, `directory`) win.
- A game's cvars are applied by dot-server before the module registers them and again after (`reapply_descriptor_cvars`); an override rides both passes.
- **Unpinned maps are resolved by the installer on every start**, into `data/content-maps.json` (`_resolve_owner_maps`), because a version decided per join would hand two players two packs under one map. An origin that does not answer keeps the cached version; an entry with no cached version is left out with a WARN, never a failed boot.
- The launcher runs `install-games` when `cfg/server/content/overrides.yml` names maps even with no games list, and copies the template into a `cfg/` that lacks it. The stock map lists live in `cfg.example/content.yml` (no game's own `game.yml` names a map pack any more), so a server offers them by default and its owner can remove them.
- **Every game reads the map list**: game-airdrift through `_adopt_descriptor_maps`, the minigames, look-at-me and delivery through dot-game's `DotGameContent.map_dirs`, playlot through its dependencies, fatalcontact through its own delivered-map path.
- **When a map pack is fetched is the game's `metadata: maps_delivery:`** (`TmcGameConfig._maps_to_clients`): `lazy` leaves it in `maps` (fetched on a change); `server` also puts it in `server_dependencies`, mounted before the game loads; `client` puts it in `dependencies`, mounted before load and sent to every player. `server` exists because dot-server admits players once the scene is up and does not wait for a module, so a game that fetched its maps in its own module load ran its first seconds on its built-in course.

selftest's "a server's settings per game" section holds these rules and ties the template to the reader.

## Per-game config directories: `cfg/game/<game>/`

Each game has one directory, named for its repository: `game-fatal-contact`, `game-airdrift`, `game-playlot`, `game-prop-hunt`, `game-deathrun`, `game-zombie-zone`, `game-hide-n-seek`, `game-murder-mystery`, `game-hungario-<mode>`, `mg-buses-from-hell`, `mg-dangerous-delivery`, `mg-look-at-me`, `mg-smash-copter` and `mg-wipeout` (`TmcGameConfig.cfg_id`; a published game uses the name half of its id). The directory holds `server.yml` (`name`, `max_players`, `cvars`, `metadata`, `maps`, `map_owner`, `suggested_maps`) and any addon files the game layers over `cfg/addon/` (`cfg/game/<game>/<addon>/...`). The operator's copy of the same directory is `cfg/server/game/<game>/`, which an update never touches.

**First boot writes a base file for every game on the server.** `TmcGameCfgDirs.write_base_configs` creates `cfg/game/<game>/server.yml` for each game that has none in either tier, from what the game declares in its own `game.yml`: its name, player count and every cvar with its default and the comment written above it there. Every setting line is commented out, so the file documents what can be set and never pins a default the game later changes; remove the `#` to set one. An existing file is never touched, and a server with a read-only `cfg/` warns and boots. Cvars a game registers only in code are not listed (a game's `game.yml` is what a server can read without loading the game); `cvarlist` on the console shows the live set. The selftest (`_test_game_cfg_dirs`) fails if any game on the build gets no readable file.

**Renamed games.** A directory under a retired name (`game-arena`, `game-final-contact`, `arena` for Fatal Contact; `game-g2gfast`, `g2gfast` for Airdrift; `game-playground`, `playground` for PLAYLOT; `TmcGameCfgDirs.RETIRED_DIRS`) is moved to the current name on boot, in `cfg/game/` and `cfg/server/game/`, with one log line. A directory with no successor is renamed whole. Into an existing one only the files it lacks are moved, an identical file is dropped and a differing one is kept as `<file>.from-<old name>` (never read, never deleted) and named in the line. `tools/cfg_sync.sh` renames `cfg/game/<old>` the same way before it writes the shipped defaults, so an owner's edit in the old shipped directory is not shadowed by the new template. Until migrated (a read-only `cfg/`), the old name is still read as a fallback; the current name wins when both exist.

## The `cfg/` move (2026-10-22)

Settings that one addon reads live in `cfg/addon/<addon>/<file>`, and the operator's overrides in `cfg/server/addon/<addon>/<file>`, which is the strongest layer (for `rcon.yml` too; an empty `rcon_password` there switches RCON off). `TmcConfig.LAYERED` names the files and their addons; `server.yml` is `cfg/server/server.yml` (a flat `cfg/server.yml` is a shim) and carries `net_*` too; other `cfg/server/*.yml` add keys. The flat files, `addons.yml` (now `packs.yml`), `games.yml` (now `game_rotation.yml`; the rotation lives in `cfg/content/games.yml`) and `content.yml` (now `cfg/server/content/overrides.yml`) are read through `DotCfgLegacy` until 2026-12-31, and a template is never copied beside a flat file that exists, because the new path wins whole. `./server cfg-migrate [--dry-run]` moves them and keeps the originals in `cfg.bak/`. `net.yml` is merged into `server.yml` (a leftover `net.yml` is still read after it, with a WARN, so it wins); subsystem keys left in `server.yml` (`log_*`, `rcon_*` bar the password, `TmcConfig.LEGACY_KEYS`) are applied with one WARN naming the addon folder. A game's entry under `games:` of `content.yml` moves to `cfg/game/<game>/server.yml` (`TmcGameConfig.read_game_files`: the same keys, `sv_name` and `sv_maxplayers` accepted, laid over the `content.yml` entry key by key). `defaults:` and the stock template `cfg.example/content.yml` (which `client/solo.json` mirrors) stay in `content.yml` for now.


## Aliases: one table for cvars and commands

`game:` in `server.yml` picks the boot game and `game <id>` at the console switches live, the same pairing as `map`. `sv_game` and `sv_games` are old spellings that are aliases of `game` and `games` **by default** (silent; nothing to write, old files keep working). If both spellings are written with different values the plain name wins and one line says so.

An alias is `alias_name: target`. It works as a key in any `cfg/` file (when the target is one word: `sv_games: a,b` is read as `games: a,b`) and is registered on the console (so it also works at a prompt, in RCON, with a target that has arguments: `restart: changelevel smash`). Three layers, later overrides earlier:

1. **Addon defaults**: `host/aliases.yml` and any `addons/<addon>/aliases.yml` (this is where `sv_game: game` and `sv_games: games` live).
2. **The game**: `content/<game>/aliases.yml` of the boot game. Console only (config files are read before the game is chosen); a game pack's mistakes are ERR lines, never a refused boot.
3. **The owner**: `cfg/server/alias.yml`.

Every layer uses the same syntax, `#` comments, no limit on entries:

```yaml
kickall: kick all            # ADD
sv_game: map                 # REMAP an alias an earlier layer made (same name, new target)
remove: [sv_games]           # REMOVE aliases an earlier layer made (also `remove: sv_games`)
```

`aliases` at the console lists the effective table with the layer and `file:line` each entry came from. Refused loudly, as an ERR naming `file:line` and a failed boot (owner and addon layers): a line that is not `name: target`, a name twice in one file, an alias to itself, an alias to another alias (no chains or loops), an alias shadowing a setting, cvar or command (not counted: an alias whose name is the very cvar its target sets, like the default `hostname` for `sv_name`, which hides nothing), and a target that is not a setting, cvar or command this server has. `remove:` of a name no earlier layer made is a WARN.

## Every startup variable is a `server.yml` key

A panel's Startup tab (the egg in `deploy/pterodactyl-egg.json`), `deploy/env.example` and the `TMC_*` environment all set the same things as `cfg/server/server.yml`. Every one of them has a key there. [b]Precedence, for all of them, is the order `tools/check_cfg_precedence.sh` tests:[/b]

1. a flag on the `./server` command line (`--name X`), then
2. a key in a `cfg/server/*.yml` file (or `cfg/net.yml`, `rcon.yml` for the RCON port), then
3. the `TMC_*` variable the panel sets.

The variable never overwrites a file and is dropped, with one `INFO <key>: cfg/server/server.yml wins over TMC_X` line, when a file sets the key. An empty variable is absent. A console command typed at runtime (`sv_maxplayers 20`, `game x`, `map y`) is applied after boot and changes the running server for as long as it runs; it does not write the file. A value that is not valid (`channel: sideways`, `verbose: maybe`) stops `./server` with a message naming the key, and there is no cap on any list.

The key may also be written under any alias (`hostname:` for `sv_name`, `sv_games:` for `games`); the layered table in the section above lists them, `aliases` on the console shows the effective one, and `sv_name:` wins over `hostname:` when both are written.

| Panel variable | `server.yml` key (aliases) | Live-changeable | Notes |
|---|---|---|---|
| `TMC_GAMES` | `games:` list of `owner/repo` (`sv_games`) | no (list is read at boot; `changelevel`/`game` pick among them) | installed, offered and rotated; a repeat is kept once with one WARN |
| `TMC_GAME` | `game:` bare id or `owner/repo` (`sv_game`) | yes: `game <id>` | a bare id matches the `games:` entry whose name half it is; an `owner/repo` the list lacks is added to it |
| `TMC_MAP` | `map:` (`sv_map`) | yes: `map <name>` | |
| `TMC_CONTENT_URL` | `content_urls:` (`sv_content_url`) | no | one string or a list |
| `TMC_GAMES_MODE` | `games_mode:` hide, remove, keep (`sv_games_mode`) | no (launcher) | |
| `TMC_NO_INSTALL` | `no_install:` true/false (`sv_no_install`) | no (launcher) | |
| `TMC_PORT` | `net_port:` (`sv_port`) | no (bind time) | |
| `TMC_BIND` | `net_bind_ip:` (`sv_bind`) | no (bind time) | |
| `TMC_RCON_PORT` | `rcon_port:` (`sv_rcon_port`), in `rcon.yml` or `server.yml` | no (bind time) | `rcon_password` is a secret and has no variable |
| `TMC_QUERY_PORT` | `query_port:` (`sv_query_port`) | no (bind time) | |
| `TMC_A2S_PORT` | `a2s_port:` (`sv_a2s_port`) | no (bind time) | |
| `TMC_QUERY_BIND` | `query_bind_ip:` (`sv_query_bind`) | no (bind time) | |
| `TMC_NAME` | `sv_name:` (`hostname`) | no | the name in the browser list |
| `TMC_MAX_PLAYERS` | `sv_maxplayers:` | yes: `sv_maxplayers <n>` | |
| `TMC_ALLOW_WEB` / `_DESKTOP` / `_MOBILE` | `sv_allow_web:` / `sv_allow_desktop:` / `sv_allow_mobile:` | yes (console cvars) | 1 admits, 0 refuses |
| `TMC_WEB_BUILD` | `sv_web_build:` | yes: `sv_web_build` | |
| `TMC_WEB_LOADER` | `sv_web_loader:` | yes: `sv_web_loader` | |
| `TMC_AUTO_UPDATE` | `auto_update:` when-needed, always, never (`sv_auto_update`) | no (launcher, before boot) | |
| `TMC_CHANNEL` | `channel:` latest, stable (`sv_channel`) | no (launcher, before boot) | |
| `TMC_ADDONS_ANNOUNCE` | `addons_announce:` all, game (`--addons-announce`) | no (read at boot) | `game` announces only the current game's addons; anything else refuses boot ([addon-packs.md](addon-packs.md#only-the-current-games-addons)) |
| `TMC_CACHE_BYTES` | `cache_bytes:` bytes, or `20G` / `512M` (`--cache-bytes`) | no (read at boot) | Ceiling on the content cache in `data/content_cache`. Empty or 0, the default, is **unlimited**. A server mounts every map it offers and never evicts a mounted one, so a ceiling below what they add up to fails maps with `code=quota` ("The content cache is full and everything in it is in use"). Every boot logs `content cache limit` with the disk free. A `cache_bytes` in `data/content.json` or `DOT_CLOUD_CACHE_BYTES` still wins, and that line names it. Anything that is not a byte count refuses boot. |
| `TMC_VERBOSE` | `verbose:` true/false (`sv_verbose`) | no (log level is fixed at start; `log_level:` in the file sets the default) | |
| `DEPLOY_REPO`, `DEPLOY_BRANCH` | none | no | [b]Install-time only.[/b] The egg's install script reads them to clone this repository, which is what contains `server.yml`'s reader, so no file of ours can exist yet on the first install. A reinstall or an auto-update keeps following the checkout's own `origin`, which is the value the install wrote. |

Three things in the egg are deliberately not keys: the secret (`rcon_password`, a file with a mode on it), the Godot runtime version (pinned with its checksum in `tools/fetch-godot.sh`), and the environment of the install container itself.

### A complete example (a party server)

```yaml
hostname: "Zee's MiniGames #1 | Party/Random Games!"
sv_maxplayers: 40
game: mg-smash-copter          # bare id, or owner/repo
games:                         # owner/repo ids; a repeat is one game
  - gamemann/mg-look-at-me
  - gamemann/mg-deathrun
  - gamemann/mg-smash-copter
```

This exact file is `examples/fixtures/zee_minigames/cfg/server/server.yml`, checked by the selftest and by `tools/check_cfg_precedence.sh`.

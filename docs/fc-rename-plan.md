# FC rename: phase 2 (load-bearing names)

Phase 1 renamed text, comments, docs and test fixtures that named Fatal Contact by its old name. What is left
are ids other systems resolve: published content ids, directories inside pinned tags, cvars, scene paths and
database rows. Each keeps working under both names first, and the old one goes only after every pin and
publish has moved. Below, `OLD` stands for the old FC name.

Rule for every lookup: prefer the FC name, fall back to the old one, and log a WRN naming the old one.

## Already accepting both names (nothing to do before the switch)

| Name | Where | Compat | Test |
|---|---|---|---|
| cfg dir `cfg/game/game-OLD`, `cfg/game/OLD` | host/tmc_game_cfg_dirs.gd:10-13, tools/cfg_sync.sh:13 | moved to `game-fatal-contact` on boot (WRN since this change, host/tmc_game_config.gd:92) and by cfg_sync before an update | examples/selftest.gd `_retired_cfg_dirs` |
| content id `gamemann/game-OLD` | host/tmc_game_ref.gd:15 | installed and offered as `gamemann/game-fatal-contact`, WRN in tools/install_games.gd:147 | examples/selftest.gd ~1100-1112 |
| `gamemann/OLD-weapons`, `-dm-maps`, `-surf-dm-maps` | host/tmc_game_ref.gd:16-18, client/tmc_addon_namespaces.gd:18 | read as `fc-*`; map wildcards too | selftest.gd `qualify_map` check |
| addon dir `addons/OLD_weapons` | setup.sh:1506-1834, tools/addons-lock.sh:129-138, tools/check-pinned.sh:21-30, setup.ps1:234-254; dot-ci resolve-deps.sh, server-compat.sh; dot-bootstrap bootstrap.sh/.ps1; dot-core dot_addon_api.gd:492 | used only when the pinned fc-weapons ref (<= v1.4.51) holds it, with a WRN | tools/check_renamed_dirs.sh, dot-ci tests/test_resolve_deps_renamed_dir.py, dot-bootstrap tests/test_renamed_addon_dir_sh.sh |
| game id `OLD` (changelevel, allow lists, TMC_GAMES) | content/fatalcontact/game.yml:109 `former_ids`, demo.sh:684,849, setup.sh:431 | resolves to fatalcontact | examples/selftest_content_lists.gd:126-134, examples/pack_requires.gd:192, tools/check_tickrate.sh:17 |
| repo/short names | dot-bootstrap projects.tsv:121 alias column | `fc`, `final-contact` and `game-OLD` all reach game-fatal-contact | dot-bootstrap tests/test_rename_dirs_sh.sh |
| profiler system prefix `OLD.` | dot-game addons/dot_game/tools/dot_game_perf_bench_compare.py `RENAMED_PREFIXES` | an old bench read as `fc.`, WRN on stderr | dot_game_perf_bench_compare_test.py |

## Still the old name, in this order

1. **Game code (fcr-game, game-fatal-contact).** Scene, module and class names (`scenes/OLD_server.tscn`,
   `game/OLD.tscn`, `game/OLD_module.gd`, `OLD_vote.gd`), cvars (`OLD_timelimit`, `OLD_scorelimit`,
   `OLD_warmup`, `OLD_restart`, `OLD_vote`, `OLD_stats_report`) and profiler zones `OLD.*`. Cvars keep the old
   name as a registered alias (as `OLD_stats_report` already is, dot-game docs/services.md:50). Then update
   content/fatalcontact/game.yml:54-56, docs/reference.md:373-414,566-572, docs/testing.md:33 and
   examples/fixtures/game_vote_rounds/content.yml:7-9 in the same push as the game.
2. **Pack content id `tmc/OLD`** (content/fatalcontact/game.yml:48; examples/burst_probe.gd:35,
   enet_relay.gd:15, voice_two_clients.gd:10, game_vote_rounds.gd:23; tools/check.sh:616-617; docs/reference.md:176-182).
   The signed trust list names it, so it needs a publisher-side alias (`moved_to`) before the id changes;
   add `tmc/OLD` -> `tmc/fatalcontact` to TmcGameRef.RETIRED_IDS in the same change.
3. **Published content ids**: dot-cloud content.lock.json:7 (`gamemann/game-OLD`) and docs/collections.md:33
   (`gamemann/game-OLD-all-maps`). Move the pin after the owner republishes under the FC id; the old id
   keeps resolving through RETIRED_IDS.
4. **Map pack ids** in cfg.example/server/content/overrides.yml:119-157 (`gamemann/OLD-surf-dm-maps-*`).
   These are the ids published today; switch them once the packs are republished as `fc-surf-dm-maps-*`.
5. **Legacy addon dir**: drop the OLD_weapons branches only when no game pins fc-weapons <= v1.4.51.
6. **Web route** `/OLD` (docs/releases.md:82) and the nightly job name `Netchaos OLD`
   (dot-game docs/qa.md:45) belong to website-city and the nightly DB.

## Owner steps

- Republish game-fatal-contact, fc-dm-maps and fc-surf-dm-maps under their FC ids (CDN keeps `moved_to` on
  the old ones). Agents then move the pins in steps 3-4.
- Re-sign the trust list for the FC pack id before step 2 ships.

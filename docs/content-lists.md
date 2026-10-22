# Download lists: `cfg/content/addons.yml` and `cfg/content/games.yml`

Which addon repositories and which games or packs a server installs is data you own. The shipped defaults are `content-lists/addons.yml` (the pinned addon repositories, from `addons.lock`) and `content-lists/games.yml` (from `games.list`); `host/tmc_content_lists.gd` (`TmcContentLists`) owns the schema and reads them. `cfg/content/` is a folder of its own, not a tier, so it never clashes with `cfg/addons/<addon>/`.

```yaml
merge: true            # absent or false: this file REPLACES the list below it
remove: [dot-voice]    # ids dropped after the lists below are merged in
entries:
  - dot-core                      # a git repository
  - dot-vote@v0.2.1               # pinned to a tag or commit
  - repo: game-arena
    pin: v1.0.0
    content: arena                # games.yml only: the content directory
  - pack: gamemann/surf_mesa      # a dot-cloud pack id
    pin: 1.2.0
```

Layers, weakest first: the shipped default, `cfg/content/<file>`, then `cfg/server/content/<file>`. Without `merge: true` the strongest file is the whole list. A pin is respected as written; an unpinned entry follows the origin's newest. A pack is still checked against its signature by dot-cloud, this only says what to fetch.

A bad entry (both or neither of `repo` and `pack`, a name with a path in it, a pin with odd characters) fails with `DotError.CODE_INVALID` naming the file and entry number; a file that is not yml fails with `CODE_PARSE`. `examples/selftest.gd` covers the default, replace, merge, server override, pin and bad entries.

**Who reads them.** `setup.sh` (`GAMES` and `ADDONS_ALL`), `tools/game_source.sh`'s `game_entries`, `tools/package_check.sh`, `tools/addons-lock.sh` and `tools/check_lists.sh` read them through `tools/content_lists.sh` (the same layering in bash: `content_list`, `content_game_entries`, `content_addon_repos`). `install-games` reads the operator's own `cfg/content/games.yml` (never the shipped default, which would download every game) when `--games`/`TMC_GAMES` is not given. A pin an operator writes in `addons.yml` beats `addons.lock`; `addons.lock` stays the pins of the shipped list. `repo_url()` still decides the owner of a repository.

**Rotation.** A games entry may carry `maps: [ids]` (the rotation order) and `rotation: sequential|random|vote`. `TmcContentLists.game_order` gives the games' order (listed first, then the other installed games sorted), `map_rotation` the maps (listed, else the installed ones sorted). An unknown map id, an unknown game that sets `maps:`/`rotation:`, or a bad `rotation:` value fails with `CODE_INVALID` naming it. `TmcHost` turns the order into a `main` cycle when the operator wrote `cfg/content/games.yml`, there is no `cfg/games.yml` rotation and two or more games are installed; a rotation file always wins. Handing a game's `maps:` to dot-map's `DotMapRotationFile` is the game's call and is not wired yet (nightly `rotation-zero-config`).

**The old `games.list`.** Read only if it still exists and there is no `cfg/content/games.yml`, with one WARN naming the new place, until 2026-12-31; after that it is ignored with an ERROR. The tracked file is gone; `addons.lock` is untouched.

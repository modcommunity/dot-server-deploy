# Download lists: `cfg/content/addons.yml` and `cfg/content/games.yml`

Which addon repositories and which games or packs a server installs is data you own. The shipped defaults are `content-lists/addons.yml` (the pinned addon repositories, from `addons.lock`) and `content-lists/games.yml` (the games `setup.sh` publishes); `host/tmc_content_lists.gd` (`TmcContentLists`) owns the schema and reads them. `cfg/content/` is a folder of its own, not a tier, so it never clashes with `cfg/addons/<addon>/`.

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

A `games.yml` entry may also carry `maps: [id, ...]` (the rotation, in that order) and `rotation: sequential|random|vote`; absent means every installed map sorted by name, sequential. `TmcContentLists.game_order` (games.yml order, then unlisted installed games sorted) and `map_rotation` (one game's maps and mode) give these, and fail with `CODE_INVALID` naming an unknown game or a listed map that is not installed. A rotation file such as `cfg/addons/dot_map/maps.yml` wins when it exists.

**Who reads them:** `setup.sh`, `tools/check_lists.sh`, `tools/package_check.sh`, `tools/addons-lock.sh`, `tools/game_source.sh` (`game_entries`, so `check.sh` and `play.sh`) read them from bash through `tools/content_lists.sh`; `install-games` fetches the `pack:` entries when it is given no `--games`. A pin in `addons.yml` is what `setup.sh` checks out; an entry without one falls back to `addons.lock`. `addons.lock` is still what the shell build writes and checks.

**The old `games.list`** (`<repository> <content directory>` per line) was removed. A box that still has its own copy at the project root and no `games.yml` keeps working with one WARN until 2026-12-31; after that it is ignored with an ERROR. Move it to `cfg/server/content/games.yml`.

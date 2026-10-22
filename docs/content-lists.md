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

**Not wired yet:** `setup.sh`, `install-games` and `tools/check_lists.sh` still read `games.list`, `addons.lock` and `repo_url()`; they move onto these files in a follow-up. Until then the shipped yml is kept equal to those lists by hand.

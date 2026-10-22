# Changing your server's settings: edit `cfg/server/` only

Everything you tune lives in the `cfg/server/` folder beside your server (create it if it is not there). The rest of `cfg/` is what the addons, the games and this project ship; edit it and an upgrade may overwrite you, or your file may be ignored. **Never edit a file inside `addons/`, `content/` or the game itself**: an upgrade replaces those and your change is gone. Put your changes in `cfg/` and an upgrade keeps them.

## Where a setting can live

Each addon (the party system, the map rotation, the vote) has a folder named after it with `-` written as `_`: `dot-party` is `dot_party`. From weakest to strongest, the first two layers are shipped with the addon and the game, and the last two are yours:

| Layer | Folder | Who writes it |
| --- | --- | --- |
| addon default | `cfg/addons/<addon>/` | the addon |
| game default | `cfg/game/<game>/<addon>/` | the game |
| **your server** | `cfg/server/addons/<addon>/` | **you** |
| **your server, one game** | `cfg/server/game/<game>/<addon>/` | **you** |

The strongest layer wins. A flat file such as `cfg/party.yml` still works until 2026-12-31 and logs one warning telling you where to move it; if the new file exists the flat one is ignored whole. The older `cfg/server/<addon>/` also still works, with the same warning.

## Worked examples

**Change a setting.** Make a party's seats be held for 30 seconds: create `cfg/server/addons/dot_party/party.yml` containing `party_seat_hold_sec: 30`. Only the keys you write change; every other setting keeps its default.

**Replace the map list.** (The replace and `merge: true` rule for `maps.yml` is in dot-core; dot-map adopts it in a follow-up, until then its own file lookup applies.) A list file (a map rotation) is replaced whole by yours, which is what you want when you say "exactly these maps". Create `cfg/server/addons/dot_map/maps.yml` and list only the maps you want.

**Add a map to the shipped list.** Start your file with `merge: true` and it is added to the list below instead of replacing it. Drop one with `remove:`:

```yaml
merge: true
remove: [dm_old_map]
maps: [dm_new_map]
```

**Change one game only.** Put the file under `cfg/server/game/<game>/<addon>/` instead, for example `cfg/server/game/game-arena/dot_map/maps.yml`. Other games on the box are unaffected.

**Choose what gets downloaded, and how it rotates.** `cfg/server/content/games.yml` lists the games and packs this server installs, and `cfg/server/content/addons.yml` the addon repositories, see [content-lists.md](content-lists.md). The same list is the rotation, so most servers need no rotation file at all:

```yaml
entries:
  - repo: game-arena
    maps: [dm_one, dm_two]
  - mg-deathrun
```

With no rotation file the games play in the order written here, and each game's maps rotate in the order of its `maps:` (no `maps:` means every installed map, sorted by name). One game means no game rotation. `rotation: sequential|random|vote` picks how a game's maps are chosen. A map or game id that is not installed is an error naming it, not a skip.

**Which one wins.** A rotation file (`cfg/server/addons/dot_map/maps.yml` for maps, `cfg/games.yml` for games) beats `games.yml`'s order, which beats the default of "everything installed, sorted". Use a rotation file only for what the list cannot say (weights, per-map settings, named rotations).

## Which layer won, and what loaded

Read `data/from_yaml.cfg`, written on every boot: it is exactly what your files became. A key the server does not know is listed at boot as unknown and never stops the server. Developers: [dot-core's addon-config.md](../../dot-core/docs/addon-config.md).

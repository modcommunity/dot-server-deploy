# Changing your server's settings: edit `cfg/server/` only

**For**: a server operator changing a setting. **Quick start**:

```bash
mkdir -p cfg/server/addons/dot_party
echo 'party_seat_hold_sec: 30' > cfg/server/addons/dot_party/party.yml
./server            # restart; data/from_yaml.cfg shows what your files became
```

1. Find the addon's folder name (`dot-party` is `dot_party`).
2. Put a file with only the keys you change in `cfg/server/addons/<addon>/`, or in `cfg/server/game/<game>/<addon>/` for one game.
3. Restart and read `data/from_yaml.cfg`.


Everything you tune lives in the `cfg/server/` folder beside your server. **Never edit a file inside `addons/`, `content/`, the game itself or the rest of `cfg/`**: an upgrade replaces those (or they are the shipped defaults) and your change is gone. Put your changes in `cfg/server/` and an upgrade keeps them.

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

**Choose what gets downloaded.** `cfg/server/content/addons.yml` and `cfg/server/content/games.yml` list the addon repositories and the games or packs this server installs (`cfg/content/` works too), see [content-lists.md](content-lists.md). Most servers need no rotation file: with none, a game rotates through its installed maps sorted by name, and several games rotate in the order of `games.yml`. To pick maps and the order, add them to the game's entry:

```yaml
entries:
  - repo: game-arena
    maps: [dm_one, dm_two]    # the rotation, in this order
```

A `maps.yml` rotation file (weights, per-map settings) still wins when it exists.

## Which layer won, and what loaded

Read `data/from_yaml.cfg`, written on every boot: it is exactly what your files became. A key the server does not know is listed at boot as unknown and never stops the server. Developers: [dot-core's addon-config.md](../../dot-core/docs/addon-config.md).

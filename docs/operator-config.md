# Changing your server's settings: edit `cfg/server/` only

**For**: a server operator changing a setting. **Quick start**:

```bash
mkdir -p cfg/server/addon/dot_party
echo 'party_seat_hold_sec: 30' > cfg/server/addon/dot_party/party.yml
./server            # restart; data/from_yaml.cfg shows what your files became
```

1. Find the addon's folder name (`dot-party` is `dot_party`).
2. Put a file with only the keys you change in `cfg/server/addon/<addon>/`, or in `cfg/server/game/<game>/` for one game.
3. Restart and read `data/from_yaml.cfg`.


Everything you tune lives in the `cfg/server/` folder beside your server. **Never edit a file inside `addons/`, `content/`, the game itself or the rest of `cfg/`**: an upgrade replaces those (or they are the shipped defaults) and your change is gone. Put your changes in `cfg/server/` and an upgrade keeps them. An upgrade overwrites only `cfg/game/<game>/` and `cfg/addon/<addon>/`; it never touches `cfg/server/`. Your server name and port live in `cfg/server/server.yml` (the old flat `cfg/server.yml` works until 2026-12-31).

## Where a setting can live

Each addon (the party system, the map rotation, the vote) has a folder named after it with `-` written as `_`: `dot-party` is `dot_party`. From weakest to strongest, the first two layers are shipped with the addon and the game, and the last two are yours:

| Layer | Folder | Who writes it |
| --- | --- | --- |
| addon default | `cfg/addon/<addon>/` | the addon |
| game default | `cfg/game/<game>/` | the game |
| **your server** | `cfg/server/addon/<addon>/` | **you** |
| **your server, one game** | `cfg/server/game/<game>/` | **you** |

The strongest layer wins. A flat file such as `cfg/party.yml` still works until 2026-12-31 and logs one warning telling you where to move it; if the new file exists the flat one is ignored whole. The older `cfg/server/addon/<addon>/` and `cfg/server/<addon>/` also still work, with the same warning.

## Worked examples

**Change a setting.** Make a party's seats be held for 30 seconds: create `cfg/server/addon/dot_party/party.yml` containing `party_seat_hold_sec: 30`. Only the keys you write change; every other setting keeps its default.

**Replace the map list.** (The replace and `merge: true` rule for `maps.yml` is in dot-core; dot-map adopts it in a follow-up, until then its own file lookup applies.) A list file (a map rotation) is replaced whole by yours, which is what you want when you say "exactly these maps". Create `cfg/server/addon/dot_map/maps.yml` and list only the maps you want.

**Add a map to the shipped list.** Start your file with `merge: true` and it is added to the list below instead of replacing it. Drop one with `remove:`:

```yaml
merge: true
remove: [dm_old_map]
maps: [dm_new_map]
```

**Change one game only.** Put the file under `cfg/server/game/<game>/` instead, for example `cfg/server/game/game-arena/maps.yml`. Other games on the box are unaffected.

**Choose what gets downloaded.** `cfg/content/addons.yml` and `cfg/content/games.yml` list the addon repositories and the games or packs this server installs (the old `cfg/addons.yml` and `cfg/games.yml` work until 2026-12-31 with one warning). Per-game overrides go in `cfg/server/content/overrides.yml` (the old `cfg/content.yml` is read the same way), see [content-lists.md](content-lists.md). Most servers need no rotation file: with none, a game rotates through its installed maps sorted by name, and several games rotate in the order of `games.yml`. To pick maps and the order, add them to the game's entry:

```yaml
entries:
  - repo: game-arena
    maps: [dm_one, dm_two]    # the rotation, in this order
```

A `maps.yml` rotation file (weights, per-map settings) still wins when it exists.

## Threads and who is sent what

Two groups of settings decide how much a busy server costs. All of them go in `cfg/server/server.yml` (the server's own file; restart to apply), and the first group is also live at the console and in dot-workbench's **Server threads** panel.

```yaml
# threads: the count, then the opt-ins (nothing is threaded until its own switch is on)
sv_worker_threads: -1      # -1 cores less one (at most 8), 0 everything on the main thread; set it when several servers share a machine
sv_threads_net: 1          # build each player's snapshot on the workers (not on the web)
sv_threads_npc: 0          # NPC decisions and path searches, for brains that support it

# relevance: what a player is sent
net_interest_radius: 150   # metres; at most this far from a player is sent to them (0 keeps the game's own)
net_far_every: 4           # anything farther than net_far_distance is sent in one snapshot of 4
net_far_distance: 60       # metres; 0 is never far
```

`net_interest_radius` is a ceiling on the game's own radius (the smaller wins; 0 means no limit from you). `net_far_every` and `net_far_distance` replace the game's values when written. `sv_threads_npc` is read by no game yet. Zombie Zone's `zz_net_far_every` and `zz_net_far_distance` are the same two settings under the game's own names and keep working; where a game sets its own, the game's wins.

Where the files live: the server's own settings are `cfg/server/server.yml`; an addon's are `cfg/server/addon/<addon>/<file>.yml` (singular `addon`, the folder is the addon name with `-` as `_`) and one game's `cfg/server/game/<game>/`. The workbench's Save for the thread cvars writes `cfg/server/addon/dot_server/threads/server.yml` and applies it at the next start. `cfg/server/addons/` (plural) and `cfg/addons/` are the old layout: read, with a warning, and not documented anywhere else. A name the server does not know is listed at boot as `unrecognised setting`, with the nearest known names (`did you mean net_interest_radius?`).

## Which layer won, and what loaded

Read `data/from_yaml.cfg`, written on every boot: it is exactly what your files became. A key the server does not know is listed at boot as unknown and never stops the server. Developers: [dot-core's addon-config.md](../../dot-core/docs/addon-config.md).

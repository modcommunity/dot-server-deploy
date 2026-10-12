# The constraint that decides what a delivered game may look like

**This build contains no game.** Every game id is `kind: pack`: `setup.sh` turns each game repository into a signed dot-cloud pack in `dist/` (`./server pack <id> --source <repo>`), the server finds it there by content id, and a client downloads it on connect. A built-in game would be a game that has to be re-exported to change, and a client that contains one game contains the machinery for all of them. When nothing names a game the server boots `arena` (`default: true` in its `game.yml`).

## The root cause

A delivered pack mounts at `res://dot_cloud/<id>/<version>/`, not at the path its content was authored at, and **a mounted pack's `class_name` globals are not registered in the host**. Measured:

```
class_name reference from a mounted pack    FAILS to compile
preload("res://path.gd")                    works
extends "res://path.gd"                     works
```

The pack mounts, its scenes load, and every script in it is dead, with no error until something tries to run one. It is a property of the engine and will not go away. It is the same shape as dot-cloud's rule for avatar packs ("the pack is data, the code ships in the build"), reached from further along.

## The seven forms, all closed

Each was found by running something, and each is invisible until a game is actually delivered.

| Route | Symptom | How it is closed |
| --- | --- | --- |
| script → script by `class_name` | every cross-file type reference fails to compile; the pack mounts and its scripts are dead | every game references its own files by relative `preload`; `tools/check.sh` refuses a new `class_name` |
| scene → script by `ext_resource` | the scene loads with its script silently missing (`Attempt to open script 'res://…' … 'File not found'`) | `DotCloudPublisher` rewrites text resources to the mount prefix at publish time |
| script → anything by `"res://…"` | resolves against the HOST project root: another game's file, or nothing | `<Game>Paths.rebase()` resolves the game's root from its own script's `resource_path` |
| script → superclass by `extends "res://…"` | the same, for the inherited class | made relative; a relative superclass path travels with the script |
| an asset the engine has to IMPORT | a `.glb` or `.png` is bytes nothing can open (`exists=false file=true load=null`), and no error | the publisher ships `.godot/imported/` and the `.import` markers, with the three absolute paths in each marker rewritten onto the mount |
| an imported asset's reference to its SIBLING | the mesh loads and its texture does not (the binary `.scn` holds a UID plus the authored path); two warnings, no error | `DotCloudMounter` registers the pack's own UIDs against the mounted files after mounting |
| a path the publisher already rewrote, rebased again | `res://dot_cloud/tmc/smash/0.1.0/dot_cloud/tmc/smash/0.1.0/assets/…` | `<Game>Paths.rebase()` returns a path already under the mount unchanged |

The seventh exists because the second and third are both closed. The publisher rewrites `res://` strings inside `.tscn`, `.tres` and `.import`, but not inside a `.gd`, which it cannot parse. So a delivered game holds both kinds (a script `const` that still says `res://props/x.tscn`, and an exported property that arrives already absolute) and one function is handed both. The live exposure was a per-scene exported path such as `bfh_prop_body.atlas_path`.

## Rules that follow

- **A delivered game references its own files by relative path**: relative `preload`, relative `extends`, and every `res://` string through `<Game>Paths.rebase()`. A `const` cannot hold a function call, so such paths are `static var`.
- **`rebase()` is one line over `rebase_onto(path, root)`.** Built in, `root()` is `res://` and every property of `rebase()` that matters in a pack is a tautology, so a suite that tests against the real root passes with the bug in. mg-smash-copter's did. Any new `<Game>Paths` splits the same way so a suite can hand it a mount prefix.
- **Only a first segment the game actually ships is moved.** `res://audio` in a game with no `audio/` names the HOST's directory; rebasing it would point into a pack where nothing exists.
- **A form is closed when every game closes it, not when the mechanism exists.** The seventh was first fixed in one game and written up as closed; six others carried the unguarded `rebase()` until a review across all of them.
- **A delivered module may name only base classes the host build carries.** A module that `extends DotGameModule` needs `addons/dot_game` here; without it the symptom is "Could not find base class" once, then a server admitting players into a game with no netcode.
- **This build cannot name a type a pack declares**, so anything here that inspects a delivered game does it by duck typing and `describe()`, the same bargain every module makes with dot-game.

## What `tools/check.sh` counts

It counts what would genuinely break: shipped code, outside comments, not already wrapped in `rebase()`, first segment owned by the game. Its first version counted the literal inside a `rebase()` call (the fixed form), doc comments and `examples/`/`tools/` (which never travel), so it went from 92 to 102 when the work landed. A number that moves the wrong way when the work lands teaches people to stop reading it.

## Publishing a pack

- **The source of a pack is the game's repository** (`--source`); `game.yml` supplies the id, version and entry scene, and `pack.json` beside it says what not to ship.
- **A pack is named for its CONTENT id, not its directory.** Hungario is several game ids over one `content_id: hungry`; everything looks a pack up as `{base}/{content id}/…`, so a pack under a directory id is one nothing can find.
- **A pack published here carries `requires.json`, as a release pack does.** `tools/pack.gd` runs dot-core's `tools/dot_requires.gd` with `--path` the source (its own addons, its `requires.floor.json`), audits a committed `requires.json` instead, and adds the derived file through `RequiresPublisher` without writing into the game's checkout; it reads the manifest back and fails the pack if the file is missing. Before 2026-10-12 only dot-ci's `package.sh --pack` wrote one, so a self-published pack could not be refused with "needs dot-x API level N". A source with no deriver in its dot-core ships without one, with a note. `examples/pack_requires.tscn`.
- **Imports happen before publishing.** Nothing imports at runtime on any platform, so `setup.sh` runs `--import` in each game repository before packing it.
- **`exclude_dirs` in `pack.json` matches a directory name at any depth.** `"tools"` once also dropped game-playground's `game/tools/` (every tool-gun mode). And a game pack must not follow a link to a maps directory that is published as its own pack: an id already in a catalogue is never replaced, so the game's copy shadows every maps update.
- **A stale pack is invisible from both sides**: the game is fixed, `setup.sh` is not re-run, and this server serves the old pack while both suites pass. `tools/check.sh` compares the manifest's timestamp against every source file in the sibling and fails on anything newer. Timestamps, not contents, because a correctly published `.tscn` is deliberately not byte-identical to its source. With no sibling (a release tarball, the container's final stage) it says so and passes.
- **`check.sh` fails if `game/`, `scenes/`, `maps/`, `avatars/`, `npcs/`, `props/` or `textures/` exists at the project root**: a vendored copy left from the old arrangement would win over the delivered game for players on this build only.

The games used to be copied into one `game/` and `scenes/` here, because a `.tscn` stores absolute `res://` paths; that made every new game a new engine build. Closing the forms above is what made delivery possible. The stories are in [history.md](history.md#the-mount-constraint).

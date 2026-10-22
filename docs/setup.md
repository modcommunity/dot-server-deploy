# setup.sh: addons, games and the runtime

**For**: an operator installing or re-installing a server, and anyone changing `setup.sh`. **Quick start**:

```bash
./setup.sh              # runtime, addons into addons/, games into games/, writes ./server
./setup.sh --no-games   # a box that installs its games at runtime
./setup.sh --update     # move the clones to addons.lock
./server
```

**Edit** `cfg/server/` only; **never edit** `addons/`, `games/`, `dist/` or the generated `./server`. Which games and addons exist is `cfg/server/content/` ([content-lists.md](content-lists.md)).


`setup.sh` (and `setup.ps1` for Windows) fetches the runtime, puts the addons and games where the build can see them, publishes the packs, and writes `./server` from `tools/server.in`. **`./server` is generated: regenerate it (re-run `setup.sh`) after editing `tools/server.in`**, or an export runs the old launcher without the new checks.

## One fact, one place

This project's most repeated bug is one fact written down twice, and it has shipped that way several times ([history.md](history.md#lists-that-went-stale)). The current owners of each fact:

| Fact | The one place | Readers |
| --- | --- | --- |
| which games to build | `cfg/content/games.yml` over the shipped `content-lists/games.yml` (`setup.sh` builds `GAMES` from it) | `tools/check.sh`, `tools/package_check.sh`, `play.sh` read it through `game_entries` (`tools/content_lists.sh`); `tools/check_lists.sh` fails when a `content/<dir>/pack.json` or a game repository in dot-bootstrap's `projects.tsv` has no entry |
| which addons exist | `cfg/content/addons.yml` over the shipped `content-lists/addons.yml` (`setup.sh` derives `ADDONS_ALL` from it) | `tools/package_check.sh`, `tools/addons-lock.sh` read it through `content_addon_repos`; `setup.ps1`'s `$addons` is a copy (no PowerShell here to prove a parser of a bash array), and `tools/check_lists.sh` (run by `check.sh`) fails when it differs in a name |
| addon name to repository | `addon_repo()` (underscores to hyphens, except `zee_weapons` → `zee-dot-weapons`) | the exception is repeated in `setup.ps1`'s `Get-AddonRepo`, which `tools/check_lists.sh` compares; the two bash tools take repository names straight from the yml |
| repository to owner | `repo_url()`: `dot-*` from `$GIT_BASE` (the organisation), everything else from the games owner | the family rule in [game-dev/CLAUDE.md](../../../CLAUDE.md#repositories-owners-and-pushing) |
| where a game's source is | `tools/game_source.sh` (`--games-dir`, then `games/`, then the parent), with `game_entries` | sourced by `setup.sh`, `play.sh`, `check.sh`, `package_check.sh` |

`setup.sh` resolves every source before it removes anything and refuses a partial set.

## The addons live inside the project

A missing addon is cloned into `addons/.repos/<repo>` and `addons/<name>` is a **relative** link into it, so the tree can be moved, tarred or copied into an image and still resolve. Cloning beside the project (the old default) wrote into a directory this project does not own, made several servers on one box share one set of clones without saying so, and dangled every link when the directory moved. `.repos` is hidden from Godot twice (the leading dot, and a `.gdignore` written before the first clone), because each clone has its own `addons/<name>` and scanning both would declare every `class_name` twice.

- **`--addons-dir DIR` (`TMC_ADDONS_DIR`) is the old behaviour, asked for by name.** It accepts a directory of addons or of repositories, links with absolute paths, and clones what is missing into that directory. The Dockerfile and `tools/package_check.sh` pass `--addons-dir ..` explicitly, because both stage the siblings deliberately and would otherwise prove something about GitHub rather than the working tree.
- **An existing link that still resolves is left alone.** That is what makes the change safe to pull on a box set up the old way; `addon_source` reports where each addon came from.
- **`--update` runs after resolution** and is given directories, because an addon can be in three places.
- **`--vendor` copies instead of linking** (for a container's final stage or a release tarball), then deletes `addons/.repos/` and `games/`.
- **The addons are locked**: see [releases.md](releases.md#addonslock).

## The games live in `games/`

`setup.sh` clones a missing game into `games/<repo>` and publishes from there, for the same reasons as the addons, and worse: what comes out is a signed pack every client runs. `games/` has a `.gdignore`, because a game walked as part of this project declares its `class_name` globals here too, and a delivered game's scripts then resolve to this build's stale copy (`Value of type "res://dot_cloud/…" cannot be assigned to a variable of type "G2GIdentity"`).

- **A developer checkout gets a link, not a second clone.** `link_sibling_game` makes `games/<repo> -> ../../<repo>`; a second clone is the arrangement where a fix is committed, pulled and still not running. `--vendor` skips the link.
- **`--games-dir DIR` (`TMC_GAMES_DIR`) is separate from `--addons-dir`** on purpose: one shared addon library does not imply publishing packs from a shared games tree.

## `--only-games` and `--skip-games`

They filter the `GAMES` array and nothing else; everything below walks only `GAMES`. A name may be the repository, the repository without `game-`, or the content directory. Both are repeatable and comma- or space-separated (`TMC_ONLY_GAMES`, `TMC_SKIP_GAMES`); given both, `--only-games` picks and `--skip-games` narrows. **Do not use them on a box that installs its games at runtime** ([installing-games.md](installing-games.md#a-server-that-installs-its-games-must-build-none-of-them)); use `--no-games`.

- **A bad name is fatal, at the array**, naming every game this build has. A typo that silently narrowed the build would surface four steps later as a message about `dist/`.
- **A skipped game's existing pack in `dist/` is not deleted**, and the run says so.
- **What was left out goes in `dist/.skipped-games`**, and any run that filtered nothing deletes it. `check.sh` and `play.sh` read it so a deliberately skipped game is not reported stale; a marker left behind would excuse a pack that genuinely failed.
- **The addons are derived, so there is no `--skip-addons`.** Each project declares `/addons/<name>` lines in its own `.gitignore`; a filtered build links the remaining games' union plus `ADDONS_SHELL` (the addons this project's own scripts name). For the full set the derivation reproduces `ADDONS_ALL` name for name, and it runs only when a game was actually dropped.
- **`ADDONS_SHELL` may be small because a mistake in it is loud**: this project's own scripts fail to compile on the next import.
- **An addon the build no longer needs is unlinked, and where it pointed is recorded in `addons/.unlinked` first**, because `addon_source` finds a sibling only through its existing link; the first version without the record re-cloned 26 addons on the next unfiltered run. Only symlinks are ever removed.
- **A filtered build narrows what the server offers**: `vote_exclude` is seeded into a newly created `cfg/addons/dot_vote/vote.yml` (named, not edited, when the file exists) and covers every content directory sharing the dropped `content_id`.

## Addons only this project names

`dot_replay`, `dot_friends` and `dot_log` are named by this project's scripts and by no game, so they are in both `ADDONS_ALL` and `ADDONS_SHELL`. **This project's `.gitignore` is a bare `/addons/`, which dot-bootstrap and dot-ci read as "declares nothing"** on purpose: two named lines under it would make both tools resolve exactly those two into a project that needs all of them.

## The runtime: `tools/fetch-godot.sh`

- **One version, pinned** (`GODOT_VERSION=4.7.2-stable`), because a digest only means anything against a file that cannot change.
- **The digests are in the script, reviewed by a person**, never read from the `SHA512-SUMS.txt` served beside the binary (that would be checked by whoever would have had to tamper with both).
- **A mismatch deletes the file and exits non-zero.** No `--force`. The digest gates the unpack too.
- It lands in `~/.cache/tmc/godot/<version>/godot` (`TMC_GODOT_CACHE` moves it), falling back to `.godot-runtime/` in the project when the home directory is unwritable.
- `--no-download` / `TMC_NO_DOWNLOAD=1` restores the old refusal, and an explicit `--godot` never downloads.
- **It runs the binary before reporting success**: Godot links fontconfig at load even headless, so on a minimal image it dies with `libfontconfig.so.1: cannot open shared object file`, which reads like a bad download. The fetcher prints the package-manager line for the missing library.
- **It stages on the destination's filesystem, not `/tmp`, runs `unzip < /dev/null`, and checks `df` first** ([pterodactyl.md](pterodactyl.md#a-containers-tmp-is-not-the-machines)). `tools/fetch-export-templates.sh` has the same three fixes.
- **The Dockerfile has no download of its own**: stage 1 runs `tools/fetch-godot.sh --dest /usr/local/bin`. Two pins drift.
- `setup.ps1` has its own digests and takes the **console** exe, because the plain Windows build detaches from the console that started it.

## Windows

`setup.ps1` makes junctions rather than symlinks, `server.ps1` is the launcher and `server.cmd` forwards to it. **Neither has ever been run on Windows from here**: there is no PowerShell on the development machine, so both are reviewed, not tested, and they are the first suspect if anything Windows-shaped misbehaves. Known divergences:

- `tools/server.ps1.in`'s `pack` still runs `res://tools/publish.tscn`, a scene that was never written; the bash launcher builds on `tools/pack.gd` and dot-cloud's CLI. It needs a port, not a patch.
- No `TMC_*` environment layer and no `install-games`, deliberately ([installing-games.md](installing-games.md#rules-of-the-installer)).

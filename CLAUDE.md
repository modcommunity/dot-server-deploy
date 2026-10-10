# dot-server-deploy

TMC's server tool: a Godot project that boots a dot-server from `cfg/` and `content/`, and
the client shell it exports — for a browser, and now for a desktop the app can install on. Read `../../CLAUDE.md` first for the family-wide rules; this file
is what is specific to here.

## Why this project exists

**Everything in the family had been run and nothing had been deployed.** Each addon has
its own headless suite, three games run the seams, and not one of them answers "how does a
server owner start this". `dot-serve` is the front door for a bare dot-server; this is the
front door for the whole platform — configuration, permissions, content, a container, and
a client a stranger can open in a browser.

**It is the first place the browser target was actually loaded.** Everything about it was
reasoning until now: the WebSocket listener, the no-threads path, the `user://` flushes.
Loading it found three bugs in three different repositories, and every one of them made
the browser target impossible.

## The one constraint that decides what a delivered game may look like

**A mounted dot-cloud pack's `class_name` globals are not registered in the host.**
Measured, not assumed:

```
class_name reference from a mounted pack    FAILS to compile
preload("res://path.gd")                    works
extends "res://path.gd"                     works
```

The pack mounts, its scenes load, and every script in it is dead — with no error until
something tries to run one. So a game meant to be **delivered** references its own files
by path; a game compiled into the shell has no such restriction.

That constraint has not gone away — it is a property of the engine. What changed is the
games: every one of them references its own files by relative path and rebases its own
`res://` strings, so each is correct in a build and at a mount prefix alike. **Every
game id is `kind: pack` and this build ships no game at all.** The five fourth-form
routes below are what had to be closed first, and `tools/check.sh` keeps them closed.

A built-in game is a game that has to be re-exported to change, and a client that
contains one game contains the machinery for all of them, which is the thing this was
trying to stop. `content/arena/game.yml` sets out the constraint. When nothing names a
game the server boots `arena` (`default: true` in its `game.yml`); the 2D lobby that used
to be the default was scratched on 2026-10-08, and the suites that booted it boot buses.

It is the same shape as the constraint dot-cloud already documents for avatar packs — "the
pack is data, the code ships in the build" — reached from further along.

### The constraint has seven forms, and all of them are closed

One root cause — a delivered pack mounts at `res://dot_cloud/<id>/<version>/` and not at
the path its content was authored at — reaching the code by three separate routes. Each
one was found by running something rather than by reading, and each is invisible until a
game is actually delivered.

| Route | Symptom | State |
| --- | --- | --- |
| script → script by `class_name` | every cross-file type reference fails to compile; the pack mounts and its scripts are dead | **closed** — every game references its own files by relative `preload`, and `tools/check.sh` refuses a new `class_name` |
| scene → script by `ext_resource` | the scene loads with its script silently missing: `Attempt to open script 'res://…' … 'File not found'` | **closed** — `DotCloudPublisher` rewrites text resources to the mount prefix at publish time |
| script → anything by `"res://…"` | resolves against the HOST project root: another game's file, or nothing | **closed** — `<Game>Paths.rebase()` resolves the game's root from its own script's `resource_path` |
| script → superclass by `extends "res://…"` | the same, for the class a script inherits from | **closed** — made relative; a relative superclass path travels with the script |
| an asset the engine has to IMPORT | a `.glb` or `.png` in the pack is bytes nothing can open: `exists=false file=true load=null`, and no error anywhere because the file is right there | **closed** — the publisher ships `.godot/imported/` and the `.import` markers, and rewrites the three absolute paths inside each marker onto the mount |
| an imported asset's own reference to its SIBLING | the mesh loads and its texture does not: the imported form is a binary `.scn` whose dependency is a UID plus the authored absolute path, and the pack can rewrite neither. Two warnings, no error, and a game that appears to have shipped without art | **closed** — `DotCloudMounter` registers the pack's own UIDs against the mounted files after mounting, so the binary form's reference resolves with nothing rewritten |
| a path the publisher ALREADY rewrote, rebased a second time | `res://dot_cloud/tmc/smash/0.1.0/dot_cloud/tmc/smash/0.1.0/assets/…`, which does not load, in a path long enough that the doubling reads as noise | **closed** — `<Game>Paths.rebase()` returns a path already under the mount unchanged |

The seventh is the second and third forms meeting, and it only exists because both of them are closed. The publisher rewrites every `res://` string inside a `.tscn`, a `.tres` and a `.import`; it does not rewrite the ones inside a `.gd`, because a script is not a resource file it can parse. So a delivered game holds both kinds — a `const` in a script that still says `res://props/x.tscn` and needs rebasing, and an exported property on a node that arrives already absolute and must not be — and one function is handed both. It was found by booting a server that mounted mg-smash-copter: the cannon fired, the prop spawned, and `ScPropBody` could not load its model.

**It was closed in one game and written up here as closed everywhere, which is its own small lesson.** When this entry was first written only mg-smash-copter had the guard; the other six carried a byte-identical unguarded `rebase()`, and a review pass over all seven is what found that. They all have it now, and the live exposure was mg-buses-from-hell, whose `bfh_prop_body.atlas_path` is an exported property that exists to be set per scene — which is exactly the shape that lands a string where the publisher rewrites it. **A form of this constraint is closed when every game closes it, not when the mechanism exists.**

**The check for it cannot be written against the real root, and that is the lesson worth more than the fix.** Built in, `root()` is `res://` and every `res://` path is already under it, so every property of `rebase()` that matters in a pack is a tautology in a build. mg-smash-copter's suite asserted the idempotence, the bug was put back, and the suite reported 101 passed and 0 failed. `rebase_onto(path, root)` exists so a suite can hand it a mount prefix; `rebase()` is one line over it. Any game adding a `<Game>Paths` should split it the same way.

The sixth was found by **publishing the first game in this family that vendors art** and looking at a screenshot of a real client: mg-buses-from-hell's crates arrived as white boxes with the node their model was instanced under reported as having "vanished". It is the same root cause reaching the code by a route nothing here could rewrite — see dot-cloud's own notes.

The fourth was found by accident: a const collision made somebody open
`npc_chaser.gd`, whose own comment said it extended a path rather than a class *"because
it is the shape an entity delivered in a dot-cloud pack must have"* — and the path it
extended was absolute. The intent was right and the form was not, in eleven files.

`<Game>Paths.rebase()` closes the third. It resolves the game's root from its own
script's `resource_path`, which is `res://` when the game is built into the shell and the
mount prefix when it is delivered — so one form is correct in both, and built in it
returns exactly what it was given. Format specifiers survive, because only the prefix
moves. A `const` cannot hold a function call, so paths that were constants are
`static var` now.

**Only a first segment the game actually ships is moved.** `res://audio` in a game with no
`audio/` names the HOST's directory, and rebasing it would point into a pack where nothing
exists. Five such references remain across the five games and every one is correct as it
stands.

`tools/check.sh` counts what would genuinely break — shipped code, outside comments, not
already wrapped in `rebase()`, first segment owned by the game. **The first version of that
counter got it wrong in three ways at once** and read 92 before the fix and 102 after, which
is a completed piece of work reported as a 10% regression: it counted the literal inside a
`rebase()` call, which is the fixed form; it counted doc comments, which are prose; and it
counted `examples/` and `tools/`, which never travel in a pack. A number that moves the
wrong way when the work lands is worse than no number, because it teaches people to stop
reading it.

## `cfg/` is written by setup, and `cfg.example/` is what is tracked

**A configuration file an operator edits in place cannot also be a file git is tracking.** The seven `cfg/*.yml` were committed, and setup.sh carried a second copy of each one in a heredoc for a tarball with no checkout, and setup.ps1 carried a third for Windows. Three consequences, all of them found on a live box rather than reasoned about:

`git pull` on a running server stopped. *"Your local changes to the following files would be overwritten by merge: cfg/server.yml"* — and what it was refusing to merge was a default nobody wanted, over an answer somebody had chosen for that deployment. The operator's options were to stash their own configuration or to commit a box's port into the repository, and both had been done.

**The copies drifted, silently, in the direction that grants nothing.** The committed `groups.yml` carried dot-server's real flag names, having been fixed when the `warn`/`announce`/`change` bug was found; both setup scripts still wrote the three names that match no flag and grant nothing while erroring nowhere. `vote.yml` existed only in the checkout, so a tarball install had no game voting at all and no file saying it could. The committed `server.yml` had gained `content_urls` and `query_bind_ip` and lost `sv_password`, `sv_tickrate` and `sv_tags`, because it was not a template any more — it was one server's answer, being edited by whoever was on that box.

**And a generated secret reached a public repository.** setup.sh generates an RCON password on first run, writes it 0600, and prints it once. Run that where git is watching a tracked `cfg/rcon.yml` and the next `git add -A` publishes it, beneath a comment block explaining that the file ships empty because a password in a public repository is a password everybody has. `rcon_allowed: ["127.0.0.1"]` is why it was a rotation rather than an incident, which is the argument for that default and not for the mistake.

So: `cfg.example/` is tracked and is the only copy. `cfg/` is gitignored, written file by file on first run by whichever setup script ran, and **never overwritten** — an upgrade that regenerated a config would throw away the edits on the one run nobody is watching. The cost of never overwriting is that a template which *gains* a setting is invisible, so both scripts finish by naming the keys the templates have that your files do not mention, treating a commented-out key as answered. `rcon_password: "@RCON_PASSWORD@"` is a placeholder substituted on the way in, so the tracked file has no secret in it even for one run.

The Windows script's comment said a shared source would be a third format and two scripts agreeing by construction was not worth inventing one. The shared source turned out not to be a format at all — it is the files themselves, and both scripts now copy a directory.

## The configuration is a surface, not a second parser

`cfg/*.yml` compiles to a `.cfg` that dot-server's own console executes, in dot-server's
own startup-config slot. The console is the parser, the validator, the range clamp, the
permission check and the audit trail, and a second one here would drift from it silently.
dot-serve reached the same conclusion from the other end: "dot-server's console is the
parser, and a second one here would drift from it."

Two consequences worth keeping:

- **It goes through `startup_config`, not through a hook.** That slot runs after the
  console exists and *before* the listener opens, which is the only window in which a
  `FLAG_STARTUP_ONLY` cvar — `sv_tickrate`, and everything else fixed at boot — is still
  settable. There is no signal in that window and there should not be one.
- **The compiled file is written to disk.** `data/from_yaml.cfg` is generated and
  overwritten every boot, which is the opposite of dot-serve's rule about never touching
  `server.cfg` and right for the opposite reason: this file is *derived*, and the authored
  one is the YAML. It exists because "what did my configuration actually become" is the
  question an operator has when a setting appears not to work.

**`sv_map` is a third consequence, and it is the exception that shows the rule.** Almost everything in `cfg/` reaches dot-server as a console line, and two settings cannot: `sv_query_app`, because the cvar that would take it is registered by the query host after the startup config runs, and `sv_map`, because there is no `map` command at this level at all. The one that exists belongs to whichever game is loaded, and when the console's `+command` half runs — after the listener, which is already as late as dot-server can make it — this host has not loaded a game yet. So `./server -- +map bhop_g2g_intro` was parsed, logged, dispatched into a console with no `map` in it, and dropped: the server booted on the game's own default map and said nothing about the argument. `TmcHost` reads `+map` out of argv itself now, alongside `--map` and `TMC_MAP`, and applies it after the game is up through a duck-typed `change_to` — `has_method`, not `is DotMapSession`, for the reason dot-vote's map source gives. **It loads two maps at boot and that is the honest cost:** a game's map session is built by the game's own scene from the game's own config, so the first map is chosen before anything here can say otherwise, and reaching into a scene that has not been instantiated yet to change a value it is about to read is the kind of thing that works until a game builds its session somewhere else.

`TmcYaml` is deliberately small and refuses everything outside its subset with a file and
a line: tabs, duplicate keys, anchors, aliases, tags, block scalars, inline mappings,
document markers. A complete YAML parser is a large program with a long history of parser
bugs — including a boolean type famous for turning the country code `NO` into `false` —
and none of that belongs in a file that decides what port a server listens on. It belongs
in dot-core eventually and is here while it has one consumer.

## The players choose the next game

`cfg/vote.yml` and `host/tmc_vote.gd`. **This is the first place in the family anybody
votes for a game.** dot-map has voted for maps since it was written and two games use
it; nothing had ever voted for what the *server* should be running, because until this
project there was nowhere a server ran more than one. There are five games in
`content/` and `changelevel` already switched between them under live players — the
only thing missing was letting the players ask.

```
!game_nominate g2gfast   !game_rtv   !game_vote 2      !game_timeleft   !game_next
```

**The `game_` prefix is load-bearing.** A game in `content/` may run a vote of its own — one of them votes for the next *map*, which is what that genre has always done — and its module registers `rtv`, `nominate`, `timeleft` and `nextmap` before `TmcVote.install` ever runs. `DotConsole.register_command` keeps the first registration of a name and hands it back, so an unprefixed server vote does not fail loudly: it gets four dead commands and nine live ones, and a player nominating a game is told there is no such map while `!nominations` shows them an empty ballot. The four names also belong to the game's module, so the first `changelevel` away unregisters them for the rest of the process. `!rtv` is about the game in front of you; `!game_rtv` is about which game is next. For the same reason this director sets `register_service = false` — `dot_vote_director` in `DotRegistry` belongs to the loaded game's vote, and the registry is last-wins.

The engine is **dot-vote**, and the whole of the policy is `vote.yml`, which is a `DotVoteRules` and therefore layers `defaults < vote.yml < DOT_GAME_VOTE_* < --game-vote-*` like everything else here. **Not `DOT_VOTE_*`**, which is the prefix of the MAP vote inside a loaded game — same process, its own rules — and one prefix for both would make one flag change two votes. The layer was claimed by this file and never applied until 2026-09-23; `TmcConfig._layer_vote_overrides` is where it is now, and the selftest asserts the plain prefix does not reach it. `host/tmc_vote.gd` is only the wiring: who counts as a player, who counts as an admin, where the announcements go.

Three decisions in that file are this deployment's rather than dot-vote's:

- **`vote_exclude` takes a game off the ballot.** Empty by default. It is a TMC key
  rather than a `DotVoteRules` one because which installed games a player would choose
  between is a question about this deployment.
- **A game's time limit lives in its own `game.yml`**, under `metadata: vote: time_limit_sec:`. Forty minutes of surf and ten minutes of a small deathmatch are not the same number and never will be, and the alternative is a second table of game ids that goes stale — which this project has already been bitten by twice. **That block was dropped until 2026-09-23**: `TmcContent` built the descriptor's metadata from `kind`, `module` and `directory` and nothing else, so every per-game vote setting anybody wrote was ignored in silence. It is passed through now, and `metadata: map_vote:` rides with it — the game's own map vote reads that as the layer between its code defaults and `user://cfg/<game>_vote.json`. The three keys this host sets win over the block, so it is not a second way to say `module:`.
- **`begin_on_apply` is off.** dot-vote's director would otherwise announce a change
  it made *and* this host would announce the same change through `game_loaded` — which
  is two notifications of one play, two entries in the play history, and every cooldown
  quietly half as long as it says. The host's own signal is the one that is right,
  because it also fires for an operator typing `changelevel` by hand, and a manual
  change has to reset the clock and everybody's rock-the-vote just the same.
  `examples/multigame.tscn` fails if that setting is flipped.

**The game vote is on every player's HUD, and until 2026-09-24 it was chat only.** Its ballot, its countdown and its result still reach chat through `announce_fn`. The countdown to a ballot, the ballot's own time and every `cue` now also go out as dot-server `DotNotice`s, and the shell's `TmcNoticeOverlay` (`client/notice_overlay.gd`) draws the line and plays the cue. It was chat only because the shell talks to a server over exactly two RPC sets, `DotClientLink`'s and `DotClientChat`'s, neither could carry anything but a chat line, and a loaded game's own wire is the game's — this host names no game's classes, and the change the vote causes replaces that wire. The fix was a generic notice pair in dot-server (`broadcast_notice`/`send_notice` → `notice_received`), which moved the signon revision from `c5c1f679edb5` to `b202b914834e`: **every web and native shell built before it is refused by a server built after it**, with "This server needs a different build of the game client" rather than a timeout, until it is re-exported. See dot-server's CLAUDE.md for the pair and why its payload is a dictionary.

Four things about the wiring in `TmcVote`:

- **One HUD line, `NOTICE_TOPIC`, and TmcVote owns it.** Each countdown second replaces it, the ballot replaces it with `!game_vote 1-N` and its time, and the notice's seconds are counted by the client between messages, so it moves smoothly rather than once a second.
- **It is taken down by a poll, not a signal.** `_sync_notice()` runs after every `advance` and clears the line the moment the director is neither counting down nor voting. `DotVoteDirector.cancel_countdown` emits nothing, so a HUD driven only by signals kept counting to a ballot an admin had called off. `shell_notice` gives the take-down one second against a line with thirty left, because the overlay expires a spent countdown on its own and a longer window passed with the clear removed — which is how the first arming of it failed.
- **A late joiner is sent the line that is still true.** Notices go to playing sessions only, so `client_spawned` resends the current line with what is left on it; otherwise a player arriving mid-ballot saw nothing for its whole duration.
- **The cue ids are written twice, by necessity, and checked against each other.** `cfg.example/vote.yml` names them (`tmc_vote_start`, `tmc_vote_end`, `tmc_vote_warning`, `tmc_vote_count`) because the server decides what plays; `TmcNoticeOverlay.sound_catalogue()` has them because the client plays them, and `host/` is not in the client build. `selftest` fails if the template names a cue the overlay has no def for — dot-audio treats an unknown id as silence on purpose, so the drift would be a silent vote for every player — or a def with no synthesised stand-in, since no audio file ships. Real sounds go in `client/sounds/<id>.ogg` and win over the synthesiser one id at a time.

**One game on offer is no game vote.** `TmcVote.install` returns null — no `!game_*` commands, no game clock, no ballot asking the players to choose between the only game and extending it — when fewer than two games are on offer after `vote_exclude`, and the game's own MAP vote is then the only vote on the server. Games are counted **by content id**, not by game id (`TmcVote.votable_count`): hungario's five modes are five game ids over one `tmc/hungry`, and its own map vote is already a vote over those five, so a hungario-only server counted as five games put two ballots over the same choice on every screen. With two or more games both votes run at once — the game vote on its ninety-minute clock, the map vote on the game's own — and that was always supported; the prefix and the two ballot topics are what keep them apart. **And by the name on the ballot**: a box holding the built-in `g2gfast` beside a published `<owner>/game-g2gfast` has two content ids and one game, and that counted as two put "g2gfast or Extend" to the players of a g2gfast-only server (2026-10-07). `votable_count` collapses a choice whose name it has already seen, and dot-vote now does the same on the ballot (a choice named like the running one is not offered) and holds no ballot at all when nothing else is left — at the time it falls due, not only at boot, so a game whose `min_players` the server stops meeting does not leave a ballot of Extend alone either. `multigame` installs it over one game, over one game installed twice under one name, and over hungario alone, and asserts null all three times. **mg-smash-copter and mg-buses-from-hell have no map vote**, so a server running only one of those has no vote at all now, where before it had a game vote over one game; that is the gap, and it is theirs to close.

**The ballot is drawn, and a click votes.** `DotVoteBallotFeed` sends the open ballot as a notice's `data` under `TmcVote.BALLOT_TOPIC` (`game_ballot`) whenever it changes — per playing session rather than broadcast, because each copy carries that session's voter id as `you`, which is how the shell marks the player's own choice — and to a late joiner from `client_spawned`. Every game's map vote does the same under `map_ballot`. The shell's `TmcNoticeOverlay` draws one dot-ui `DotBallotPanel` per topic down the right-hand side: number keys, F3 to free the mouse and click, or both (`ballot_input` in `vote.yml`, the server's choice), and every voter's avatar on what they chose, fetched once per URL and an initial until then. A choice goes back as `/<command> <n>` through `link.send_chat` — the silent prefix, the same command a player could type — so nothing new is on the wire in either direction. With both ballots open the number keys belong to the one opened last. `shell_notice` votes by clicking over a real socket and asserts the server counted it and sent the avatar back; it was armed by unhooking `vote_fn`, and two checks fired. **A shell built before this ignores `data`** and still has the HUD line, so nothing breaks — but nobody sees a menu until the shells are re-exported.

**The template turns it on and existing deployments do not get it by themselves.** `cfg.example/vote.yml` now ships `vote_warning_sec: 10` and `runoff_warning_sec: 5` — at 0 there is no countdown to show, only the ballot's time — and the four cue ids. `cfg/` is never overwritten and setup counts a commented-out key as answered, so a deployment whose `cfg/vote.yml` predates this has the ballot line and no countdown or sound until those keys are uncommented there.

**The overlay does not register its audio manager and does not touch the buses.** A delivered game registers its own `dot_audio` and sets its own bus volumes; a shell that did either would displace the one or reset the other the moment it started. It plays on `Master` because this project declares no bus layout. A game's MAP vote still plays its own cues over its own wire (arena, g2gfast and playground send a `VOTE` event), which is right: that vote is the game's.

**A game that stops its map clock has to stop its vote's clock too.** `content/playground/game.yml` set `pg_map_seconds: "0"` — "runs until somebody votes it out" — and left the vote's own thirty-minute clock running, so the deployed sandbox was put to a ballot at twenty-eight minutes. It sets `metadata: map_vote: {trigger: rtv_only, duration_sec: 0}` now, and `selftest` layers every shipped game's `map_vote` block over dot-vote's defaults and fails for any whose `*_map_seconds` is 0 while its vote still has a clock. Armed by putting the playground back on a 1800-second `time_limit`.

## Roles in, flags out

dot-server's permission model is **flags, not roles**, deliberately: operators do not agree
on what a "moderator" is, and a game adds `slay` without coordinating with anybody. What an
operator writes is roles. `TmcAdmins` is the translation and the only place the two
vocabularies meet.

It is a **source**, not a replacement: `DotAdminManager` merges every source rather than
taking the first match, so a player named here and in a site group gets the union.

**And it does nothing without authentication.** `DotAdminManager.resolve` returns before
consulting any source when a session is not authenticated — a guest uid is a random
per-device string, so granting anything to one grants it to anyone. Correct, and it looks
exactly like the file being ignored, which is why `cfg/auth.yml` says so at the top.

## A server installs its games, and the descriptor was the half nobody published

`./server install-games` and `./server index`, added because a deployment that wants two games should not carry ten and should not need a redeploy to get an eleventh.

**A game is two halves and only one of them was ever published.** The pack on the content origin is the game: scenes, scripts, art, signed, content-addressed, mounted at `res://dot_cloud/<id>/<version>/`. What a pack does not contain is `content/<id>/game.yml` — which scene the *server* runs, which module drives it, how many players it takes, what its cvars are. That file existed only in this repository, so the only way to get a game was to clone the repository, which means getting all ten; and publishing an eleventh reached nobody until every box re-cloned. Decoding `dist/tmc/arena/manifest.json` and looking for `game.yml` among its 212 files is what made this concrete: it is not there, and nothing had ever needed it to be.

`tools/index.gd` publishes the missing half into `dist/`, which is already what gets uploaded — `games.json` plus `descriptors/<id>/game.yml`. `tools/install_games.gd` is the other end: read the catalogue, fetch the descriptors this box was asked for, then `DotCloudClient.ensure` each distinct pack.

**Keyed by directory id, not by content id.** `hungry_classic`, `hungry_frenzy`, `hungry_gauntlet`, `hungry_warrens` and `hungry_reef` are five descriptors over one pack, `tmc/hungry`. A descriptor store keyed by content id gives those five one file, the last write wins, and four modes silently become the fifth. The same fact appears again one layer down: prefetching iterates distinct **content ids**, or the origin is asked for the same 30 MB five times.

**Prefetching without keeping the manifest achieves nothing, and the measurement is the point.** dot-cloud resolves a manifest *before* it consults the store, and a manifest is fetched over the network every time. So a server holding all 212 files of a game, with the origin stopped, exited **7** with `Could not download the content manifest` — a box that could not restart because somebody else's web server was down. `install-games` now keeps each verified manifest under `data/manifests/` and `TmcHost._build_cloud` searches it; the same run then boots offline with `need=0` and exit 0. Found by stopping the local origin, moving `dist/` aside so the developer tree could not stand in for a deployment, and trying it — with `dist/` in place every such test passes, because `dist/` is in `local_search_dirs` and is a mirror of the origin.

**The list has to be a filter as well as an installer.** Installing two games does not stop a content directory that already has ten from offering all ten, and four separate things read that set — the `games` listing, `changelevel`, the vote menu, the boot game. Filtering at any one of them leaves the other three offering a game the panel says this server does not run, so `TmcContent.scan` takes the allow list and applies it once, before a descriptor is built.

**Nothing an operator wrote is deleted.** `--games-mode remove` prunes only ids recorded in `data/installed-games.json` as installed by this tool; a game authored by hand under `content/` is not ours. The default is `hide` — kept on the disk, not offered — because the cost of being wrong in that direction is a directory nobody looks at, and in the other it is somebody's work.

**A `game.yml` already on the disk is never overwritten without `--refresh`.** It is the file an operator edits, and a startup that re-downloaded it would undo their edit on the *following* restart, which is a bug that presents itself days later to somebody who has changed nothing.

**`tools/server.ps1.in` does not have it**, and deliberately: the Windows launcher implements no `TMC_*` environment layer at all — no `TMC_GAME`, no `TMC_PORT` — because it is a developer's front door on a machine somebody is typing at, and every panel and every container this exists for is Linux. `--games` as a filter would fit it; `install-games` would be sixty lines of PowerShell for a case nobody has. Add it when a Windows box is actually installing games, not before.

### Somebody else's game, by `owner/name@version`

`TMC_GAMES=gamemann/game-g2gfast01@1.2.0`, or `@latest`, or no version at all. The site publishes packs under `<owner>/<name>` with a version segment, any member may publish one, and `tmc` is simply the owner reserved for first-party content. Nothing about a game being *ours* is load-bearing any more, which is the point.

**The layout was the mismatch, and this project was the one that was wrong.** dot-cloud's default template has always been `{base}/{id}/{version}/manifest.json` and the site publishes exactly that; `TmcHost` overrode it to a flat `{base}/{id}/manifest.json`, which was right when the only origin was this project's own `dist/` and every pack had one version in it. So a server asked for `content/tmc/g2gfast/manifest.json` and an origin serving the site's scheme answered 403 — S3's answer for a key that is not there when the caller may not list.

Both shapes resolve now. `DotCloudClient.manifest_url_fallbacks` takes extra templates, tried after the primary, per base; the flat form is a fallback because **an origin holds both** — eight imported map packs were published under it and are still the maps a game asks for by name. Re-publishing everything in existence is not a precondition for a server starting.

**The descriptor comes out of the pack, and for somebody else's game it can come from nowhere else.** `games.json` and `descriptors/` are this project's index over first-party content; a member who publishes `alice/her-game` writes no such thing and should not have to. What they ship is their repository, and a game's repository has its `game.yml` in it — so the file is already in the signed pack, addressed by hash. `install-games` fetches the manifest, verifies the signature against a key this server already trusts, finds `game.yml` among the files, downloads that one object and **checks its hash before writing it**. That last check is not ceremony: every other file in a pack is verified when dot-cloud syncs it, and this one is pulled out early by a different path and then written to disk as configuration the server obeys.

**`@latest` is a FILE, because an origin cannot answer a question.** A bucket behind a CDN has no query interface and listing is not public, so a publish writes `content/<id>/latest.json` naming the version it just published. Not derived by sorting: without listing there is nothing to sort, and with listing it would be a sort over version strings, which is how `0.10.0` ends up older than `0.9.0`. Written last, after every object and the manifest, because it is the only mutable document in a tree that is otherwise immutable by construction — and therefore the only one that can point at something incomplete.

**A game can name other packs it needs, and `@latest` is pinned at install.** `dependencies:` in a pack's `game.yml` is a list written like a games-list entry — `gamemann/surf_mesa@latest`, `modcommunity/dot-ui@v0.1.2` — and read through the same `TmcGameRef`. `install-games` resolves each to a version when it installs or updates the game and writes the pinned keys back into the installed descriptor (`stamp_dependencies`, text like `stamp_identity`), and prefetches them. `TmcContent` refuses an entry that still has no version rather than resolving it: a server that resolved `@latest` per join would hand two players two different packs under one game. dot-server fetches them on the server before a change and sends them to clients as `content_extra` in the one `content.sync` (dot-server e496831). A shell exported before that ignores the field, joins, and lacks the packs — so a game that declares dependencies needs a shell exported after it.

**A published game's id is `<owner>/<name>`, and so is its directory.** `gamemann/game-arena` installs into `content/gamemann/game-arena/` and is that game everywhere — `changelevel`, the vote, `TMC_GAME` — so a fork and its original, or two people's games that share a name, sit side by side. It was the name half alone until 2026-09-30, which made `alice/arena` and `bob/arena` one directory: one overwrote the other, and the first fix refused the second, which is the wrong rule for a platform that wants forks. A bare name still works wherever it is unambiguous (`TmcContent.find`, dot-server's `find_game`), and a built-in stays `content/<name>/`. An install from before is MOVED into its owner's directory by `install-games` when its descriptor names that content id, and the egg's prune loop keeps such a flat directory for that one run rather than deleting what is about to be moved.

**One parser, two readers.** `TmcGameRef` exists because `install-games` decides what to FETCH and `TmcHost` decides what to OFFER, and both are handed the same `TMC_GAMES` string. A server that installed `gamemann/game-g2gfast01` into `content/game-g2gfast01/` and then filtered its content directory against the raw entry would find no such directory, report the game missing, and offer nothing — having just downloaded it. The prune had the same exposure in the other direction: it would have deleted that game on every restart, for ever. This project has now shipped "one fact written down twice" three times; this is the third place it could have gone.

**Verified end to end**, against a pack published the way the site publishes one — `gamemann/test-lobby@0.1.0` under `content/<id>/<version>/`, with a `latest.json` beside it: descriptor pulled out of the signed pack, hash checked, written to `content/test-lobby/game.yml`, pack fetched and mounted at `res://dot_cloud/gamemann/test-lobby/0.1.0`, and a server booted with `TMC_GAMES=gamemann/test-lobby@latest` reporting `games: test-lobby` and `selftest ok`.

**And the client that fetched it was never started**, which cost a hang rather than an error. `acquire` and `ensure` start a `DotCloudClient` themselves; `fetch_manifest` and `verify_manifest` do not, and those are what a descriptor is read through. Unstarted, the first has no HTTP client at all — `Nonexistent function 'get_bytes' in base 'Nil'` — and the second would check a signature against a `config_file` that has never been read. dot-cloud has a paragraph about exactly this on `ensure`, written when dot-map hit it from the other side.

### A server that installs its games must build none of them

The install finished, and then put all seven game repositories in `games/` on a box whose panel said `g2gfast`. `setup.sh` clones every game, imports it and publishes it, which was right when a deployment's games came from its own `dist/` and is now seven clones, seven imports and seven packs whose entire output is thrown away — plus a content **signing key** generated on a machine that should only ever consume signed content.

`--only-games` looks like the answer and is a trap. **The addon list is derived from the games being built** — that is what `ADDONS_SHELL` and the derivation beside it are for — so `--only-games g2gfast` wires in the addons g2gfast declares and unlinks the rest. The server then works, until somebody adds `arena` to `TMC_GAMES`: it downloads, it mounts, and every script in it fails to compile against classes this build does not have. A box that decides at RUNTIME which games it runs cannot answer "which addons will I need" at install time.

`--no-games` is the honest form of the question, and the file already had the machinery: `GAMES=()` plus `PUBLISHED_GAMES=1`, which is the existing statement of "do not publish anything" that a release tarball with a populated `dist/` sets. Every guard downstream already reads it — no keygen, no game import, no pack, and the "No games were published" refusal does not fire — and the addon derivation falls back to the full list because there is no game left to derive a shorter one from. That fallback is documented in this file as being for "a build with no game sources at all, because a published pack in dist/ does not say which classes it parses against", which is exactly this case arrived at from the other direction.

Verified on a fresh clone installed the way the egg installs it: `games/` empty, `dist/` empty, `keys/` empty, **54 addons linked**, and then a server booted with `TMC_GAMES=g2gfast` against a local origin — descriptor fetched, pack fetched, module loaded from the mount, selftest ok.

One thing that box cannot do is find a map nobody published: g2gfast's `maps/imported/` is gitignored and travels as one pack per map, so an origin serving the game and not its maps gives a server that boots, reports `could not fetch the map surf_mesa`, and carries on. That is the same on a box that built its own pack, because a fresh clone has no maps either.

### A reinstall is root looking at somebody else's checkout

Every REINSTALL — never a first install — died before it did anything:

```
[install] updating an existing checkout
fatal: detected dubious ownership in repository at '/mnt/server'
```

The install container runs as **root**; wings hands the volume back to the server's own user when an install finishes. So the second install is root opening a checkout owned by somebody else, which git has refused since 2.35.2 — and the refusal is correct, because on a shared machine that is precisely how one user gets another to run hooks they wrote. A first install never sees it, because `/mnt/server` has no `.git` yet, which is why this only ever appeared on the *second* attempt.

`git config --global --add safe.directory '*'` in the egg's install script, and **the placement is the decision**. It is not in `setup.sh`, and must not be: that script runs on people's own machines, where this check is a real protection, and a setup tool that turns it off globally for everyone to fix a container is a setup tool that hands out a foothold. In the egg it is written to root's config inside a container that is destroyed minutes later, it never reaches the server container, and every repository it covers is one this same script is about to create on that volume. `*` rather than `/mnt/server` because setup.sh clones fifty-odd more underneath it, each with the same owner and the same question.

Reproduced and fixed against a checkout chowned to another uid: `fatal: detected dubious ownership` as root without it, and `fetch` + `reset --hard` clean with it.

### The owner was never the problem: the NAME was derived twice

The install after the move died on `could not clone: zee-weapons` — naming a repository that exists under no owner at all, which is why checking the owner would never have found it.

`addon_source` turns an addon's name into its repository by swapping underscores for hyphens, with one exception: `zee_weapons` lives in `zee-dot-weapons`. `resolve_addons` — the function that decides what is MISSING and therefore what gets cloned — spelled the same derivation out again, one line, without the exception. So this machine looked for `zee-dot-weapons` on disk, correctly failed to find it, and then asked GitHub for `zee-weapons`.

Both halves had to be wrong for it to hide this long: on a developer box the pack is already in `addons/.repos/`, so `addon_source` finds it and `resolve_addons` never needs the name it would have got wrong.

**One fact written down twice, which is this project's most repeated bug in its smallest form.** There is an `addon_repo()` now and it is the only place the question is answered. Reproduced on a fresh clone with no addons on disk — `could not clone: zee-weapons`, exit non-zero, the operator's message word for word — then fixed in the same tree: `+ zee-dot-weapons`, **54 addons in addons/**, `./server` written.

It also corrects what the entry above claims. The owner fix was right and was not what was breaking this install.

### And a fresh install hung before it ever got that far

A Pterodactyl install stuck on "installing", with **no log to read**: wings writes `/var/log/pterodactyl/install/<uuid>.log` when the install container EXITS, so a hung install has an empty log directory and a spinner, and the only output that exists is `docker logs -f <uuid>_installer`.

The cause was one missing line in an exception table — a table that no longer exists, because the fix below was the second half of the same lesson. `addon_source` derives `zee_weapons` into the repository `zee-dot-weapons`, and `repo_url` sends everything it does not recognise to `modcommunity` — where **that repository does not exist**; the pack lives under another owner, which is written down in the family map and was not written down here. Checked: `modcommunity/zee-dot-weapons` is 404, `gamemann/zee-dot-weapons` is 200.

**And a 404 over HTTPS is not an error, it is a question.** GitHub answers an unauthenticated request for a repository it will not admit to with a demand for a username, git puts that on the terminal, and the clone loop sends stderr to `/dev/null`. On a developer box there is no terminal, so it fails and lands in "could not clone" — which is what every comment in `setup.sh` describes and what anybody reading it would expect. An install container HAS a terminal. Same code, same repository, and the difference between a warning and an infinite hang is whether something is attached to file descriptor 0.

**The table became a rule, and that is the durable half.** Three names were an exception list keyed on the ones somebody remembered; then every `game-*` moved to the same owner and it would have been eight. `repo_url` now asks the question the family actually answers — **the addons are the organisation's and the games are their author's** — so a name beginning with `dot-` comes from `$GIT_BASE` and everything else comes from the games owner. A game added tomorrow needs no edit, and neither does a game deleted. One exception survives and it is a NAME rather than an owner: `mg-buses-from-hell` is checked out under a directory that is not what its repository is called.

So the specific fix is the owner, and the general one is that no `git` this project runs may ask anybody anything: `GIT_TERMINAL_PROMPT=0` stops git's own prompt, `GIT_ASKPASS` stops it delegating to a helper, and `ssh -oBatchMode=yes` stops the same hang wearing a host-key question instead. Measured afterwards: the 404 repository fails in 0.18s and is reported, rather than waiting for ever.

`./server install-games` in the egg is capped with `timeout` now for the same reason — this family's own rule is that a headless Godot run **hangs** rather than failing, and an uncapped one inside an installer is the same invisible spinner.

### And before that, it filled a 100 MiB /tmp and asked what to do about it

The next install got as far as the runtime and stopped here:

```
    sha512 verified
/tmp/godot-fetch.cwjBJb/x/Godot_v4.7.2-stable_linux.x86_64:  write error (disk full?).  Continue? (y/n/^C)
```

on a host with 201 GB free, which is the detail that makes it look impossible. **A container's `/tmp` is not the machine's `/tmp`.** Wings mounts one as a tmpfs sized by `docker.tmpfs_size` — 100 MiB by default — and `fetch-godot.sh` staged there: a 70 MB archive unpacking to a 146 MB binary, in 100 MiB.

**And `unzip` does not fail when a write fails. It asks.** On a developer box somebody answers; in an install container the question goes to a terminal nobody is reading, and the panel sits on "installing" for ever. The same shape as the credential prompt above, from a completely different cause — which is the lesson worth keeping: **every non-interactive path here has to be non-interactive on purpose, because the tools it drives are all willing to stop and ask.**

Fixed in three parts. The staging directory is now the DESTINATION's filesystem rather than `/tmp` — it is where the binary is going, it was just created and is known writable, and the install becomes a rename inside one filesystem instead of a copy across two. `unzip` is given `< /dev/null`, so a write error is an error again. And a `df` runs before the download rather than after, so "there is not enough room here" arrives in one second with the number in it instead of ninety seconds later as a question.

`tools/fetch-export-templates.sh` had the identical defect with a gigabyte behind it, and has the identical fix. Both were verified against a real 100 MiB tmpfs.

### And the egg could not have started a server

Found while adding the panel variables, not by running it: Pterodactyl installs with the volume at `/mnt/server` and **runs** with the same volume at `/home/container`. The egg puts the runtime on the volume and `setup.sh` bakes its absolute path into `./server`, so at startup that path names a directory that exists only during the install — and `TMC_GODOT_CACHE`, which named it, is not set at startup either. Every remaining candidate in the fallback search was another absolute path or a `PATH` lookup, and the yolks image has no Godot on `PATH`: `no Godot runtime found`, exit 3, on a box with the runtime sitting beside the script. `$PROJECT/.runtime/*/godot` is now in that list, because a path relative to the project is the one form that survives the volume being mounted somewhere else. Reproduced both ways with `env -i PATH=/usr/bin:/bin HOME=/nonexistent`.

### And the startup command named the port in a form the panel does not fill in

The first real panel start crashed in a second with `entrypoint.sh: line 13: ${server.build.default.port}: bad substitution`, exit 1, twice, and then wings stopped retrying. The egg's startup was `./server --port {{server.build.default.port}}` — and that dotted form is the one Pterodactyl uses for **configuration-file parsing**, not for the startup line. The startup line has its own short list (`{{SERVER_PORT}}`, `{{SERVER_IP}}`, `{{SERVER_MEMORY}}`) plus the egg's own variables; anything else is passed through as `${...}`, and the image's entrypoint hands that to the shell, which refuses a name with dots in it. It is `{{SERVER_PORT}}` now. **A server created from the old egg keeps its own copy of the startup command**: re-importing the egg does not change it, so fix it per server (admin → the server → Startup). The `done` string, `server   ready` with three spaces, was checked against a real boot at the same time: dot-log pads the channel to eight columns, and Pterodactyl matches the line as a substring.

## Bugs this project found

Every one parsed cleanly and none produced an error where it was written. Four are in
other repositories.

**The web export shipped every imported map's textures and none of its geometry.** An imported map is a `.json` manifest naming a `.bin` of vertices, and only one of the two is a Godot resource: Godot 4 has a loader for JSON, so every manifest went into the pack, and nothing loads `.bin`, so not one byte of map geometry did. The `Web` preset exports `all_resources`, which means exactly that — every file the engine has a loader for — and `include_filter` is the only thing that carries a file it does not.

What that looks like from a browser is the shape this family has now shipped three times. `G2GBspMap.build_from` reads the manifest first, so the client got a spawn point, a full zone set, a start line, a finish line and a pit, logged every stage correctly, and then found no mesh: a client that connects, signs on, spawns, and draws sky in every direction. It had survived because the only maps anybody had loaded in a browser are the three built in **code**, which are a scene and a script and can therefore never fail to be there — this tree's own "a code path only one deployment shape reaches", with the deployment shape being the one a player uses.

`export-web` now greps the built pack for every `maps/**/*.bin` on disk and refuses to finish if one is missing, rather than trusting a filter to keep working. The pack goes from 22 MB to 59 MB, which is the honest cost of eight imported maps: a client that lacks one cannot follow a `changelevel` to it.

**In dot-net — `Array.sort()` on a `StringName` does not sort lexicographically.**
Godot compares StringNames by their interned pointer, which is whatever order the names
happened to be created in. `DotNetMessageRegistry.seal()` assigned wire ids from that sort,
so **two peers gave the same message type two different ids** and computed two different
schema hashes. Nothing errors: each end encodes correctly and decodes the other's message
as a different type, or refuses it.

Invisible to every suite in the family, because they all run both ends in one process —
sharing one intern table and therefore one order. A browser client is the first peer that
is a genuinely separate program, and it disagreed immediately: server `8a9acd7731ef`,
client `861a4fd82a45`, for the same two types. a game's `headless_net` asserted the
order is lexicographic, which catches it without two processes.

**In dot-core — `isSecureContext` is not "the page is HTTPS".** A browser treats
`http://localhost` and `http://127.0.0.1` as trustworthy origins, so `isSecureContext` is
true on a plain HTTP page served from either — while mixed-content blocking, which is the
rule that actually decides whether a `ws://` socket may be opened, exempts exactly those
origins. `DotTransportWebSocket` asked the wrong one, upgraded every development page's
`ws://` to `wss://`, and failed against a server with no certificate. Which is every
server anybody tests against locally, and is the reason nothing in this family had ever
loaded in a browser. `DotWeb.is_https_page()` is the right question.

**In dot-server — the audit log never opened.** Every subsystem is a `DotNodeRef`
defaulting to `of_created(...)`, and a created node has already run `_ready()` by the time
`DotServer` assigns its config — which is why `admins.load_admins()` is triggered
explicitly. The audit log was the one that was missed: `_ready` found no config, took the
"no audit log path" branch and returned, and nothing opened the file afterwards. So in
every default configuration **no administrative action was ever recorded**, and the audit
trail is the record a moderation dispute is resolved from. It warned about it on every
boot, which is what hid it: it reads like a setting nobody had filled in.

**In the RPC routing — Godot addresses an RPC by the receiver's path relative to its
`MultiplayerAPI` root.** With the default root of `/root`, a `DotServer` at
`/root/Host/Server` sends calls addressed to `Host/Server`, and a client whose
`DotClientLink` is at `/root/Shell/Server` answers every one with "Node not found". Both
ends now scope an API to their own subtree, so both send and expect `Server` and neither
has to know what the other's scene is called.

**Here — `set_anchors_preset` does not set offsets.** The anchors describe how a rectangle
should follow its parent and change nothing until something resizes it, so a `Control`
built in code kept the zero size it was created with. Every child laid out inside nothing
and the entire interface was invisible while being, by every property, correctly
configured.

**Here — a symlinked addon dangles the moment the directory moves.** `setup.sh` links the
siblings, which is right on a developer's machine and wrong in a container's final stage or
a release tarball. The symptom is every dot-* `class_name` unresolved at once, which reads
as a broken project. `--vendor` copies instead.

**Here — Godot headless still links `libfontconfig`.** The headless display driver draws
nothing and the binary loads fontconfig anyway, so the container died before running a line
of GDScript.

**Here — a container running as an arbitrary uid has no passwd entry**, so `$HOME` is `/`,
Godot cannot create `user://`, and it crashes with a signal 11 several errors later.

**Here — a builtin game must name no client scene.** Exactly the trap dot-server's own
CLAUDE.md describes. `TmcContent` refuses one rather than passing it through, because the
failure it causes — a client that never reports loaded and is timed out for being idle —
gives no hint where it came from.

**`demo.sh switch` could reach one of its five servers, and `rcon.mjs` had taken `--port` since the day it was written.** The script stands up five servers, names their ports in five pairs of variables, and then hardcoded `$GAME_PORT` in the one command that changes what is running — so the surf timer, the sandbox and the deathmatch were administrable only by a `node tools/rcon.mjs --port ...` line typed by hand, which is exactly the knowledge a script like this exists to hold. The capability was there, the caller was there, and the argument between them was never passed. This tree's own "a value produced correctly and consumed by nothing", arriving as an option nobody handed over.

There was also **no way to change a MAP at all**, on any of them. dot-server gave the plain name `map` to dot-map deliberately, and every game registers its own under its own prefix — `g2g_map`, `pg_map`, `arena_map` — so there is no single command to send and `demo.sh` had none of them. A game change swaps the module, the netcode and the client's scene and puts everybody through signon; a map change swaps the world and nothing else and is what an operator means nine times in ten. The script could do the first and not the second.

**`./server` documented exit code 6 for "port in use" and had never returned it.** A dot-server that cannot bind exits with Godot's own code and one line in the middle of its boot log, so a supervisor reading these codes — which is the entire reason they are documented — restarts it forever against a port somebody else owns. Both launchers check now, and both check the **RCON port as well**: it is the game port plus one, two servers a single port apart collide there and nowhere else, and the message the loser prints names a port `ss` says is free. `demo.sh` has three paragraphs warning about precisely that collision, and the launcher it warns you about could not detect it.

**The Windows launcher was a nine-line batch file, and the README described the Bash one.** `server.cmd` understood `check`, `config` and `games` and handed everything else to Godot unread, so `--port`, `--bind`, `--name`, `--max-players`, `--game`, the directory flags, `--godot`, `--dry-run`, the `--` passthrough, the runtime version check and the refusal of a secret on the command line existed on Linux and macOS and not on Windows. Nothing could report it: every one of those options was correct, tested and reachable — from the other script. `server.ps1` is the launcher now and `server.cmd` forwards to it. Reviewed rather than run: there is no PowerShell on the machine this was written on, which is a weaker claim than anything else in this repository makes.

**`./server check` printed `selftest ok` over a game module that never compiled.** On a fresh clone `./setup.sh --only-games <one game>` left `addons/dot_game` unlinked; that game's module logged `Could not find base class "DotGameModule"`, and the check passed. A script that fails to parse takes no exit path: Godot logs it and hands back a script nothing can instantiate, dot-server's `load_module` called `.new()` on it and aborted its coroutine, the host awaited null, read `.ok` off it and aborted too, and the boot carried on to the end. Two fixes, each armed on its own. dot-server's `load_module` checks `can_instantiate()` and returns a failed result (dot-server 004e8f2), so the host's existing "module did not load" exit fires. And the host installs `TmcScriptWatch` — a `Logger` on the engine's own log — for the length of a selftest and fails it with exit 7 on any script error or any `Parse Error` / `Could not find base class` / `Failed to load script`, which also catches a broken script that is NOT the module (a server scene's, which loads with its script silently missing). `tools/check_boot_failures.sh`, run by `check.sh`, boots both shapes through the real launcher and requires both refused. It cannot catch a parse failure in `host/tmc_host.gd` itself: the scene then runs no script and never quits, which is why the cases are capped with `timeout`.

**Nothing checked the SERVER side of a join, and one probe said it did not happen.** `reconnect` waited for the client's `PLAYING` and called it "the server admits them", but `DotClientLink` enters `PLAYING` itself, on the line after it sends `loaded`, with nothing coming back. A 2026-09-14 probe of this exact shape — a `TmcHost` and the real `client/shell.tscn` in one process, over a loopback WebSocket — saw the client in `PLAYING` and the server's session in `LOADING` for ever; two processes joined fine. `reconnect` now also waits for a server session in `SPAWNED` on both connects (16 -> 18). **On today's code it passes every time** (six of six runs on 2026-09-27): the probe's RPC, `report_loaded`, went away with dot-server 52fe6bd's six envelope lanes, and the in-process shape spawns on the server like two processes do. Why the old per-method RPC was lost in one process was not established, and cannot be now without rebuilding the 09-14 tree. The check is armed: with the client's `loaded` send removed it reproduces the probe's states exactly (client `PLAYING`, server `["LOADING"]`) and fails on only these two lines, while every older check passes — which is how the old suite had been passing over it.

## What the web player signs in against, and why it is a file

`client/auth.json`, shipped inside the export, read by `_sign_in()` and gitignored
because it is a deployment's answer rather than this repository's. `demo.sh` writes it
before the export.

**A browser has no environment and no argv**, so `DOT_AUTH_BACKBONE_URL` — how every
other deployment sets this — cannot reach a web client. Without a file it gets whatever
`DotAuthConfig`'s exported default happens to be, and that default was a domain nobody
owned (see dot-auth's CLAUDE.md). Same shape and same reasoning as `client/content.json`:
a shipped file rather than the page's query string, because this URL decides where a
single-use sign-in code is redeemed and a link that could aim it elsewhere would be a
credential-forwarding link.

It is the **site** origin, not the game origin. Those are deliberately different
registrable domains — the game origin is where the engine is *served from*, and the
sandbox exists to keep the site's cookies and storage away from it. Pointing the
backbone there would send the site's own handoff codes to the domain that separation
exists to protect them from.

**And the shell was asking for the wrong thing.** It called `DotAuthClient.sign_in()`,
which tries the page handoff, then a stored session, and then falls through to
`start_device_login()`. So a shell opened as a bare link — every standalone embed, every
development page — started a *device-code* login: two requests to the backbone on every
page load, for a flow this shell has nowhere to display a code and nobody will ever
read. `_sign_in()`'s own comment had said "there is no code, `sign_in()` fails
immediately" since it was written; that was the intent and not the behaviour. It now
calls `try_web_handoff()`, which is the only sign-in this shell was ever meant to do.

Those two failing requests were also what made the wrong domain visible at all.

## The games are published, and the packs are checked

### A real client in a delivered game

`examples/smash_client.tscn`, 40 checks, in `tools/check.sh`. The multigame suites boot buses and switch to hungario, where a mount which half worked could still look right. This one connects to a 3D game whose map is rebuilt every round out of a pack, and asserts the whole delivery path from the operator's end: the pack mounts at the prefix the game computes, the module's script is the mounted copy rather than a built-in one, the world describes itself with platforms and its own gravity, a round starts and the cannon puts something in the air, the client rebuilds a field of its own, and the game's own console command still answers afterwards. **Since 2026-09-26 it does all of that as two builds**: the client and the server each register an envelope kind the other lacks before the join (see dot-server's `DotEnvelope`), neither sends the other what it lacks, each drops what is forced onto the wire anyway, and the round runs over it. Its last section hands the server's game netcode the schema of a client that cannot play this game and asserts the client is disconnected with dot-net's sentence as `CODE_VERSION` — which found that a kick from outside an RPC handler never delivered its reason at all (dot-server's `_close_peer`), and that smash's bridge cast freed bodies when a client left mid-round.

**Refusals the shell says in words.** `CODE_VERSION` in a disconnect is a kinds or message-types mismatch between two builds that share a signon revision — the shell shows the server's sentence ("This server needs a newer game client.") rather than the build-mismatch message, which would name the same revision twice. `_cloud.host_role` is `"client"` in the shell and `"server"` in `TmcHost`, so a pack whose `requires.json` asks for more than the build has says which side is behind. `tools/install_games.gd` builds its own `DotCloudClient` and leaves the role at `"build"`; set it there too when that file is next touched.

**It is written entirely by duck typing, because this build cannot name a type the pack declares.** The world is `module.get("game")` and everything asked of it goes through `describe()`. That is not a workaround: it is the same bargain every module in the family makes with dot-game, and the reason a game exposes `describe()` at all.

The first boot of that game against a real server found four things, and not one of them is reachable from inside the game's own project, where its files are at `res://` and its `class_name` globals are registered: a path the publisher had already rewritten being rebased a second time, a combat manager setting itself up twice, lag compensation reporting as unwired on a server where it works, and dot-match warning once per player per round about a game that places its own players.

**Its fixture turns the stdin console off**, which is worth knowing before writing another one. dot-server's reader is a thread blocked in a read the engine cannot cancel, so a suite that shuts the server down while stdin is still open leaves the thread to be destroyed unjoined — one "Thread object is being destroyed" warning with a full backtrace, at the end of a run that passed. That trade is the right one for a real server, where the alternative is a ctrl-c that hangs until somebody presses enter.

**There are six games now.** `mg-buses-from-hell` was added on 2026-09-14 — the first asymmetric one, and the first that vendors art, which is how the sixth form of the mount constraint above was found. It is also the first game in the family whose module subclasses `DotGameModule`, so `addons/dot_game` is in the addon list: a delivered module `extends DotGameModule`, and a base class the host build does not carry is a module that cannot parse. The symptom is *"Could not find base class"* once, at load, followed by a server that admits players into a game with no netcode in it.

**This build contains no game.** `setup.sh` turns each sibling repository into a signed
dot-cloud pack in `dist/` — `./server pack <id> --source ../<repo>` — and the server finds
it there by content id, with no URL anywhere. A client downloads it on connect. The list
is `setup.sh`'s `GAMES` and this sentence is prose about it, not a second copy;
`tools/check.sh` and `tools/package_check.sh` both READ that list rather than repeating
it, which is the fix for the time all three had gone stale together.

It was not always so. For most of this project's life the five games were **copied** into
one `game/` and one `scenes/` at the project root, because a `.tscn` stores its script
reference as an absolute `res://` path and there is no relative form — so a game's own
`maps/` had to become *this* project's `maps/`. That worked, and it meant a new game was a
new build of the engine: an export, an upload, and every player on the old build unable to
join. Closing the five forms of the mount constraint above is what made the other
arrangement possible, and `pack.json` beside each `game.yml` is where a game says what not
to ship.

**What the source of a pack is, and why it is the repository.** Not a directory here: the
old arrangement merged all five games into one `game/`, so no directory in this project
*is* any single game — the files are separable only by their name prefix, and an `include`
list copies directories and files, not globs. `--source` names the repository and
`game.yml` still supplies the id, the version and the entry scene, so nothing is said
twice.

**A pack is named for its CONTENT id, not its directory.** Those are the same almost
everywhere and where they differ it is load-bearing: hungario is three game ids over one
`content_id: hungry`. Everything that looks a pack up builds
`{base}/{content id}/manifest.json` and `dist/` is one of those bases, so `dist/hungry_classic/`
would have been a pack nothing — not the server that wrote it — could find.

**Imports happen before publishing, and that ordering is the whole of it.** A `.glb` or a
`.png` is not a loadable resource: the editor imports it into `.godot/imported/` and the
`.import` marker beside it redirects every load there. Nothing imports at runtime, on any
platform. So `setup.sh` runs `--import` in each game repository before packing it, and the
publisher ships the imported form and the markers — with the three absolute paths inside
each marker rewritten onto the mount. Without that a pack carries the bytes of an asset
nothing can open and reports nothing, because the file is right there:

```
character-a.glb    exists=false  file=true   load=null
arena.tscn         exists=true   file=true   load=PackedScene
```

The failure this still allows is a **stale pack**, and it is invisible from either side: a
game is fixed in its own repository, `setup.sh` is not re-run, and this server keeps
serving the old pack. Both suites pass, because each tests the code it has — the game's on
the fix, this one on what an operator actually deploys. It is the same shape as every
other bug in this family that hid behind a suite that was genuinely passing.

`tools/check.sh` compares the manifest's timestamp against every source file in the
sibling and fails on anything newer. **Timestamps rather than contents**, because the
publisher rewrites every `res://` reference in a `.tscn` onto the mount prefix — a
correctly published file is deliberately *not* byte-identical to its source, so the
comparison the old copy-checker did cannot be made here. It also fails if `game/`,
`scenes/`, `maps/`, `avatars/`, `npcs/`, `props/` or `textures/` exists at all: a vendored
copy left over from an older checkout would win over the delivered one for players on this
build and for nobody else.

Where there is no sibling to compare against — a release tarball, the container's final
stage — it says so and does not fail, and `setup.sh` keeps whatever is in `dist/` rather
than trying to republish, because a deployment should not be holding the signing key.

### A stranger's game, the way a stranger ships it

`examples/template_client.tscn`, 21 checks, in `tools/check.sh` after smash_client. smash_client publishes with this project's own `./server pack` from a checkout; a third-party developer ships something else — the `-pack.zip` their release workflow attaches, which the site signs under `<site username>/<repo>` — and that artifact had never been mounted by anything here. So this one takes `dot-game-template` (the repository a developer copies to start a game), packages its git HEAD with `../dot-ci/scripts/package.sh --pack --name dot-game-template` exactly as its release does, unpacks the zip and publishes it with `DotCloudPublisher` under `someone/dot-game-template@0.0.1` with a key made for the run and trusted by that run's `content.json` alone, stamps the pack's own `game.yml` with `install_games.gd`'s `stamp_identity`, boots a real host on it, joins a real client, and steers the template's client scene at a coin until the server scores it and the client shows the score. It says "skipped" and exits 0 when the template or dot-ci is not beside this project.

**It packages HEAD, so commit the template before believing it.** Armed with a scratch clone whose bridge was reached by `class_name` rather than by `preload`: the mount fails with `Identifier "TplBridge" not declared`, the section aborts, and the two counters fail the run. Its first armed run also found that the artifact is named after the checkout's directory unless `--name` is passed — the reason the release workflow passes the repository's name — so the suite passes it too.

### A game whose courses are a second pack

`examples/wipeout_client.tscn`, 26 checks, in `tools/check.sh` after template_client. mg-wipeout's courses are not in its pack: `content/wipeout/game.yml` names `tmc/wipeout_maps@0.1.0` under `server_dependencies`, and `content/wipeout_maps/` publishes mg-wipeout-maps as that pack (setup.sh's `GAMES` carries it as `mg-wipeout-maps:wipeout_maps` — a content directory with a `pack.json` and no `game.yml`, so it is published and never offered). It is the **first user of `server_dependencies`** in the family, and the failure it exists to catch is silent: a mount prefix the game computes wrongly gives a server that plays the one practice course built into the game. So it asserts the dependency is listed, mounted where the game computes, read (11 courses, 6 arenas), played (a round on a delivered course), that the client — which was never sent a course file — built the same course with the same number of pieces from the STAGE document, and that a forced final death crosses with the same arena and the same pickups on both ends. **Armed**: with `server_dependencies` removed, seven checks fail and nothing else does.

`examples/deathrun_client.tscn`, 19 checks (2026-10-06), in `tools/check.sh` after wipeout_client: mg-deathrun the same way, `content/deathrun/` naming `tmc/deathrun_maps@0.1.0` (mg-deathrun-maps, `content/deathrun_maps/`) under `server_dependencies`. It asserts the courses are mounted where `DrModule._add_delivered_courses` computes, read (3 with the built-in practice one), that a round runs with stand-ins, that the client built the server's course with the same number of traps from the document it was sent, and that `dr_courses` lists both delivered courses. Not in setup.sh's `GAMES` yet (nor are delivery and lookatme): that list is what a production box publishes, and none of the three is released.

`examples/prophunt_client.tscn`, 22 checks (2026-10-09), in `tools/check.sh` after deathrun_client: mg-prop-hunt the same way, `content/prophunt/` naming `tmc/prophunt_maps@0.1.0` (mg-prop-hunt-maps, `content/prophunt_maps/`) under `server_dependencies`. Beyond the maps it asserts what is new in this game's pack: the prop catalogue (`props/catalogue.json`, 163 measured models) and the taunt list are read from inside the game's own mount, and the client's catalogue knows every prop id the delivered map names (a missing one is built as nothing, silently). **Writing it found two things, neither in the game.** This checkout had no `addons/dot_menu` link (setup.sh's list gained it on 10-09, nobody re-ran it here), so every delivered client since the dot-menu rollout fails to parse its settings on join; and the class cache was stale for the new dot-props, dot-team, dot-fx and dot-game classes until `--import`. Both are local and fixed by `setup.sh` / `--import`; a production shell needs the same (see the dot-menu rollout). Not in setup.sh's `GAMES`: nothing is released.

`examples/playground_client.tscn`, 21 checks (2026-10-07), in `tools/check.sh` after deathrun_client: game-playground's custom maps (game-playground-maps, `content/playground_maps/`, `tmc/playground_maps@0.1.0`) as the family's **first client `dependencies`** — not `server_dependencies`, because a playground map is a document of boxes and props that the client builds too. It asserts the pack is a client dependency the client was told to fetch, mounted where both ends compute, that BOTH catalogues list `pgc_town` from that mount, that a change to it is followed by the client with every static box built (166 on each end), that the map's props (44, five doors on buttons) are the server's drawn on the client with none of the client's own, and that `pg_status` names it. **Armed** by removing the `dependencies` line: ten fail. **Writing it found two packing bugs, both in `content/playground/pack.json`.** (1) `exclude_dirs` matches a directory name at ANY depth, so `"tools"` (meant for the repo's dev scripts) also dropped `game/tools/`, every tool-gun mode: the tool gun has been broken in every delivered playground since it was added (2026-10-05), and a preload added on 10-07 made the whole game fail to load ("No Playground is registered"). Fixed in game-playground by renaming the directory `game/toolgun/`; a scan of every other pack found no other nested directory an `exclude_dirs` entry catches by accident (g2gfast's `maps/imported` is excluded on purpose). (2) The game pack followed the `maps/custom` link and shipped its own copy of the maps, which shadowed the maps pack on both ends (an id already in a catalogue is never replaced), so a maps update would never have reached anybody. `custom` is in `exclude_dirs` now. **Release order**: create `gamemann/game-playground-maps` and publish `playground_maps` BEFORE a playground whose game.yml names it, because a game whose dependency cannot be fetched is not loaded at all (`DotGameManager._acquire_content` abandons the change); and the playground pack still waits on the 10-06 shell rebuild (new dot-player-controller and dot-props). setup.sh's `GAMES` carries `game-playground-maps:playground_maps`; a clone that fails there is only a warning, which is exactly how a playground naming an unpublished pack would reach a box.

Teardown prints one engine `ERROR: Condition "ready_state != STATE_OPEN"`, from dot-net sending a snapshot in the tick its peer closed. smash_client's game has the identical send path; it is dot-net's, not this game's.

### It went stale, and so did the guard

**Both halves of that arrangement had gone stale at once, and each hid the other.**
`setup.sh`'s list still named `dot-2d-hungry`, renamed months ago to `game-hungario`. So it deleted `game/` and `scenes/` (the wipe
came first), warned twice about repositories it could not find, and died with "No games
were found beside this repository, and none are vendored" — having just made that true.
Whatever was in the tree was whatever the last successful run had left, nine days old.

And `tools/check.sh`, the guard against exactly that, **repeated the same list** under a
comment saying it must not: "The list is setup.sh's, and it has to stay setup.sh's." It
had the old names too, found no siblings, and printed the release-tarball line — "no
game repositories beside this one; staleness not checked" — on a developer's machine
where all three were sitting right there. A guard that reports the healthy case when it
is broken.

Both are fixed the way the comment always intended: `setup.sh` resolves every source
*before* it removes anything and refuses a partial set, and `check.sh` now READS the
list out of `setup.sh` rather than holding a second copy of it.

What that un-staling then exposed: the current `hungry_module.gd` declares its
statistics through `DotStatsSchema`, and `dot_stats` was not in the addon list. Every
type reference in the module became a parse error, a module that will not parse does
not load, and `changelevel hungry_classic` swapped the world while leaving the previous game's
module driving it — with the failure visible only as `Could not find type` lines
scrolling past during a scene change.

## The runtime is fetched now, and the verification is the whole point

`setup.sh` used to stop on a fresh machine with "no Godot runtime found", and the reason it gave was that fetching a binary means verifying a signature, which is a different program with different risks. The reasoning was right and the conclusion was backwards. It made the first step on every new box a manual download from a browser, on a machine that may not have one — and the thing it was avoiding, which is *verification*, is about thirty lines. So the different program was written: `tools/fetch-godot.sh`.

**Three rules, and they are the entire value of it:**

- **One version, pinned.** `GODOT_VERSION=4.7.2-stable`, not `latest`. A digest only means anything against a file that cannot change, and `latest` changes.
- **The digests are in the script, in git, reviewed by a person.** They are deliberately *not* read from the `SHA512-SUMS.txt` served beside the binary: a checksum fetched from whoever served the zip is checked by whoever would have had to tamper with both, which is one party and therefore no check at all. Trust was established once, by hand, at the version bump; every run since is an equality test against what is checked in.
- **A mismatch deletes the file and exits non-zero.** There is no `--force`, no "checksum unavailable, continuing", and no path through the script that installs something unverified. The digest also gates the *unpack*, not just the install — a zip is parsed by a C library before anything is executed.

It lands in `~/.cache/tmc/godot/<version>/godot` rather than in the project, so one download serves every checkout on the box and `rm -rf` of a deployment does not cost 150 MB. `TMC_GODOT_CACHE` moves it, and a home directory that cannot be written — a container running as a uid with no passwd entry, which this project already handles elsewhere — falls back to `.godot-runtime/` in the project.

**`--no-download` (or `TMC_NO_DOWNLOAD=1`) restores the old refusal**, for a box with no network or a policy that says binaries arrive one way and it is not this one. An explicit `--godot` never downloads either: a wrong path that quietly became a fetch would be a script ignoring the argument it was handed, and the operator would never learn that the runtime they meant to test was not the one that ran.

**It runs the binary before it reports success, and that check earns its keep on exactly the machine this is for.** Godot links fontconfig at *load* time even though `--headless` draws nothing, so on a minimal server image it dies with `libfontconfig.so.1: cannot open shared object file` before a line of GDScript — the same hole the container hit, which is documented in the Dockerfile. The fetcher reads the missing library out of the failure and prints the `apt-get` / `dnf` / `pacman` line for it, because "cannot open shared object file" on a freshly downloaded binary reads as a bad download and is not one.

**The Dockerfile no longer has its own copy of the download.** It had one, pinned to its own `GODOT_SHA256`, and two pins drift: the image and the host would have been running different engines with nothing saying so. Stage 1 copies `tools/fetch-godot.sh` and runs it with `--dest /usr/local/bin`.

`setup.ps1` does the same thing for Windows with its own digests, because there is no Bash there to share. It takes the **console** exe out of the archive rather than the plain one — the plain Windows build detaches from the console that started it, so a headless server started by the launcher would print its log nowhere.

## The native client, and the four things it turns on

`./server export-native` builds the shell for Linux, Windows and macOS, writes one archive per platform into `build/`, and prints the command that publishes each one. It exists because the desktop app installs a *file* and there was nothing to give it: `export_presets.cfg` held exactly one preset — Web — so the browser was the only way anybody could play anything on this platform, and the app's Games tab was right to report that nothing was published for this machine.

**The presets are tracked now, and they were not before.** `export_presets.cfg` is written and rewritten by Godot's editor, so it is gitignored for the same reason `cfg/` is — and the consequence was a build command that only worked where somebody had made a preset by hand. `export_presets.example.cfg` is the tracked copy, `setup.sh` and `setup.ps1` copy it in when there is none, and neither ever overwrites one that exists: a preset file is something an operator may have adjusted, and a regenerating upgrade throws that away on the one run nobody is watching. It is the `cfg.example/` rule, applied to the other file the editor owns.

**The launch arguments need the bare `--`, and that is the part worth remembering.** `client/shell.gd` reads the address from `OS.get_cmdline_user_args()`, which is *only* what follows a `--` on the command line. Godot 4 **silently ignores an argument it does not recognise** rather than refusing to start — measured, not assumed — so `tmc.x86_64 --connect 127.0.0.1:6099` launches perfectly, renders the menu, fills in nothing, and connects to nothing. The published argument template is therefore `--,--connect,{host}:{port},--udp,{host}:{udpPort}`, and the desktop app's own builder drops a pair cleanly when its value is missing (no server chosen, or a server with no ENet port). `{udpPort}` is the server's own A2S `udp:<port>` keyword: spy records it as `meta.enetPort` and the site's app API hands it to the desktop app as `udpPort` (2026-10-09, `[native-udp-launch-1]`). Without it a native client tried UDP at the join port, which behind nginx is the TLS port, and fell back to WebSocket after 2.5 s. A version of this that "works on my machine" and joins nothing is one comma away.

**One file per platform, because an install is a download.** `binary_format/embed_pck=true` puts the pack inside the executable, so there is no second file to lose or to mismatch, and the archive then holds exactly one entry — which is exactly what `--entry` names. The zips carry the mode bits, so the binary arrives executable rather than arriving and failing to start with a permission error that reads like a broken download.

**It is the client, not the server.** Every preset excludes `host/*`, the same way the Web one does. `client/shell.tscn` is the main scene, a player who double-clicks gets a menu and a server address, and an operator runs `./server`. A native build that could also host is a different product and would ship a different preset.

**It publishes under the ENGINE app, for the reason the web build does.** A server hangs off `godot` rather than off a game, because it can change which game it is running while players stay connected — so a Play press resolves the build from there. Publishing the same 80 MB shell again under each game app buys a Library entry per game and costs a copy per game; do it when somebody wants the games listed separately, not by default.

Two engine facts came out of getting macOS to export at all, and both are in `project.godot` rather than in the preset:

- **A universal or arm64 macOS export is refused while `textures/vram_compression/import_etc2_astc` is off.** It is an import setting for VRAM-compressed textures and this project has none — `compress/mode=2` appears in no `.import` file — so turning it on reimports nothing and adds nothing to any build. The alternative was an x86_64-only build published under a column that says `MACOS_UNIVERSAL`, which is a row that lies.
- **The `.app` bundle is named from the project name**, and this project's name is the *server* tool. `config/name.macos="TMC"` is a feature-tagged override — the exporter resolves project settings through the preset's feature tags — so the bundle is `TMC.app` and the entry is `TMC.app/Contents/MacOS/TMC` rather than a path with a space in it and the wrong word.

Verified by running, on this machine: all three exported, the Linux archive unpacked the way the app unpacks one, and the binary joined a real `./server` — admitted, spawned, in the match, HUD drawing — with the address arriving through `-- --connect`.

### Two bugs this found in the launcher

- **`warn` was called twice and defined nowhere.** Both of `export-web`'s map checks end in `|| warn "..."`, so the message about a build carrying 66 MB it did not need was `warn: command not found`. The condition is rare, which is why nobody hit it, and rare is what a warning is for.
- **The PowerShell launcher's map check asserted the opposite of the bash one's.** `tools/server.ps1.in` still carried the version from when the build was supposed to *contain* map geometry, so a Windows operator running `export-web` got "8 map geometry file(s) did not reach the export" and a dead stop on a build that was correct. Both now call one function that checks the two things that are actually true, and the fix that message names points at `maps/imported` — `./server pack <id>` alone publishes `content/<id>`, where no imported map has ever lived.

`tools/server.ps1.in` has one more divergence of the same shape, **not** fixed here: its `pack` still runs `res://tools/publish.tscn`, the scene that was never written and that the bash half stopped naming when `./server pack` was rebuilt on `tools/pack.gd` and dot-cloud's CLI. It needs the signing key, the content directory and the `--all` handling that the bash one grew, which is a port and not a patch.

## Validating

```bash
tools/check.sh              # parse, shell syntax, every suite, then a real boot
#                             `./server check` also asserts the operator's console:
#                             `log`, `sec_status`, `sec_why`, `party_status`,
#                             `mm_status` and `replay` on a server that booted, RUNS
#                             party_status, and fails if the replay ring is not recording.
tools/check_boot_failures.sh  # two boots whose game cannot compile; ./server check must refuse both
tools/package_check.sh      # the same thing in the shape an operator unpacks
```

`examples/admin_loading_selftest.tscn` (149) and `examples/admin_live.tscn` (28) are the admin menu and the loading screen; see their section above.

`examples/selftest.tscn` covers the YAML reader, the config translation, the permission
translation, the content index, the game vote's HUD cues, the sink layer, the guard, the replay ring and the friends client against fixtures in
`examples/fixtures/` — 218 checks across 14 sections. `examples/shell_notice.tscn` (31 checks) is the game vote on a real shell's HUD over a real socket, menu and click included; `multigame` (72) hears the same notices at the server with nobody connected. Those fixtures
are asserted on value by value, so changing one changes a check — which is the point: they
are the exact keys an operator writes, checked against the exact settings they are supposed
to reach.

`./server check` is the other half: a real `DotServer`, a real listener, the default game loaded
and its module in it.

`tools/package_check.sh` runs in the configuration this project is **shipped** in rather
than the one it is developed in. `check.sh` sees seventeen symlinks in `addons/` and
every game resolving, through `games/` or beside it; a release tarball and the
container's final stage see neither. It exports the tracked files only, runs `setup.sh --vendor`, moves the result
away from the siblings, and then checks that nothing points back out of the tree, that
`addons/` holds real directories, and that it boots.
It also reaches the one branch of `check.sh` a developer checkout never can: with no
sibling to compare against the staleness check reports `--` and must still pass,
because there the copy is the only record there is.

It does not build the container — that needs a Docker daemon. Everything else about the
packaged shape it does cover.

**`tools/browser_check.mjs` is the one that matters and the only one that can see the
browser.** It loads the export in a real Chromium, connects it to a real server, and
reports the WebSocket, the console and a screenshot. Three of the bugs above are its, and
none of them was reachable any other way.

## The addons come from inside this project now

`setup.sh` used to require the fifty dot-* repositories **beside** this one, and to clone them into the parent directory when they were not there. That is the right shape for a developer checkout, which is what dot-bootstrap makes, and the wrong default for the machine this project is for:

- **It writes into a directory this project does not own.** A `git clone` of dot-server-deploy into `~/` puts fifty repositories in `~/`, which nobody asked for and nothing cleans up.
- **Several servers on one box share one set of clones without saying so.** Pulling for one changes all of them, at whatever moment each next restarts — and "the fix is installed and still not running" and "a server nobody touched changed" are the same arrangement seen from two ends.
- **Every link points out of the tree.** Move the directory and all fifty dangle at once, which surfaces as every `dot-*` class_name unresolved and reads as a broken project. `--vendor` exists for exactly that, and having to know about it was the flaw.

The default is now inside: a missing addon is cloned into `addons/.repos/<repo>` and `addons/<name>` is a **relative** link into it. The tree can be moved, tarred, `cp -r`d or COPYed into an image's final stage and still resolve. `.repos` is hidden from Godot twice over — the leading dot, which its scanner skips, and a `.gdignore` written before the first clone — because each of those directories is a whole repository with its own `addons/<name>` in it, and scanning both halves means every class_name in the family arriving twice.

**`--addons-dir DIR` is the old behaviour, asked for by name.** It takes a directory of addons (`DIR/dot_core`) or a directory of the repositories (`DIR/dot-core/addons/dot_core`) — both, because guessing wrong is a silent re-clone of fifty repositories the box already has — links what it finds there with an absolute path, and clones what it does not find *into that directory*, since that is the point of sharing one. `--addons-dir ..` is exactly what this script did before. `TMC_ADDONS_DIR` is the same switch for a unit file or a CI job that cannot add an argument to a line somebody else wrote.

**An existing link that still resolves is left alone, and that rule is what makes the change safe to pull.** Every box set up before this, and every developer checkout, has `addons/<name> -> ../../<repo>/addons/<name>`; re-pointing those on the run where somebody typed the usual upgrade command would clone fifty repositories the machine already has into a second copy. So `addon_source` reports where each addon actually came from and the summary line says so — `50 addons in addons/ (50 already linked elsewhere)` — rather than restating the default.

Three consequences elsewhere, all of them the same mistake avoided:

- **`--update` runs after resolution, not before.** It is given directories rather than repository names, because there are three places an addon can be and a pull that only knows one layout is a fix that is installed and still not running.
- **`--vendor` deletes `addons/.repos/` once it has copied out of it.** A container's final stage and a release tarball copy this directory whole, and fifty repositories under it would travel — each a second copy of what was just vendored beside it. Nothing is lost that a re-run cannot fetch, and a re-run finds the vendored directories and fetches nothing.
- **The Dockerfile and `tools/package_check.sh` pass `--addons-dir ..` explicitly.** Both stage the siblings deliberately — the build context is the parent directory, and the package check links them into a staging tree — so both would otherwise reach the network for fifty repositories and prove something about GitHub rather than about the working tree.

## The addons a server installs are locked to what the shell was built from

`addons.lock` names a ref per addon repository — a release tag — and `setup.sh` clones at it and moves its own clones there on `--update`, which the egg passes on every reinstall. Before it, every install took each addon's `main` on the day, while the web and desktop shells were exported whenever somebody last exported them; the two drifted, and a server ahead of the shell refuses the join with "This server needs a different build of the game client" the moment dot-server's RPC surface or a shared message type moves.

**Only what this script owns is ever moved.** A fresh clone anywhere, and an existing clone under `addons/.repos/`. A developer's sibling checkout and a shared `--addons-dir` are somebody's working tree and are never detached onto a tag. So on a developer box the lock is a statement, not an action: `tools/addons-lock.sh check` compares the linked addons against it and is the thing to run before `./server export-web` or `export-native`, because a shell exported from a tree that is not at the lock is a shell no locked server matches. `tools/addons-lock.sh write` re-locks every repository to its newest `v*` tag (highest by `sort -V`, not most recent), `write v0.1.3` to one tag, and refuses to write a lock with a hole in it — a missing entry would install that addon at `main`, which is the drift this exists to stop. `TMC_ADDONS_LOCK=off` restores the old behaviour.

**A tag can move under you, and the check has to compare commits.** dot-server's `v0.1.1` was re-pointed at the same commit as `v0.1.2` after it was cut, which made the first test of `--update` look like a no-op. And an annotated tag lists twice in `ls-remote` — the tag object, then `^{}` for the commit — so `check` peels to the commit; its first version compared a HEAD against a tag object and reported every clone as wrong.

## A game that needs newer addons updates the server's addons, by itself

A box's addons move only when the checkout is updated and `setup.sh --update` runs; a restart never did it. So when game-g2gfast v0.1.5 was released needing dot-platform API level 3 (2026-10-04), a restart installed it, the server refused it at boot ("This game needs dot-platform API level 3 or newer; this server has level 2"), and came up running nothing until a reinstall.

**`install-games` checks a pack's `requires.json` before switching to it** (`_check_requirements`, the same `DotAddonApi.check` dot-cloud applies at mount). A version the addons cannot run is not installed over one they can: the installed version is kept, the log says which addon is behind, and the tool exits **4** (`EXIT_ADDONS_BEHIND`) — ahead of 2 and 3, because it is the one failure the launcher can fix.

**On 4 the launcher does a reinstall's two steps and runs itself again, once** (`self_update` / `update_and_restart` in `tools/server.in`): fetch this checkout's branch and reset to it, `setup.sh --no-games --update` to move the addons to the new lock, then `exec ./server` with the original arguments and `TMC_AUTO_UPDATED=1` so a lock that still cannot run the game does not loop. `TMC_AUTO_UPDATE` / `--auto-update` (and the egg's "Update addons automatically"): `when-needed` (default), `always` (every start), `never`. It resets only a deployment — a shallow clone, or a checkout whose HEAD origin already contains — with no local changes to tracked files, and needs `git` in the runtime; otherwise it says to reinstall and starts on what it has. setup.sh `--update` never detaches a developer's own sibling checkouts, only its clones under `addons/.repos/`.

**The two release guards that go with it:** this repository's CI now parses every script against `addons.lock` at the locked refs (dot-ci v1.2.3 resolves a project that has a lock from the lock; it ran with Godot off before), and a game's release refuses a pack no released dot-server-deploy can run (dot-ci v1.2.4, `scripts/server-compat.sh`). So the order is still: tag the addon, lock it here, release this repository, then tag the game — and now each step that is skipped fails in CI instead of on a box.

## A game names three lists of packs beside its own

`game.yml` (inside a game's pack, or under `content/<id>/`) may name: **`dependencies:`** — mounted on the server and sent to every client at game load (shared assets); **`server_dependencies:`** — mounted on the server only, never in a client's `content.sync` (bot data, rulesets); **`maps:`** — the game's delivered maps, carried as pinned keys and fetched when the server changes to one, not at load. Each entry is `<owner>/<name>` (optionally `@<version>`/`@latest`); `install-games` pins every list to concrete versions (`PACK_LISTS`, `_resolve_dependencies(text, bases, field)`, `stamp_dependencies(text, keys, field)`), prefetches `dependencies` and `server_dependencies` but never `maps` (a gigabyte before boot), and `TmcContent` refuses an unpinned entry rather than resolving one per join. The fields live in dot-server (`DotGameDescriptor.server_dependencies` / `.maps`, `DotGameManager.current_server_dependencies()` / `current_maps()`, API level 2); a game turns `maps` into dot-map definitions with `DotMapCatalogue.add_delivered` / `DotMapDef.from_content_key` (dot-map level 2). game-g2gfast is the first user: its 26 courses moved from its own `sv_content_maps` cvar to `maps:`, and it falls back to the cvar on a server whose dot-server predates the field.

## A server owner's settings per game, in `cfg/content.yml` (2026-10-09)

**Every setting a server owner would change about a game lived in that game's `game.yml`, and the installer replaces that file with each new version's.** A cvar, a player count, a map vote's timing, the map list: an owner's edit lasted until the next game update and then sat in `game.yml.prev`, read by nobody. And the `maps:` list made every map a release of the game, because the installer pins a game's lists when it installs or updates the game and otherwise never looks again. `host/tmc_game_config.gd` (`TmcGameConfig`) is the owner's half: `cfg/content.yml` holds `defaults:` and `games: <id>:` sections of `name`, `max_players`, `cvars`, `metadata` and `maps` (`add`, unpinned = newest; `remove`; `game_maps`). The host lays it over each descriptor right after the content scan (`TmcHost._apply_game_config`, both boot paths), so dot-server, dot-vote and the game see one descriptor and nothing downstream changed. Order: game.yml < defaults < the game's section; cvars and metadata merge key by key (metadata recursively), lists replace. **Identity keys are refused, not applied** (`scene`, `client_scene`, `module`, `kind`, `content_id`, `version`, the dependency lists): a different value is a different game under this one's name. Unknown keys are refused by name, because an override silently ignored is the bug this replaces. The host's own metadata keys (`kind`, `module`, `directory`) win, as they do over game.yml. A game's cvars are applied by dot-server before the module registers them and again after (`reapply_descriptor_cvars`); an override rides both passes.

**Unpinned maps are resolved by the installer, every start, into `data/content-maps.json`** (`_resolve_owner_maps`), because `TmcContent`'s rule stands: a version decided per join would hand two players two packs under one map. An origin that does not answer keeps the cached version, and an entry with no cached version is left out with a WARN, never a failed boot. The launcher runs install-games when `cfg/content.yml` names maps even with no games list, and copies the template into a `cfg/` that lacks it, because game-g2gfast's own list moved out into `cfg.example/content.yml` (26 courses) and a box that never re-ran setup would otherwise have dropped to the three built-in maps. selftest's "a server's settings per game" section holds the rules and ties the template to the reader (armed: a replacing metadata merge fails it). **Every game reads the map list now** (2026-10-09): game-g2gfast through `_adopt_descriptor_maps`, the minigames, look-at-me and delivery through dot-game's `DotGameContent.map_dirs`, playground through its dependencies, arena through its own delivered-map path. No game's own `game.yml` names a map pack any more; the stock ones are in `cfg.example/content.yml`, so a server offers them by default and its owner can remove them. **When a pack is fetched is the game's `metadata: maps_delivery:`** (`TmcGameConfig._maps_to_clients`): `lazy` leaves it in `maps` (fetched on a change); `server` also puts it in `server_dependencies`, which dot-server mounts before the game loads; `client` puts it in `dependencies`, mounted before load and sent to every player. `server` exists because a game that fetched its maps inside its own module load ran its first seconds with only its built-in course: dot-server admits players once the scene is up and does not wait for a module. `wipeout_client` found it and now takes its courses from `examples/fixtures/wipeout/content.yml` (27 checks), with `content/wipeout/game.yml` naming none; `deathrun_client` and `prophunt_client` still use `server_dependencies` in their descriptors, which is the back-compat path and worth keeping one suite on.

## A server names the shell build its players load

`web/shell-build` is one line, the build id of the web shell exported from this checkout's `addons.lock`, and `TmcHost._register_web_build` reports it as the NOTIFY cvar `sv_web_build`. The site reads it from the query rules into the server's vars and frames that build for any launch into this server (website-city `~/types/play/web-build.ts`, branch `feat/server-web-build` as of 2026-10-04); a server that reports nothing gets the shared `App.webGameBuild`.

**Why: one shared shell broke one side of every addon release.** A pack built against new addons does not compile on an old shell, and servers are reinstalled on their owners' schedule while the shared build is switched on ours. With the server naming its own build, a release publishes a new shell under a new prefix and nothing that has not moved yet notices. **The site honours a pin only for a build it has a row for** (website-city `WebGameBuild`, Admin → Game), and only while that row is not disabled — an admin can switch off a build with a hole in it, and its servers' players then get the shared build instead of an error. A row also keeps the build out of the site's prune; a build with no row is refused as a pin and may be pruned.

**For a release that needs a new shell** (the engine, the boot stage, the shell's own code, or the first shell carrying addon packs — see "An addon release reaches players without a new shell"), **the order is: lock, export, upload, register the build in the site's Admin → Game (one click — the panel lists a pinned build with no row under "Pins being ignored"), write `web/shell-build`, tag.** An addon-only release needs none of it once that shell is out. The file must name a build that is already uploaded and registered — an unregistered one is ignored and its players get the shared build, which is the wrong shell for this server's addons. It is a tracked file rather than an operator setting because the fact is "which shell matches the addons this checkout installs", and an operator-entered copy is the copy nothing keeps in step. `./server check` fails if the cvar is missing or not NOTIFY (armed).

## An addon release reaches players without a new shell (2026-10-10)

**What this platform wants:** a fix to an addon reaches every player by a server restart, and a new shell is needed only for the engine, the boot stage or security. Every addon tag is already a signed pack on the content origin (`modcommunity/<repo>@<version>`, published by the site's release sync). What was missing was a client that would take one.

**How it works, end to end.** `TmcHost._advertise_addons` reads `addons.lock` and puts one `{dir, repo, id, version}` per installed addon into dot-server's `addon_set`, which rides the signon challenge (with `content_base_urls`, so a desktop client knows where to look). The shell's `_on_server_info` asks dot-cloud's `DotCloudAddonSet.plan_for` what is newer than this build's own `res://addons.lock` (every export carries it now) and than the overlay it is already running. If anything is: it leaves the server quietly, fetches the packs, builds one overlay, writes a plan naming where it was going and who was signed in, and restarts (`_restart`: a page reload, or a relaunch with BOTH halves of the command line — `OS.get_cmdline_args()` stops at the bare `--`, and everything this shell reads is after it). The new main scene `client/boot.tscn` (dot-cloud's `dot_cloud_boot.gd`, which names no addon class) mounts the overlay before anything is compiled and hands over to `client/shell.tscn`; the shell confirms the start, goes back to the server, and joins on the newer addons. dot-cloud's CLAUDE.md has why each piece is shaped the way it is.

**Proven on real builds, against the real site-signed packs.** An exported Linux client whose lock said dot-ui v0.1.4 and dot-audio v0.1.2, against a local `./server` on the current lock: it fetched `modcommunity/dot-ui@0.1.5` and `dot-audio@0.1.3` from dotgames.org, relaunched, mounted the overlay (2 addons, 29 uids), passed the "the overlay copy is what runs" probe, rejoined by itself and spawned in the arena match. The same build in headless Chromium against a local mirror of the two packs: page 1 updated and reloaded, page 2 mounted, confirmed and rejoined — exactly two loads. A local page cannot fetch game content from the CDN (CORS), so the browser run stops at content sync; that is the known local limit, not this.

**What running it found, all fixed:** the launcher in use was the OLD one (`./server` is generated from `tools/server.in` by setup.sh — regenerate it after editing the template, or an export runs without the new checks); a desktop relaunch lost `--connect` and every other user argument; a browser reload lost the plan and the overlay because the engine drops a filesystem sync requested while one runs, which looped the page six times (fixed by repeating the sync before the reload, and a `sessionStorage` counter that stops a loop at two); a signed-in browser player came back as a guest because the page's sign-in code is single-use (the stored session is restored after an update restart, and only for the member the update recorded).

**One engine line is expected.** An exported (release) build logs `ERROR: Attempt to disconnect a nonexistent connection from 'Server' ... 'tree_exited'` once when it leaves a server at the challenge to update. It is the engine's multiplayer cache on an ENet peer closed straight after the first message; deferring the drop does not change it, a debug run does not print it, and the update and rejoin complete either way.

**The release order is now:** tag the addon → the site publishes its pack (hourly, or "Pull now") → bump `addons.lock` here (`tools/addons-lock.sh write`) and push → restart the servers. A box in the default `TMC_AUTO_UPDATE=when-needed` now updates itself on start when the lock on its branch has moved (`lock_moved` in `tools/server.in`: one shallow fetch, and any reason not to answer — dirty tree, a developer's own commits, no network — is "start on what you have"), so the restart is the whole of it; before this, `when-needed` only updated for a game that refused to run. Push the lock only after the packs are on the origin: a client that cannot fetch them joins on its own addons (and does not retry that server this session), which is exactly the situation every release before this one was in.

**What it does not cover.** A client exported before this feature has no boot scene: it takes nothing, so ONE more shell has to be exported and published, and from then on addon releases need none. A change to the shell's own `client/` code, to the boot stage, or to the engine still needs a shell. An addon whose version is not newer than the build's is never taken (no downgrades), and a server whose lock is older than a player's build simply leaves them on the newer one, which is the case the envelope negotiation already handles. Mobile cannot restart itself: the overlay is written and applies at the next launch.

## A server may hold its players on an older web loader

`sv_web_loader` names a version of the site's shared web game loader (the JavaScript the site runs to frame the shell). The site keeps every loader it has published and serves the newest active one by default; a server reporting `sv_web_loader <version>` gets that one while the site has not disabled it, and the default otherwise — so it can hold a server back but never turn a launch into an error. `TmcHost._register_web_loader` always registers it as a NOTIFY cvar, empty unless configured, so `sv_web_loader <version>` over rcon works on a server that never set it.

**It is the operator's, unlike `sv_web_build`.** The build is a fact about the checkout and comes from a tracked file; holding a server on an old loader is a decision, so it comes from the layered config: `sv_web_loader` in `cfg/server.yml`, `--web-loader`, or `TMC_WEB_LOADER` (and the Pterodactyl egg's "Web loader version"). **It is a config FIELD (`TmcConfig.web_loader`) and not a console line**, for the reason `sv_game` is one: the YAML's console lines run during dot-server's boot, before the host registers the cvar, so a passed-through `sv_web_loader: x` was reported as naming nothing and dropped. `+sv_web_loader` on argv is read by the host for the same reason `+map` is. A value that is not one path segment is warned about and reported empty, which the site would ignore anyway. `./server check` asserts the cvar exists, is NOTIFY and equals the configuration (armed: dropping NOTIFY fails it).

**The desktop client has no equivalent yet.** It installs one build per platform, so a server ahead of or behind it is refused at signon with "This server needs a different build of the game client".

## The games came inside too, into `games/`

They stayed in the parent directory for one pass after the addons moved, and the reason given was that they are content published into `dist/` rather than code this project compiles. That is true of `addons/` and is not an argument for the parent: every bullet above applies to a game repository exactly as it applies to an addon — `git clone` of this project into `~/` putting five more repositories in `~/`, several servers on one box sharing one set of checkouts with nothing saying so, and `./setup.sh` in one server's directory republishing packs out of a tree another server's operator is halfway through editing. The last of those is worse here than for the addons, because what comes out of it is a *signed pack* that every client mounts and runs.

So `setup.sh` clones a missing game into `games/<repo>` and publishes from there. `games/` gets a `.gdignore` for the reason `addons/.repos` does: a game walked as part of this project declares its `class_name` globals a second time, and then a **delivered** game's scripts resolve those names to this build's stale copy rather than to their own — the `Value of type "res://dot_cloud/…" cannot be assigned to a variable of type "G2GIdentity"` failure, which is the same bug the leftover vendored directories caused.

**A developer checkout gets a link, not a second clone.** dot-bootstrap puts every game beside this project; cloning a second copy into `games/` is the arrangement where the fix is committed, pulled and still not running. `link_sibling_game` makes `games/<repo> -> ../../<repo>` instead, relative because the whole set moves together, and `game_source` resolves through it with `pwd -P` so the link and the sibling are one answer rather than two. `--vendor` skips the link: that is the release-tarball position, the tree is about to be moved away from the siblings, and a link into them would then be the dangling link `tools/package_check.sh` fails on — correctly. `--vendor` deletes `games/` afterwards too, for the reason it deletes `addons/.repos/`.

**`--games-dir DIR` is `--addons-dir` for the games, and it is a separate flag on purpose.** A box that keeps one library of addons does not necessarily keep one library of games, and `--addons-dir ..` silently meaning "and publish packs from the games up there as well" is the kind of implication that ends with somebody publishing from a tree they did not expect. `TMC_GAMES_DIR` is the same switch for a unit file.

**`--only-games` / `--skip-games` filter the `GAMES` array and nothing else, and that is the whole feature.** Everything below the array walks `GAMES` and only `GAMES` — resolving, cloning, updating, importing, publishing, and the "these are nowhere this run looked" refusal — so one filter at the declaration reaches all of it, and a second list of exceptions further down would be the shape every list bug in this project has taken. A name may be the repository, the repository without its `game-` prefix, or the content directory the second field names, because an operator reading `cfg/server.yml` has the last of those in front of them and should not have to know which of the three the script wanted. Both flags are repeatable and comma- or space-separated; `TMC_ONLY_GAMES` / `TMC_SKIP_GAMES` are the same switches for a unit file. Given both, `--only-games` picks the set and `--skip-games` narrows it — the order that makes `--only-games arena,buses --skip-games buses` mean something instead of contradicting itself.

- **Names are validated against the whole list before anything is dropped, and a bad one is fatal.** A misspelling that silently narrowed the build is a run that looks like the flag was ignored; one that narrowed it to nothing is worse, because the failure then arrives four steps later as `No games were published and none are in dist/` — a message about `dist/`, for a filter the operator typed. Both cases `die` at the array, naming every game this build actually has.
- **It is checked at the array rather than at the argument, which is late on purpose.** The list a name is checked against is that array, and that is where it lives. A typo costs steps 1 to 3 — a runtime that was going to be downloaded anyway and clones that are idempotent — and buys a message listing the real names. `--full` makes the same trade for `sv_game`, for the same reason.
- **A skipped game's existing pack in `dist/` is NOT deleted, and the run says so.** Deleting published content on the strength of a command-line flag is not a setup script's call; the warning names the games and says the server will keep serving what is already there.
- **What was left out is written to `dist/.skipped-games`, and deleted by any run that filtered nothing.** `tools/check.sh` fails a game whose source is present and whose pack is not — exactly right for a build that went wrong and exactly wrong for one that left it out on purpose, and a developer box has all six repositories beside it, so without that file `--only-games arena` is followed by five failures. `play.sh` reads it too, so a game this build never published is not reported as stale with "re-run ./setup.sh", which would re-run it without the flag that was meant. The deletion is the half that matters: a stale marker would go on excusing those games on every unfiltered run after it, turning a pack that genuinely failed to publish into one that looks deliberate.
- **There is no `--skip-addons` because the addons are DERIVED, which is the better answer to the same question.** Each project declares what it needs as `/addons/<name>` lines in its own `.gitignore` — the declaration `dot-bootstrap` already reads — so a filtered build asks the remaining games and wires in their union plus `ADDONS_SHELL`, the seventeen this project's own scripts name. 27 for `--only-games buses`, against 53. The hand-kept `ADDONS_ALL` becomes the fallback: it is what an unfiltered build uses, and what a run with no game sources uses, since a published pack does not say which classes it parses against.
- **The derivation runs only when a game was actually dropped, and for the full set it reproduces `ADDONS_ALL` name for name.** Verified: the union of all six declarations plus the seed is that list exactly. So the default path is untouched by construction, and the derivation cannot be the reason an ordinary build breaks. Each per-game set is also transitively closed — every class named in *code* by an addon in the set is declared by another addon in the set — which was checked by mapping every `class_name` in the family and walking the closure, ignoring doc-comment references (`[DotTimer]`) and string literals (dot-team names `"DotSpectatorManager"` as a string, on purpose, because dot-spectate is duck-typed).
- **`ADDONS_SHELL` is allowed to be small because a mistake in it is LOUD.** Leave one out and this project's own scripts fail to compile on the next import, on every run — not a delivered game failing to parse on a client three layers down. That asymmetry is what makes deriving the rest safe.
- **An addon the build no longer needs is unlinked, and where it pointed is recorded in `addons/.unlinked` first.** Unlinking is what makes the derivation mean anything: left in place, the import registers its globals and a pack that quietly depends on it parses on the box that built it and fails on the fresh box. But `addon_source` finds a sibling checkout *through the existing link and by no other route*, so deleting one destroys the only record of where that addon comes from — the first version of this cloned 26 second copies into `addons/.repos/` on the next unfiltered run, which is precisely the "fix committed, pulled, and still not running" bug this file warns about three times. The record is read back before the clone path, and the relative target is restored verbatim so it resolves to what it always did. Only symlinks are ever removed; a real directory under `addons/` is a vendored addon, and a setup script may not delete content it cannot fetch again.
- **A filtered build narrows what the server OFFERS, not only what it links.** The catalogue is `content/<id>/game.yml`, checked in, all nine — so a vote could land on a game this build never published, and the server would fetch the pack from `sv_content_sources`, mount it, and fail to parse it against the addons now missing (`Could not find type "DotLoadoutManager"`), with `selftest ok` and exit 0, because a script error inside a mount aborts the mount rather than the run. `vote_exclude` is seeded into `cfg/vote.yml` when this run creates it and merely named when the file already exists — the cfg rule is that your edits are the configuration — and it excludes every content directory sharing the dropped `content_id`, so dropping hungario excludes all four `hungry_*` ids and not just the one the `GAMES` entry names.

**The search order lives in `tools/game_source.sh`, sourced rather than repeated.** `--games-dir`, then `games/`, then the parent directory — the last so that every box wired by an older `setup.sh` keeps working. Four scripts ask this question — `setup.sh` publishes, `play.sh` compares a pack against its source, `tools/check.sh` greps for the two things a delivered game may not contain, `tools/package_check.sh` stages them — and each carried its own `../$repo`, which is one edit short of the drift described in the next section. `game_entries` is in the same file, so the list and the place both come from one door.

## Two lists this project keeps, and both went stale in one pass

`setup.sh` carries the list of **addons** every vendored game needs and the list of
**games** to vendor, and this tree's most repeated bug is two copies of one list. Both bit
in the same afternoon when three games gained every addon in the family:

- **The addon list was nine short.** A game that gains a dependency and is not added here
  vendors, imports, and then fails to compile every script that names the missing class —
  dozens of "not declared in the current scope" errors in files nobody touched, which
  reads as a broken project rather than as one missing folder.
- **`content/` was one game short.** `HungryModule` registers three modes and this project
  described two, so the server registered a game it could not list, offer or vote for.
  `examples/live_switch.tscn` caught it as *"7 of 6"* — and said nothing else, which is a
  failure nobody can act on. It names them now.

And the collision check earned its place: **one game added a `game/prop.tscn` and
game-playground already had one.** Every built-in game is flattened into one `game/`
directory, because a `.tscn` names its scripts by absolute `res://` path and there is no
relative form — so two games sharing a filename means one silently overwrites the other,
and the failure is invisible until something loads. The check refused the build instead.

The same flattening has a second edge that is easier to miss: **a game's `content/` is not
vendored.** game-hungario put its NPC bodies and brains there and they mounted perfectly in
a developer checkout; in the deployment they would simply have been absent, and dot-npc
would have refused every spawn with "that NPC's content is not loaded on this server" —
which is a correct answer to a question nobody meant to ask. They are in `game/` now, with
the game's own prefix.

## Four more addons in the vendoring list

`ADDONS` in `setup.sh` gained `dot_objective`, `dot_effects`, `dot_spectate` and
`dot_economy`, because the games that name them are the games this vendors.

**This is the third time that list has gone stale and the second time in this file.**
The failure is always the same and always looks like something else: a game that gains a
dependency and is not added here vendors, imports, and then fails to compile every script
that names the missing class — dozens of "not declared in the current scope" errors in
files nobody touched, which reads as a broken project rather than as one missing folder.

`tools/package_check.sh` reads the list out of `setup.sh` rather than repeating it, which
is what stopped the previous two.

## Two addons were in the dependency list and instantiated nowhere

`ADDONS` in `setup.sh` named `dot_server_security`, `setup.sh` linked it into `addons/`, every game vendored beside it compiled against it — and **nothing in this project ever constructed one.** dot-log was worse: it was not even in the list, while `cfg/log.yml` had documented a level, per-channel levels, a mirror threshold and five file settings since the day it was written. Every one of those keys reached dot-core's own `DotLogSink`, which writes a rotating file and does nothing else.

That is the shape this family keeps finding, one level up from the usual: not a value produced and consumed by nothing, but a whole **addon** installed, configured-for, documented, and never once built. An operator reading `cfg/log.yml` would reasonably conclude this deployment could ship logs somewhere; it could not. An operator reading the addon list would reasonably conclude the server was guarded; it was not.

Both are built now, for every game this tool runs.

### The sink layer

`TmcConfig.build_log_router()` and `TmcHost._build_logging()`. `cfg/log.yml` gained everything below its "sink layer" divider: the in-memory ring behind `log tail`, RFC 5424 syslog, a batched HTTP collector in nine wire formats, redaction, and flood control in front of all of them.

**The shared settings are copied out of `server`, not read twice.** The level, the channels, the mirror threshold and every file setting exist on `DotServerConfig` because a deployment with no dot-log still has all of them through dot-core's sink. So `log.yml` names each of them once, they land there, and `build_log_router()` carries them across. A second set of keys for the same six facts is exactly the "two copies of one list" this project has already been bitten by three times, and it would fail in the worst possible way: a deployment that turned the router on would silently start writing its log somewhere else.

**`log_router: auto` is on**, and the reason it costs nothing is that the router's file target is a strict superset of the plain sink — same directory, same basename, same rotation, same timestamped naming, same `log_json` switch. What it adds is `log status`, `log tail`, `log grep`, `log targets` and `log test` on the console, and somewhere for syslog and a collector to be configured when they are wanted. `off` restores the plain sink exactly.

**It is built before the `DotServer`**, and that ordering is the point: the router registers itself as a `DotLog` sink when it enters the tree, so everything built after it is covered and everything before it is not — and what a server admin most wants out of a log is the reason the boot went wrong.

**`log_router` accepts a bool as well as the three words**, because `on` and `off` *are* bools in `TmcYaml`'s dialect — the same rule that famously turns the country code `NO` into `false`, and the right rule here, because `log_router: on` is what an operator will write. Reading only the three words would have reported the most natural spelling of the setting as an unknown key and quietly left the default in force.

### The guard

`TmcHost._build_security()`. A `DotSecurityManager` beside the server, one `DotSecurityWatch` wiring it to chat, connections, RCON, the console and dot-auth, and a `DotAntiCheat` reporting detections into the same rule engine. `cfg/security.yml` is the whole of the policy.

**It ships in dry run and that is why building it for every server is not an imposition.** Every rule evaluates, every trip is logged and ledgered marked `WOULD`, and nobody is punished. An addon that starts punishing an existing community the moment it is installed — on thresholds nobody chose, against a chat culture it has never seen — is one that gets turned off after the first false positive, and then the server has no guard at all. The intended sequence is in the file: leave it on, read `sec_status` and `sec_log` for a week, then set `sec_dryrun: false`.

**Every anti-cheat movement threshold ships at 0, meaning "do not check".** A speed limit guessed rather than measured bans the best player on the server the first time they chain a surf ramp into a boost. `sec_ac_status` reports the fastest legitimate values it has seen; those are what to set them from.

**The console commands are not registered here.** `DotSecurityManager.attach()` does it itself, and the first version of this called `DotSecurityCommands.register` as well — thirteen "command registered twice" warnings and two more for the cvars, every one of them the console correctly keeping the first registration and saying so.

### Three bugs, and the third was in the addon

- **`server_ref` was `"../Server"` and had to be `".."`.** The guard is a *child* of the server, so `..` already is the server; `../Server` asks the server for a child of its own called `Server` and finds nothing. The guard then reported "A security manager needs a server" once at boot and watched nothing for the life of the process. The two watchers *are* siblings of the guard, so their `"../Security"` is right — which is what makes the pair easy to write wrong by copying.
- **`./server check` asserted nothing about the console.** Both of these addons' entire operator surface is a set of command names, and an absent command is invisible: nothing errors, nothing logs, and the first person to find out is an admin typing `sec_why` during an incident. `_selftest_operator_surface()` now fails the check if `log`, `sec_status` or `sec_why` is missing from a server that actually booted, or if the router was built and never started.
- **In dot-server-security: the guard latched the moderation store at attach, and on this deployment that meant it never found one.** Fixed there; see that project's notes.

## Three addons were built, documented and wired into nothing, again

dot-party, dot-matchmaking and dot-locale arrived with suites and READMEs and not one caller — the same shape as the sink layer and the guard above, one generation later. `host/tmc_party.gd` (`TmcParty.install`, from the end of `TmcHost._boot`) builds them for every game this tool runs, from `cfg/party.yml` and `cfg/matchmaking.yml`:

- **`DotPartyReservations`, always** (unless `party_enabled: false`). With no booking it admits everybody and costs nothing. `seats_fn` counts sessions past authentication against `max_players`; `bypass_fn` is a session holding `DotAdminFlags.RESERVATION`, which dot-server has already resolved by the time it asks the ban seam. Bookings come from the backbone when there is a client and from `party_reserve` at the console either way. `note_arrival`/`note_departure` are `client_spawned`/`client_disconnected`.
- **`DotPartyServer`, only with a backbone client** — `TmcReport`'s, which exists when `data/listing.json` has an integration token. Every route it speaks is an integration route. It is built after the listing for that reason, and one client serves both so one token has one rate limiter.
- **`DotMatchmaker`, only with `mm_enabled: true`.** Ratings go under `data/matchmaking/` unless the operator named a file; `mm_servers` becomes a `DotMmAllocatorList`.

**The config is by prefix, not by table.** Every other file here keeps a table because an operator's name and the property's differ (`net_port` is `port`). Here they do not, so `party_<prop>` lands on `DotPartyConfig`, `party_reserve_<prop>` on `DotPartyReservePolicy` and `mm_<prop>` on `DotMatchmakingConfig` — a table would be a second copy of each addon's property list, the list that goes stale when the addon gains a setting. The policy and a playlist are plain `Resource`s rather than `DotConfig`s, so `TmcConfig._set_on_resource` coerces through the property's own type, and reads an enum by name (`party_reserve_lobbies: public_and_private`). `DOT_PARTY_*` / `--party-*` and `DOT_MM_*` / `--mm-*` layer on top — the addons' own prefixes, because unlike the vote there is only one of each in the process.

**A player claims their party with a chat command, not a handshake field.** The site has no "which party is this person in" route for a server, so the client says. The handshake payload is the natural place and the invasive one: dot-server reads a fixed set of keys out of it, and a new one is a signon change on both ends in every project that links dot-server. A chat command is already a client-to-server channel with permissions, a rate limit and an audit line, and `DotChatManager.handle_message` dispatches a prefixed line to the console *before* it fires `player_chat` — so a game that takes all chat through its own router cannot swallow it. The shell sends `/party_claim <id>` once per party per connection; `DotPartyServer.claim` checks the roster before believing it; one claim per player per ten seconds, because a claim is a request on the server's own credential.

**Party chat is dot-chat's grouped members channel.** `membership_fn(peer, channel)` is never told the sender, so a "party" channel on it reached every party member on the server; dot-chat gained `DotChatChannel.grouped` and `DotChatRouter.group_fn` for this (see its CLAUDE.md). Each game's router — found in `DotRegistry` under `dot_chat_router` or a scoped form of it — gets `DotChatChannel.group(&"party", "Party")` and a `group_fn` of `party_of(session.uid())`, unless the game set either itself. `/party_say <text>` submits into it; a game with no dot-chat router gets the line as a system message to each member.

**The client shell.** A signed-in player (`try_web_handoff` succeeded) gets a `DotPartyClient` over `DotPartyBackendApp` with `client = DotAuthClient`, and its `connect_fn` is the Connect button's own `_connect_to` — following a party to a server is exactly what the player would have done by hand. A party line sits under the identity line in the menu. Every sentence the shell shows for a refusal goes through a `DotLocale` built from `DotLocaleConfig` over `client/locales/<lang>/*.json` (the site's layout; English ships): `explain()` renders the site's refusal key when the catalogue has it and the error's own message when not, so nothing reads worse than it did. `--locale-language de` / `--locale-pseudo true` after a `--` checks a desktop build without a settings screen.

### What running it found

**The first `changelevel` took every booking off the seam, in silence.** `DotPartyReservations` chains onto whatever holds `dot_ban_source` when it enters the tree, which at boot is the first game's dot-moderation. A game change unloads that module and the next one registers its own moderation there — and `DotRegistry` is last-wins, so the booking was simply no longer asked. A private booking then admitted anybody, from the first game change on, and nothing anywhere reported it: the booking still showed in `party_status`, still counted down, and still said "private". `TmcParty` watches `DotRegistry.signals()` and puts the booking back on top, chained to whoever just arrived, deferred so the newcomer has finished registering — and walks the holder's own `previous_source` chain first, because dot-server-security's ban feeds chain too, and re-registering over something that already chains to the booking would make the chain a loop that recurses on every admission. `examples/party_live.tscn` checks the seam before and after a real `changelevel`, and was armed: with the re-chain disabled, both of those checks fail and every other one passes.

**An owner's console booking was refused by the owner's own terms.** `DotPartyReservations.book` runs the policy — `enabled` off by default, `empty_only` on — which is right for a party booking on the site and wrong for an owner typing at their own console. `party_reserve` lends the booking a copy of the terms with the gates open and the ceiling kept.

**`tools/package_check.sh` had been cloning every addon from GitHub.** It reads the repository list out of `setup.sh` by the pattern `^ADDONS=(`, and that array became `ADDONS_ALL=(` when the list became derivable — so it staged no addon at all, and `setup.sh --addons-dir ..` then cloned all fifty-odd into the staging directory, which is precisely the "proves something about GitHub rather than about the working tree" this file warns about above. It surfaced only because three addons were added that are not pushed yet and so could not be cloned. It reads `ADDONS_ALL` now (and `zee_weapons` as `zee-dot-weapons`). The same run found its pack count looking for `dist/<id>/manifest.json` at a fixed depth of two, where packs have been `dist/<owner>/<name>/` for a while: it reported "dist/ did not survive the move" about a tree holding all seven.

**Verified against a real browser.** A server started with `./server --port 6391`, `party_reserve 555 20 private` over `tools/rcon.mjs`, and `tools/browser_check.mjs` against a fresh `./server export-web`: the tab signed on as a guest, dot-server asked the ban seam, the booking refused it (`party.reserve.private`), `party_status` counted one refusal, and the menu read *"Disconnected: This server is booked for a private party until 00:17 UTC."* — through the shell's locale. Without a booking the same tab gets as far as content sync and stops on the CORS refusal every local browser run meets (see the family notes on local browser testing), which is not this.

### What is not verified

- **The site does not serve half of this yet.** `GET party/reservation` (bookings to the server) and every player route under `/api/app/v1/party/*` are specified in dot-party's `docs/backbone-contract.md` and not written. A server with a token makes one failing sync every 30 seconds and says so once at INFO; the shell switches its party client off for the session on the first 404 rather than polling a route the site has said it does not have. The integration routes the tracker speaks (`party/{id}`, `party/state`, `party/session`) exist on the site and have been run here only against a stand-in.
- **No client has claimed a party over a real socket.** `party_live` drives `party_claim` through the console with a hand-built session, and the shell's `/party_claim` goes through `DotClientLink.send_chat`, which every game's chat already uses — but the two have not met, because that needs a signed-in client, and the ticket issuer that would make one is not running.

## And the last two: dot-replay and dot-friends

An audit of every addon against every caller found exactly two that **nothing in the family constructed** — no game, no tool — and both belong here by the argument the sink layer, the guard and the party services were built on: they are operator- or shell-level, a game should not have to know about them, and this is where everything of that kind is built for every game at once.

### The replay ring, in `TmcHost`

`host/tmc_replay.gd` (`TmcReplay.install`, from the end of `TmcHost._boot`, after `TmcParty`), configured from `cfg/replay.yml`. Every server keeps a `DotReplayRing` — 60 s, capped at 32 MiB — fed by a `DotReplayEventTap` on dot-server's event bus, plus a roster keyframe every 10 s. `replay`, `replay save [seconds] [why]` and `replay list` are on the console, RCON and chat (`!replay save`), GENERIC like `log`.

- **What it records is the event bus and a roster, not the netcode.** Connects, spawns, chat (a line a filter blocked included, because what somebody *tried* is the moderation record), commands, kicks, game changes, votes. `DotReplayNetTap` records one peer's view, and which peer is a game's decision; a server tool that picked one for every game would record the wrong player in most of them. A game that wants a watchable demo wires the net tap itself.
- **The clock is the wall clock at `sv_tickrate`, not the physics tick.** dot-server drops to `DotServerConfig.hibernate_tickrate` (5) when nobody is connected (`sv_hibernate_when_empty`, on), so counting physics frames makes "the last sixty seconds" mean sixty seconds at one rate and several minutes at another. Milliseconds since install, scaled, is monotonic — all the recorder asks — and means the same whoever is connected.
- **What it costs, per tick:** one `Time.get_ticks_msec()` and `recorder.advance()`, which is three integer comparisons when nothing is due. When something was recorded, once per `replay_chunk_seconds` (1 s) the pending records are zstd'd into a chunk — a few hundred bytes — and pushed onto the ring; once per `replay_keyframe_seconds` the session list is walked. An event costs its `describe()`d data and one `var_to_bytes`. An idle server holds six small chunks a minute. The only thing that is not O(1) is a save, which writes what the ring holds on the main thread, once, when somebody asks.
- **Evidence goes onto the punishment, and none of the three punishment paths had a place for it before the record was written.** dot-server's `DotBanManager` persists and then emits `ban_added` with the stored Dictionary by reference, so the clip's `evidence()` goes on as `ban["evidence"]` and `save_bans()` runs again — the file store writes the whole document, so the second write carries it. A `kick` is not a record in dot-server at all — it is an audit line and a closed socket — so an admin's `kick`/`kickid` (the ones that audit themselves; a refused admission and the kick half of a ban do not) is answered with a second audit line, `replay_evidence`, naming the same target and hash. dot-moderation's `issue()` takes an `evidence` argument that none of its callers pass — dot-server-security's `_issue` included — so the clip is merged into `punishment.evidence` on `punished` and the store is asked to `put` it again, an upsert by id. The manager is found through `DotRegistry` and re-found on every game change, like `TmcParty` re-finds the ban seam. Every path also writes the audit line, because the final hash only proves anything somewhere the file's holder cannot rewrite, and the audit log is append-only.
- **One clip per incident.** `replay_evidence_cooldown_sec` (10): a ban is followed by its own kick, and a guard that removes a wave of bots does so in one tick. The first version of the check for this compared final hashes — and two clips of the same ring are the same bytes, so it passed with the cooldown removed. It compares the path and counts the files now, and was armed.
- **Bounded on disk three ways, separately.** `data/replays/matches`, `clips` and `evidence` each keep `replay_keep_files` (50) and `replay_keep_mib` (512); the oldest go first, and an evidence clip going is a WARN because a punishment names it. Separate so a moderator saving clips all evening cannot push last week's ban evidence off the disk. `replay_record` (a file per game, finished on `game_loaded` and on shutdown) is **off**: the ring is the evidence, and a demo of every match is disk nobody asked for.
- **`directory` defaults to empty, meaning `data/replays`.** The addon's own default is `user://replays` — a directory under the home of whoever runs the server, outside `data/`, so outside what a container mounts writable and a unit file names in `ReadWritePaths`. A clip written there is evidence nobody can find.

### The friends client, in the shell

`client/tmc_friends.gd` (`TmcFriends`), built by `shell.gd`'s `_build_friends()` at the same moment as the party client and from the same sign-in, over a `DotFriendsBackendApp` whose `client` is the shell's `DotAuthClient` — one token, one refresh, both addons. It is its own node rather than code in `shell.gd` so the suite can drive all of it against a local hub and a stand-in 404 with no window, no sign-in and no server.

- **Presence follows the connection.** On the menu: online, not joinable. Spawned: in game, joinable, `detail` "Playing <game> on <hostname>" (cut to 128, since a hostname is the operator's to choose and the addon refuses rather than truncates). Game change: the detail moves. Disconnect: back to online. Party changes go to `set_party`. The addon debounces all of that into one post.
- **Quitting posts offline, for up to two seconds.** `get_tree().auto_accept_quit = false` while friends exist, and the close request awaits `go_offline()` against a two-second deadline — a site that is down must not be able to hold a window open. A browser tab that is closed never asks; there the presence simply expires after its 120 s.
- **"Join my friend" prefers the party**, through the party client's own `join` (which already follows a party to its server), and falls back to a server **only when this shell has been on that server itself** and so knows its address. A presence carries the site's server id and the shell knows only addresses; the site's address for a server is gated on that server's `showNetInfo`, and a presence that carried one would bypass the gate. Anything else is refused with the site's own `friends.join.deny.unsupported`, rendered from `client/locales/en/friends.json`, which mirrors the site's text. The server id a presence posts is the auth challenge's `server_id` when it is numeric — the site's id on a ticket-strategy server — and 0 otherwise, which leaves the party as the only route.
- **A bare 404 turns it off for the session, once**, with one INFO line — the party client's rule. A 404 the site *explained* (an envelope with a code) is a refusal and does not. The node is kept rather than freed, with its backend nulled: requests already in flight resume into it, and a freed node would be a coroutine resuming on nothing. The one INFO line is `DotFriendsBackendApp`'s own (since 2026-09-25 it logs a site with no routes once at INFO rather than as an outage at WARN), and the switch-off itself is DEBUG for that case, so a site with no routes costs one line, not two.
- **A UI, because the menu had a natural place for one.** Under the party line: "Friends: N of M online", up to four online friends with where they are, and a Join beside each that can be followed. Rendered and looked at (`tools/progress_shot.gd --stage friends`): the first frame had rows of two heights, with and without a button, and every row is the button's height now. It is hidden for a guest and for good once friends switch off.

### The dependency, and why not a `.gitignore` line

Both are in `ADDONS_ALL` **and** `ADDONS_SHELL` in `setup.sh` (and `setup.ps1`'s list), because both are named by this project's own scripts and by no game — the dot_log case exactly. The rest of the family declares a dependency as an `/addons/<name>` line in its `.gitignore`, which dot-bootstrap and dot-ci read; **this project's `.gitignore` is a bare `/addons/`, and both readers treat that as "declares nothing"** on purpose. Adding two named lines under it would make dot-bootstrap link exactly those two into a project that needs fifty-nine, and dot-ci resolve exactly those two — a declaration that reads as complete and is two names long. `dot-bootstrap/projects.tsv` already lists `dot-replay` and `dot-friends`, and `setup.sh`'s `addon_repo()` derives both repository names by the underscore rule with no exception, so nothing else needed an edit.

## `/admin`, and the loading screen (2026-10-05)

Two server-owner features that share one shape: the server decides, a `DotNotice` carries it, and the shell draws it. `host/tmc_admin_menu.gd` + `client/admin_menu_panel.gd`, configured by `cfg/admin_menu.yml`; `host/tmc_loading.gd` + `client/loading_screen.gd`, configured by `cfg/loading.yml`. Both are installed at the end of `TmcHost._boot`, after the first game, and both route through `shell.gd`'s `_on_notice`, which sends `admin_menu` and `loading_screen` topics to their views and everything else to `TmcNoticeOverlay` as before. **No addon changed**: every API used is in the locked tags (dot-server v0.1.6, dot-core v0.1.2, dot-ui v0.1.3), checked against the tags and not only the sibling checkouts, which is the trap that broke a live server on 2026-10-04.

### The menu is a way of typing a command

**Every leaf is one console line run through `DotConsole.execute` with the admin's own context.** That makes the permission check, immunity, the chat gate, the audit line and the reply the console's, exactly as if the admin had typed `/kick #12 Spamming`. A menu that kicked people itself would be a second implementation of every moderation command. A menu that checked permissions only when drawing would be one a modified client could walk past. So the drawing check is a courtesy and the console's is the one that counts.

**"Everything listed if they have the permission" is computed per page, not configured.** An item is drawn when the first word of its line is a command in the console right now, that command `allows_chat`, and the admin holds its flag (plus the item's own `flag`, as a further restriction, never a grant). That is why the default menu can name `slay`, `freeze` and `map` on every server: a game that registers them shows them, and the first `changelevel` to one that does not takes them off with nothing here knowing. The chat gate is honoured on purpose. A game that marks `map` `no_chat()` (dot-map's `allow_chat_change = false`) has no Change map on the menu, because otherwise the menu would become the way round that game's rule.

**A path, not per-admin state.** `i:ban #12 3 2` is "ban, player #12, the third duration, the second reason", and `y:ban #12 3 2` is the same, confirmed. Confirmation sits in the HEAD token because a custom entry (`t:...`) is the last value and swallows every word after it, so a trailing `y` would become part of the reason. Every path is re-validated from scratch: a player who left between two key presses gets a reply and a fresh list, not a ban on whoever is #12 next, and a flag taken away mid-walk is checked on the next press. List choices travel as indices into the SERVER's list. The only free text that can reach a command line is a custom entry, which is stripped of quotes, semicolons and control characters and quoted into one argument. A semicolon would otherwise start a second statement with the admin's permissions. The console's tokenizer has already eaten quotes by the time a path arrives; the stripping is about what survives into the built line.

**Pages are built when asked for, so a list is never stale.** The client keeps the paths it was shown and Back re-ASKS for the previous one rather than redrawing a cached page. A player list from ten seconds ago has somebody on it who left. Root has the path `root` and an info page has its own path for the same reason: an empty path is not pushed, and Back from a category used to close the menu.

**A page always fits a notice.** `DotNotice` drops a `data` tree over 8 KiB WHOLE, which would be a menu that silently never opens on a full server. `_page` caps rows at 60 and then pops rows until the JSON is under 6000 bytes, adding "…and N more". Two hundred players make a 4.4 KB page.

### Choices ride an envelope kind, because chat has a flood limit

**Found by running it, not by reading.** The choices first went back as `/admin_menu <path>` chat lines, which is how a ballot votes. But a ballot is one line, and a menu walk is six (open, category, item, player, reason, confirm) in a few seconds. dot-server's chat limiter allows a burst of five and then one line every three seconds (`chat_rate_per_minute: 20`), so the sixth choice was dropped and the admin was told "You are sending messages too quickly" by a menu. Every stand-in suite passed, because none of them goes through `DotChatManager`; `admin_live` failed on its Back step, where two quick presses never reached the console.

So choices go on their own envelope kind, `tmc.admin_menu`, carrying `{"path": ...}`, with a limiter of its own sized for a person pressing keys (4/s, burst 16). This is the extension `DotEnvelope` exists for: a new feature is a new kind, a peer that does not know it is not sent it, and the signon revision does not move. The server registers the handler in `install` and the shell declares the kind send-only before it connects. The client's `send_kind` asks the SERVER's advert, so a server without the kind makes the shell fall back to the typed `/admin_menu` command, which is still registered and typable. **The arming has to be on the server side for that reason.** Taking the client's registration away changes nothing (it was the first arming tried, and it passed); taking the server's away sends the walk through chat and fails seven checks. A choice arriving on the kind is answered as `Source.CHAT`, because it is the player's in-game input channel and the chat gate above has to hold for it too.

**One window gets the fallback.** The kind is registered at install, after the first game loads. A player whose challenge was sent before that (a join during boot) has an advert without it and uses chat for that connection. That is rare, harmless, and fixed by reconnecting.

### `warn`

dot-moderation has had a `WARN` record since it was written, and nothing in the family issued one. `TmcAdminMenu` registers `warn <player> <reason>` (flag `admin_menu_warn_flag`, default `kick`) **only if the console has no `warn`**, so a game that brings its own keeps it. It tells the player on the HUD (`admin_warning` topic) and in chat, never naming the admin (dot-moderation's rule). It files `issue(4, …)` on the registry's `dot_moderation` by duck type, numbers rather than the enum for the reason `TmcReplay` gives, and writes an audit line. The info page reads `history_for` the same way.

### The loading screen covers a change, never the first join

The shell shows it only once `_has_spawned` is true and the menu is hidden; the first connect is the launcher's or the menu's. Two reasons can hold it up. `game`: the server's hint at `game_changing` (`{"next": {"game"}, "show": true}`), or the link going back through DOWNLOADING/LOADING. It ends at `spawned`, which also clears `content`, because a cloud phase that never said READY must not leave a picture over a running game. `content`: the content client fetching while a game runs, in practice a map. That waits `loading_show_delay_sec` (0.25) so a map already on the disk does not flash a screen. A failed change sends `{"cancel": true}` from `game_load_failed`. A screen with no activity under it for 90 s takes itself down, so a change the server abandoned without saying so cannot strand a player behind a picture.

**URLs, fetched early.** The server sends URLs, never bytes: a notice holds 8 KiB, and a server streaming a song to every player while also sending them a game would be competing with itself for the one link that matters. The document goes out on every `client_spawned`, and the shell queues every URL in it, one request at a time, while the player is still playing, so the picture is there when the change starts. Map entries are NOT in the document (a records server has two hundred maps) and go out as a hint from the loaded game's map session (`fetching` / `changing`, duck-typed through `TmcHost._find_map_session`, handed in as a callable rather than repeated). Game entries ride in the document when it fits under 6500 bytes, and as the `game_changing` hint otherwise. Fields fall through one at a time: map, then game, then default.

**Only http(s), decided on the client.** A server must not make a client read `res://` or `user://`. The rule is written twice, in `TmcLoading.is_safe_url` (so an owner hears about a bad URL at boot) and `TmcLoadingScreen.is_safe_url` (the one that counts), because `host/` is not in the client build. The suite checks the two agree. Media is decoded by magic number, never by extension: PNG, JPEG, WebP, Ogg, MP3, WAV. A picture is scaled down to 2560 px on its longest side, because a 4 MB JPEG can be 8000 px wide, which is a quarter of a gigabyte of video memory for something drawn at window size. Music loops by replaying on `finished` rather than through each format's own loop property, because WAV needs a loop end the file may not carry. It plays on `Master`, like the notice sounds, and M mutes it, remembered in `user://tmc_loading.cfg` with `DotWeb.sync_filesystem()` after the write.

### What running it found

- **The chat flood limit**, above. The only one that was a design error, and the only one no stand-in could see.
- **An added item never reached "Other".** `(other["items"] as PackedStringArray).append(id)` appends to a copy: a `PackedStringArray` is a value, and the cast hands back a copy that nobody keeps. Same family as the `StringName` sort in this file's bug list: correct-looking code against a type whose semantics are not the obvious ones.
- **Durations read `1h`.** `DotBanManager.format_duration` is compact, which suits a log line and not a menu row somebody is deciding from. `TmcAdminMenu.human_duration` says "1 hour", "1 minute 30 seconds".
- **The panel jumped sideways between pages**, and only a frame showed it. A long reason widened the panel to 494 px, and the next page was 376. Rows are clipped with an ellipsis now (the full text is the tooltip), and every page is the same 360 px. `tools/progress_shot.gd --stage admin|admin_info|loading` draws the three views under `xvfb-run` (not `--headless`, which saves empty frames); `screenshots/` is gitignored, so render them rather than looking for them. The same look found "M mute music" offered on a screen with no music to mute.
- **The client tests reached the internet.** A loading-screen test with `cdn.example.com` URLs really fetched them, because adopting a document prefetches. The suite uses `127.0.0.1:9` for anything it does not serve itself.

### Fun commands, and what a game can actually do

The defaults now carry dot-moderation's whole live-tool set in four categories (Players, Fun commands, Powers, Teleport, then Server), with lists sized for a menu: slap's damage ("Just a shove", 5, 10, 25, 50), fire, blind, beacon, on/off for the toggles, health, speed and gravity multipliers.

**"The command exists" is not the test for these, and that is dot-moderation's design, not a bug in it.** `DotModToolCommands` registers every live-tool command whether or not the game has a handler, so `!slap` in a game that cannot slap answers with the game's own reason. That is right for somebody typing. A menu row that can only fail is wrong. So an item may name an `ability`, and `TmcAdminMenu.supports` asks the command's own handler object for its `tools` and asks those `supports(ability)`; `teleport` asks whether the game gave the tools a `teleport_fn`. It is all duck-typed: an item whose command belongs to something with no `tools` is shown, and that command answers for itself. **`admin_live` measured this against the real games, and it corrected me twice.** A game whose tools do noclip has a Powers category. Hungario's tools slay and do not slap or burn (a grep for `ACTION_SLAP` in its tools file matched the *unsupported* list, which is how I first "knew" it did). Arena, g2gfast and the sandbox slap. The suite asserts the menu against what each game's tools report, not against a list of what I believed.

**`@all` and `@others`** are offered first on the player step of an item with `groups: true`, as dot-moderation's live tools spell them, and are refused on any other item, so nobody kicks the whole server through a path. The command's own immunity rule skips and counts the people the admin cannot outrank. **`anyone`** is the player kind with no immunity filter, for a step that names a place rather than a victim (`goto`, `send`'s destination), which is dot-moderation's own rule for those. **`item`** is what the loaded game's `give` can hand out, read from that command's `items_fn`, which every game with `give` already fills in for completion.

### Games extend the menu: four layers, the owner's last

Built-in defaults, then the loaded game's `metadata: admin_menu:` (`adopt_game`, on every `game_loaded`, and for the boot game at install), then layers a game registers in code through `DotRegistry.get_service(&"admin_menu").set_layer(key, tree, owner)` / `add_list(key, name, fn)`, then the owner's `admin_menu.yml`. Items and lists merge by key. A game's `categories:` merge, and the owner's replace only the built-in layout, because a game that ships "Restart the match" should not lose it on every server whose owner reordered the moderation commands. An item may name its own `category:`. Unplaced items go under a category titled with the game's name. `admin_menu_game_items: false` hides them all, and `items: x: enabled: false` hides one. A code layer with an owner goes when the owner leaves the tree, so a module unloaded by a game change takes its items with it. A computed list travels by VALUE (`=red`), not by index, because what a game offers can change between two key presses; the value is checked against what the list offers when it is chosen. Arena's `game.yml` (here and in game-arena) carries the first real one: Restart the match, Start a map vote now.

**`_read_settings` starts from the defaults on every read.** It did not, so `admin_menu_game_items: false` survived a later read of a file without the key. Any re-read (there will be a reload command one day) would have kept settings the owner had deleted.

### What the review of 9d78565 found

An independent review found no injection or permission bypass, and eight defects, all fixed with a check each. **Each new check was armed** by putting its bug back; two of the first versions passed with the bug in place and were rewritten:

1. **Sizes were counted in characters, and the notice limit is bytes.** `DotNotice._bounded_data` measures `var_to_bytes` of the whole data and drops the tree WHOLE past 8 KiB. Sixty players with CJK names made a page the notice silently dropped while it was under the 6000-character cut. Pages, the loading document and every hint are now measured with `var_to_bytes`, with a margin. Hints are cut down to fit (tips first, then extra images, then extra songs, then the entry) and never lose `show`. Boot warns about any entry that would be cut, measured UNCUT; the first version measured the cut hint, which always fits, so it could never warn. The first CJK check used names too short to cross the limit and passed with the bug restored.
2. **The "no flash for a map already on disk" delay did nothing.** The shell calls `begin(content)` on every cloud phase, and the second call showed the screen at once. Every content call now only starts the delay.
3. **A server could exhaust a client's memory with one picture.** The byte limit bounds the download, not the decode: a 1 MB PNG can declare 16384×16384. `declared_size` reads PNG, JPEG and WebP headers, and anything over 8192×4096 (or unreadable) is refused before a decoder runs. The first check used a patched PNG whose checksum then failed, so it passed with the gate removed; it now asserts on `refused_oversized`. Loopback, LAN, link-local and `.local` hosts are not fetched either, so a server cannot make every player's client probe that player's own network (`allow_private_hosts` is the suites' seam). Both halves that were left open here are closed now. **A hostname is looked up first** (off-web, through `IP.resolve_hostname_queue_item`, without blocking a frame), and a name with any private address is refused. That check found its own bug: the engine writes `::1` as `0:0:0:0:0:0:0:1`, which a text match for `::1` waved through, so IPv6 is parsed into eight groups now (`_ipv6_groups`, with IPv4-mapped addresses judged as their IPv4). The fetch that follows resolves the name again. A server that changes its DNS answer between the two (rebinding) is not stopped by this. A browser offers no lookup at all, but blocks public pages reaching private addresses by itself. **Decoding runs on a `WorkerThreadPool` task** where `DotPlatform.has_threads()` (`decode_data` returns an `Image` or an `AudioStream` and touches nothing else), and only the texture is made on the main thread. A browser build without threads still decodes in the frame, because there is no worker to give it to. `_exit_tree` waits for a running task, because its callable is bound to the node.
4. **The prefetch budget counted failures and never reset**, so a few dead URLs or a second server meant no media for the session. A song's type was decided when its turn came, after a map hint could have expired. Now the budget counts only live media, a reset clears the queue and the failures, and the kind is fixed at queue time.
5. **Back history was never truncated.** Back from a root sent after a command walked into the confirmation of the ban just carried out. A page already in the history now truncates to it.
6. **TmcLoading's commands were never unregistered**, and a second install would have run a lambda on a freed node. It has an `_exit_tree` now and refuses a name somebody else holds.
7. **A category's flag was checked only when drawing.** A typed path reached an info item under a category the admin could not see, or one the owner left off the menu. `on_menu` is checked on every path now.
8. **`reset()` kept the last server's game name**, so the next server's map screen said "Loading <their game>…".

### In a browser (2026-10-05)

Verified in headless Chromium against a shell exported from the LOCKED addons (archived at their tags into a scratch tree, because eight sibling checkouts were ahead of the lock), with the real host in a probe scene and the packs served same-origin at `/content`. A guest joined a game and the menu opened over it. **1** pressed in the browser reached the server as `c:players` on the `tmc.admin_menu` kind. A `changelevel hungry_classic` put the loading screen up with the server's picture, title, tip and live download progress, and the WAV it named was fetched (both via a hostname, because the client refuses a literal private address and a browser cannot look one up). Once Hungario spawned, the screen went. **The frames found one more bug:** the menu stayed open across the change, still showing the old game's page. `_on_game_changed` closes it now, and `admin_live` checks it (armed). Not seen: whether the browser PLAYED the sound, which headless cannot say.

### Suites

`examples/admin_loading_selftest.tscn` (149 checks, in CI): the config merge rules, the fun commands against stand-in tools, game layers from `game.yml` and from code, one check per review finding, visibility per flag against a standalone console with stand-in commands, every path from item to the exact argument list a command received (immunity, a player who left, a flag revoked mid-walk, a list index out of range, an injected semicolon), info and warn against a stand-in moderation manager, a 200-player page against the notice limit, the panel by pressing keys, `loading.yml`, the screen's timing and layering, URL refusal, the decoders, and one real HTTP fetch from a socket the suite serves. `examples/admin_live.tscn` (28 checks, `tools/check.sh` only, because it needs the packs in `dist/`) is the real `TmcHost` and the real shell over a socket. A player with no flags gets no menu; with root, `/admin` from chat opens it; it walks to Player info and Back again; it confirms a `changelevel hungry_classic`; the loading screen goes up with the picture the suite serves on :27109 and the new game's own tip, then comes down at spawn; and in both games the fun commands shown are exactly what that game's real tools report. Armed as described above.

### What is not verified

- **Audio in a real browser has not been heard.** The fetch and the decode were seen; whether the autoplay rule lets it play depends on the page having had a gesture, which a player who has been playing has given.
- **Only WAV, PNG and JPEG were decoded in a suite.** Ogg, MP3 and WebP go through the engine's own loaders, called as documented, and have not been fed a real file here.
- **Players need a new shell** (web and native) to see either. An older shell ignores both topics, so nothing breaks, and the server still answers `/admin` with a page nobody draws.

## Things deliberately not here

- **A game that is not ours.** Every game here is delivered now — `changelevel` sends a
  client to fetch one and a real browser has done it — but all five are published from
  repositories beside this one with the key this repository ships. Nothing yet takes a
  pack from a third party: that needs the signing key scoped to a namespace, which
  dot-cloud supports and no deployment uses. See "Who may sign a pack" in the README.
- **A publish step for the browser client.** `./server export-web` writes `web/build/`
  and stops there, and that is the single most expensive gap in this repository to
  rediscover: an export that was never published is indistinguishable from a fix that
  did not work, because the browser runs the previous build and prints the previous
  errors, byte for byte. There are three deployment shapes and they publish
  differently -- the site-published one takes `--zip` and an upload PER BUILD, because
  every build gets its own immutable prefix and there is no directory to write into.
  web/README.md opens with the table and a ten-second check for which shape a
  deployment is on. Check the deployed bytes before believing any conclusion about
  client behaviour.

  **And there are two things to publish now, not one.** The engine build is half of it;
  the packs in `dist/` are the other half, and a build published without them is a
  client that can mount no game at all. Content first, build second — in the other
  order every player on the new build is briefly on a client that can reach nothing.
- **A package.** There is no .deb, no .rpm and no install prefix; `./setup.sh --full`
  is the installer, and what it produces is this directory plus a unit file pointing
  at it. That is deliberate while the engine version is pinned per checkout -- a
  package would have to own /usr, and two servers on one box would then be two
  packages rather than two clones.
- **TLS.** A page on HTTPS cannot open `ws://`. Certificates and a reverse proxy are
  deployment, and they live in `deploy/`: `issue-letsencrypt.sh` gets a real certificate
  by whichever method the box allows -- HTTP-01 out of a webroot, out of nginx, or
  standalone; DNS-01 through a certbot plugin, which is the only one that issues a
  wildcard -- and `install-server-tls.sh` puts it in front of a server. `setup.sh
  --full` asks whether to do both, and binds the game to 127.0.0.1 when the answer is
  yes: left on 0.0.0.0 the game port stays open beside the TLS one, and a client that
  finds it connects in plaintext past everything the proxy is there to do. Nothing in
  the host or the client knows any of it happened.
- **A server browser.** dot-server-query answers both query protocols and `TmcHost`
  attaches one; nothing here asks. `sv_query_app` in `cfg/server.yml` sets the app
  slug a listing shows — display only, and the backbone is what a launch actually
  resolves an app against.
- **Windows beyond `setup.ps1`.** It makes junctions rather than symlinks, and neither it
  nor `server.ps1` has ever been run on Windows from here. There is no PowerShell on the
  machine this was written on, so both are reviewed rather than tested — which is a
  weaker claim than every other script in this repository can make, and is the thing to
  fix first if anything Windows-shaped misbehaves.

  `server.ps1` is new and `server.cmd` now forwards to it. The batch file it replaced was
  nine lines: it understood `check`, `config` and `games` and handed everything else to
  Godot unread, so `--port`, `--bind`, `--name`, `--max-players`, `--game`, the directory
  flags, `--godot`, `--dry-run`, the `--` passthrough, the runtime version check, the
  refusal of a secret on the command line and every meaningful exit code existed on Linux
  and macOS and not on Windows. **The README documented a launcher that only one of the
  two platforms had**, which is the kind of gap nothing can report: every one of those
  options was correct, tested and reachable — from the other script.

**Clear downloaded content (2026-10-04, `[client-clear-cache-1]`).** A mounted pack cannot be unmounted, so a client holding something wrong -- a cached object that fails its check, a failed mount, an old copy -- is fixed by deleting the downloads and starting again. The shell's menu has a "Clear downloaded content…" button under the status line (this shell has no settings screen, and the moment it is needed is right after that line said what failed). It asks first with the size (`downloaded_bytes()`: the session's cache, the default `user://dot_cloud` and the session-only one), then `request_clear()` writes `user://dot_cloud_clear_pending` and restarts -- **it deletes nothing in the running process**, because the mounted packs are still merged into `res://` and on Windows an open `.pck` cannot be deleted. `clear_pending()` runs first thing in `_ready` on the way back up, before anything mounts: dot-cloud's `DotCloudStore.clear_all()` (which now takes `packs/` too) and the other cache dirs whole. Restart by capability (`DotPlatform.can_self_restart`): a browser reloads through `DotWeb.get_global("location").reload()` one second after asking IndexedDB to flush (`force_fs_sync` reports no completion; the marker is one small file, and a lost one costs a second press) -- **called as a method, not `.call("reload")`, which asks JavaScript for a method named `call`**; a desktop build `OS.set_restart_on_exit(true, OS.get_cmdline_args())` and quits. Verified: `shell_notice` (6 checks: 112.6 MiB held, the question, the marker, nothing deleted live, a second shell booting clears it all and the store index agrees); the web export in headless Chromium (click, reload, marker survived the reload, cleared once, a further reload does not clear again); a desktop relaunch under Xvfb (pid changed, seeded pack and marker gone; `--headless` is not passed on to the relaunch, so it needs a display). `tools/progress_shot.gd --stage failed|clear|ingame` draws the button, the question and the in-game prompt. **In a game** the menu is hidden, so a `FAILED` phase from the shell's content client (which is the one every game's map fetch goes through, via `dot_cloud_client`) opens `show_content_failed`: the reason, Dismiss and the same clear button, with the mouse freed while it is up and given back as found (`shell_notice` "a download that fails in a game", armed).

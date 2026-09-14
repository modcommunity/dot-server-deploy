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
`res://` strings, so each is correct in a build and at a mount prefix alike. **All seven
game ids are `kind: pack` and this build ships no game at all.** The five fourth-form
routes below are what had to be closed first, and `tools/check.sh` keeps them closed.

The lobby was the last holdout and the argument for it was real: it is the shell's home
screen and what a player sees before anything is downloaded. It lost anyway, because a
built-in lobby is a lobby that has to be re-exported to change — and a client that
contains one game contains the machinery for all of them, which is the thing this was
trying to stop. `content/lobby/game.yml` sets out the whole of it.

It is the same shape as the constraint dot-cloud already documents for avatar packs — "the
pack is data, the code ships in the build" — reached from further along.

### The constraint has five forms, and all of them are closed

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

The engine is **dot-vote**, and the whole of the policy is `vote.yml`, which is a
`DotVoteRules` and therefore layers `defaults < vote.yml < DOT_VOTE_* < --vote-*` like
everything else here. `host/tmc_vote.gd` is only the wiring: who counts as a player,
who counts as an admin, where the announcements go.

Three decisions in that file are this deployment's rather than dot-vote's:

- **The lobby is not on the ballot.** `vote_exclude: [lobby]`. It is this server's home
  screen rather than a game, and "vote to go back to the menu" is not something anybody
  votes for. It is a TMC key rather than a `DotVoteRules` one for exactly that reason:
  dot-vote should not have an opinion about what a lobby is.
- **A game's time limit lives in its own `game.yml`**, under `metadata: vote:
  time_limit_sec:`. Forty minutes of surf and ten minutes of a lobby-sized deathmatch
  are not the same number and never will be, and the alternative is a second table of
  game ids that goes stale — which this project has already been bitten by twice.
- **`begin_on_apply` is off.** dot-vote's director would otherwise announce a change
  it made *and* this host would announce the same change through `game_loaded` — which
  is two notifications of one play, two entries in the play history, and every cooldown
  quietly half as long as it says. The host's own signal is the one that is right,
  because it also fires for an operator typing `changelevel` by hand, and a manual
  change has to reset the clock and everybody's rock-the-vote just the same.
  `examples/multigame.tscn` fails if that setting is flipped.

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
client `861a4fd82a45`, for the same two types. game-simple-lobby's `headless_net` now asserts the
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
`content_id: hungry`, and the lobby is `a_room`. Everything that looks a pack up builds
`{base}/{content id}/manifest.json` and `dist/` is one of those bases, so `dist/lobby/`
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

### It went stale, and so did the guard

**Both halves of that arrangement had gone stale at once, and each hid the other.**
`setup.sh`'s list still named `dot-a-room` and `dot-2d-hungry`, renamed months ago to
`game-simple-lobby` and `game-hungario`. So it deleted `game/` and `scenes/` (the wipe
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
not load, and `changelevel hungry_classic` swapped the world while leaving the lobby's
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

**The launch arguments need the bare `--`, and that is the part worth remembering.** `client/shell.gd` reads the address from `OS.get_cmdline_user_args()`, which is *only* what follows a `--` on the command line. Godot 4 **silently ignores an argument it does not recognise** rather than refusing to start — measured, not assumed — so `tmc.x86_64 --connect 127.0.0.1:6099` launches perfectly, renders the menu, fills in nothing, and connects to nothing. The published argument template is therefore `--,--connect,{host}:{port}`, and the desktop app's own builder drops the pair cleanly when no server was chosen. A version of this that "works on my machine" and joins nothing is one comma away.

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
tools/check.sh              # parse, shell syntax, 68 checks, then a real boot
tools/package_check.sh      # the same thing in the shape an operator unpacks
```

`examples/selftest.tscn` covers the YAML reader, the config translation, the permission
translation and the content index against fixtures in `examples/fixtures/`. Those fixtures
are asserted on value by value, so changing one changes a check — which is the point: they
are the exact keys an operator writes, checked against the exact settings they are supposed
to reach.

`./server check` is the other half: a real `DotServer`, a real listener, the lobby loaded
and its module in it.

`tools/package_check.sh` runs in the configuration this project is **shipped** in rather
than the one it is developed in. `check.sh` sees seventeen symlinks in `addons/` and
`../game-simple-lobby` and its siblings right beside it; a release tarball and the
container's final stage see neither. It exports the tracked files only, runs `setup.sh --vendor`, moves the result
away from the siblings, and then checks that nothing points back out of the tree, that
`addons/` holds real directories, that the lobby travelled with it, and that it boots.
It also reaches the one branch of `check.sh` a developer checkout never can: with no
sibling to compare against the lobby staleness check reports `--` and must still pass,
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

The **games** did not move, and that is not an oversight: they are content that gets published into `dist/` rather than code this project compiles, and a game repository under `addons/` would be imported as part of this project, which is the arrangement the flip to packs removed.

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

And the collision check earned its place: **game-simple-lobby added a `game/prop.tscn` and
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
- **A vote a player can see.** The vote runs and announces itself in chat, which is how
  every server in this genre did it for fifteen years, and it is enough to play with.
  A ballot drawn on screen needs a wire message and a screen, which are dot-net's and
  dot-ui's, and belong in the client shell rather than in the host.
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

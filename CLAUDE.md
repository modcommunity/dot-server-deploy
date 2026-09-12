# dot-server-deploy

TMC's server tool: a Godot project that boots a dot-server from `cfg/` and `content/`, and
a browser client shell. Read `../../CLAUDE.md` first for the family-wide rules; this file
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

That is why the lobby is `kind: builtin`. It is the shell's home screen, it is what a
player sees before anything is downloaded, and it is written in the family's ordinary
style. `content/lobby/game.yml` says so where somebody will read it.

It is the same shape as the constraint dot-cloud already documents for avatar packs — "the
pack is data, the code ships in the build" — reached from further along.

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
!nominate g2gfast        !rtv        !votefor 2        !timeleft        !nextmap
```

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

## The games are copied, and the copies are checked

`game/`, `scenes/`, `maps/` and `avatars/` are not in this repository. `setup.sh`
copies them out of `../game-simple-lobby`, `../game-hungario`, `../game-g2gfast`,
`../game-playground` and `../game-arena` — the list is `setup.sh`'s `GAMES` and this
sentence is prose about it, not a second copy; `tools/check.sh` and
`tools/package_check.sh` both READ that list rather than repeating it, which is the fix
for the time all three had gone stale together —
copied rather than linked because they are compiled into this build, and gitignored
because the siblings are the record of what they should contain.

**Only `scenes/*.tscn` is copied, not the scripts beside them.** A game's server-scene
script therefore has to live in its `game/` directory; one under `scenes/` never reaches
this build, and the failure is three steps removed from the cause — the scene fails to
load with "referenced non-existent resource", the module refuses to load because no game
registered itself, and the server reports "the game loaded but its module did not".
game-arena's `arena_server.gd` was in `scenes/` for exactly one run.

The failure that arrangement allows is a **stale copy**, and it is invisible from either
side: a game is fixed in its own repository, `setup.sh` is not re-run, and this project boots
the old one. Both suites pass, because each tests the copy it has — the game's on the
fix, this one on the code an operator actually deploys. They are different code and both
are green. It is the same shape as every other bug in this family that hid behind a suite
that was genuinely passing.

`tools/check.sh` compares the two file by file and fails on any difference in either
direction. Where there is no sibling to compare against — a release tarball, the
container's final stage — it says so and does not fail, because the copy it was built
with is the only one there will ever be.

This is **not** the family's deliberate duplication. That rule is about a check two addons
both need being written twice so neither has to depend on the other (`DotAvatarKey`,
`DotLoadoutKey`). This is one game in two places that must be the same game.

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

- **A downloadable game.** The pack path is understood and the constraint that shapes it is
  measured, but every game here still ships in the build, so `changelevel` has never sent a
  client to fetch one.
- **TLS.** A page on HTTPS cannot open `ws://`. Certificates and a reverse proxy are
  deployment.
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

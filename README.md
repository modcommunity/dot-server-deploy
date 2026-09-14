This repository stores useful configurations and layouts for deploying a server under TMC's [Dot](https://moddingcommunity.com/co/4-dot-assets) ecosystem.

The **Dot** collection is a set of open source Godot 4 assets that provide modular building blocks for games and applications in the TMC ecosystem, covering core functionality, networking, authentication, cloud integration, and more. This tool is what puts them together into something you run.

**This tool and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This tool, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Playing it locally, in one command

```bash
./play.sh                  # a server and the browser client, on the loopback
./play.sh playground       # start on a particular game
./play.sh games            # what else is in content/
./play.sh status
./play.sh down
```

It prints a link. Open it.

**This is not `demo.sh`, and the difference is deployment.** `demo.sh` is five servers, nginx terminating TLS, a public host, a separate registrable domain for the game and a `sudo` step to install a listener — right for showing the platform to somebody and wrong for a developer who changed a line and wants to look at it. `play.sh` is the two commands the browser check has always needed, with the three things that are easy to get wrong done for you: it rebuilds the export when the game is newer, copies `embed.html` over Godot's generated `index.html` (the one that takes `?server=` from the query string), and **tells you when the vendored `game/` is older than the repositories it was copied from** — `setup.sh` copies that directory while the addons beside it stay symlinked, so it is the one part that goes stale, and a stale copy exports cleanly, runs, and is last week's game.

**It has nothing to do with `dev.sh`.** That script is the website — website-city and friends on `:3002` — and starts no game at all. The two are independent and run side by side: `play.sh` serves the game from its own origin on `:8099`, and nothing about `embed.html?server=` involves the site. Framing a game *inside* the site is a different thing again and needs its own registrable domain; see `web/README.md`.

**Loopback HTTP only.** An HTTPS page may not open a `ws://` socket, so this shape works here and nowhere else.

## A Server You Start With One Command
TMC's server tool, as a thing you can run.

This repository is where the [dot-*](https://github.com/modcommunity) family comes together into something a server owner starts with one command. It is a Godot project that boots a [dot-server](https://github.com/modcommunity/dot-server), reads its configuration from `cfg/*.yml`, loads games out of `content/`, and serves a browser client. It ships **no game of its own**. The games are copied in from their own repositories by `setup.sh`: [game-simple-lobby](https://github.com/modcommunity/game-simple-lobby), which is the lobby it serves by default, [game-hungario](https://github.com/modcommunity/game-hungario) and [game-g2gfast](https://github.com/modcommunity/game-g2gfast).

```bash
./setup.sh              # get a runtime, wire the addons, write ./server
./server                # start it

./setup.sh --full       # or: the guided install, from a vanilla box to a public server

docker compose up -d    # or the same thing in a container
```

**On a machine with no Godot on it, `./setup.sh` downloads one.** Pinned to a single version, verified against a sha512 that is checked into `tools/fetch-godot.sh` rather than fetched from beside the binary, cached in `~/.cache/tmc/godot/` so one download serves every checkout, and deleted on a mismatch. `--no-download` refuses to fetch and fails instead; `--godot PATH` uses yours and never downloads.

Windows: `setup.bat` (a shim for `setup.ps1`), then `.\server.ps1`. It takes the same commands and the same options as `./server` — `--port`, `--bind`, `--name`, `--max-players`, `--game`, `--map`, `--config`, `--content`, `--data`, `--godot`, `--verbose`, `--dry-run`, a `--` passthrough to the console — and accepts `-Port` as readily as `--port`, so a line copied out of this README works unchanged. `server.cmd` is still there and forwards to it.

## The guided install

`./setup.sh --full` is the whole of a deployment as about ten questions, each with the answer already in the brackets. It is meant for the case it names: a vanilla Linux box, a `git clone`, and one command.

```
  A server on this machine, in about ten questions.
  Return takes the answer in the brackets. Nothing happens until the end.

    Server name [TMC Test Server]
    games here now: arena g2gfast hungry_classic lobby playground
    Game to boot [lobby]
    Player slots [64]
    Tickrate [60]
    Port the server listens on [6064]

    Put nginx in front of it, so browsers can connect over wss://? [Y/n]
    Public hostname clients will connect to [demo.example.com]
    Email for the certificate (expiry warnings) []
    Certificate method (webroot, nginx, standalone, dns, manual) [webroot]
    Public TLS port [443]

    Install a systemd service, so it starts on boot? [Y/n]

  This is the whole of it:

    - set up the project: runtime, addons, games, cfg/, ./server
    - cfg/server.yml: TMC Test Server, game lobby, 64 slots, 60 tick
    - cfg/net.yml: port 6064, bound to 127.0.0.1 (nginx is the way in)
    - install nginx and certbot if they are missing
    - open 80 and 443 in ufw
    - get a certificate for demo.example.com over webroot
    - nginx: wss://demo.example.com:443 -> 127.0.0.1:6064
    - install and start the dot-server.service unit, running as games

  Go ahead? [Y/n]
```

**Nothing is done until every question is answered.** The answers are collected, the plan is printed, and one confirmation covers the lot — an installer that acts on answer three while asking answer four cannot be stopped at answer five, and half an install is worse than none. `--yes` takes every default and asks nothing, so the same install runs from a provisioning script; without it, `--full` refuses to start when stdin is not a terminal, because a prompt with nobody attached is a hang rather than a question.

**Every default is what is already true.** The server name, game, slots, tickrate and port come from `cfg/` when this box has one, so pressing return through the whole thing is a supported way to re-run it, and the second run reports *cfg/ already said all of that*. A key the templates have gained since your `cfg/` was written is appended rather than refused — the installer asking a question and then silently doing nothing with the answer is worse than either doing it or not asking.

**nginx is the optional half, and it is one question because it is one decision.** A page served over HTTPS may not open a plain `ws://` socket, so a browser client needs `wss://`, which needs a certificate, which needs something in front of the server to terminate it. Answer yes and it installs nginx and certbot if they are missing, opens the ports in `ufw` or `firewalld` when one is running, gets a real certificate with [`deploy/issue-letsencrypt.sh`](deploy/issue-letsencrypt.sh), installs the reverse proxy with [`deploy/install-server-tls.sh`](deploy/install-server-tls.sh), and **binds the game to `127.0.0.1`** — left on `0.0.0.0` the game port stays open beside the TLS one and every client that finds it connects in plaintext past everything nginx is there to do. Answer no and none of that happens.

**An nginx that is already here is somebody else's nginx.** The installer joins it rather than assuming it: it counts the server blocks already configured and says so, starts nginx only if it is not running, enables it only if it is not enabled, and reports those apart — "nginx was already here, serving 13 server block(s)" and "already running; not restarting it" are the sentences an operator reads to find out whether this run touched their website. The public TLS port is checked against what actually holds it before anything is written: nginx holding it is fine and normal, since a second server block on one port with a different name is what SNI is for, but anything else holding it is fatal *here* rather than at the next nginx restart, which could be weeks later and somebody else's problem. A name nginx already serves gets a warning, because two server blocks with one `server_name` on one port is a vhost that installs, tests, reloads and is then silently never used.

**The service is the other optional half.** [`deploy/install-systemd.sh`](deploy/install-systemd.sh) writes the unit, enables it, starts it, waits, and then checks it is *still* running — `systemctl enable --now` exits 0 for a service that died a second later, and an installer that reports success there has told you the opposite of what happened. It defaults to running as the user that owns the project directory rather than the one typing, because under `sudo` those are not the same and one of them is root.

Anything it does can be done on its own afterwards: the three scripts above take the same arguments the installer passes them, and `./setup.sh --letsencrypt --domain <host> --email <you>` is the certificate step without the questions.

## What it gives a server owner

- **One command to start.** `./setup.sh` finds a Godot runtime — or downloads the pinned one, verified — wires in the addons, writes a commented `cfg/` from `cfg.example/`, and writes `./server`. It never overwrites a config file that already exists, and it names any setting the templates have gained that your files do not mention, so an upgrade that adds one is visible rather than skipped. `cfg/` is not in this repository: it is what one deployment decided, and a tracked copy is one `git pull` on a running server stops on. RCON reaches loopback only until you widen `rcon_allowed`; `cfg/rcon.yml` says how.
- **Configuration in YAML**, in files split by subject: `server.yml`, `net.yml`, `rcon.yml`, `auth.yml`, `groups.yml` and `permissions.yml`. Anything dot-server exposes as a console variable can go in them under its own name.
- **Roles, not flags.** dot-server's permission model is flags, deliberately; `groups.yml` is the translation, so an operator writes `admin: [kick, ban, mute]` and a player gets the flags.
- **Moderation.** Bans, kicks, mutes, votes and an audit log, all dot-server's, all reachable from the console or over RCON.
- **Games loaded at runtime, and delivered at runtime.** A directory under `content/` with a `game.yml` in it is a game; `changelevel` switches between them with players still connected. **This build ships no game code at all** — every one of them is a signed dot-cloud pack that the server and each client download and mount, so adding a game to your server is publishing a pack and writing a YAML file. No new client build, no upload, nothing in an admin panel, and every player already connected to something else gets it on the way in.
- **The game, and the map it starts on.** `sv_game` and `sv_map` in `cfg/server.yml`, `--game` and `--map` on the command line, `TMC_GAME` and `TMC_MAP` in a unit file, and `-- +map <id>` for the fingers of anybody who has run a dedicated server before. A game decides whether it has maps at all, so a game with none, and an id its catalogue has never heard of, are both a line in the log rather than a refusal to boot.
- **The players choose the next game.** `!game_nominate`, `!game_rtv`, `!game_vote`, `!game_timeleft` and `!game_next`, which is the shape every server in this genre has had since 2005, over the games in `content/` rather than over maps. They are prefixed because a game may run a vote of its own over its own maps, and those own the bare `!rtv` and `!nominate` that players' fingers already know. Each game gets its own time limit, in its own `game.yml`. All of it is `cfg/vote.yml`, and `enabled: false` turns it off.
- **A browser client.** `./server export-web` builds it; one export serves every server, because the address comes from `?server=`. **It publishes nothing** — `web/build/` is the output, and what makes a browser see it depends on which of the three deployment shapes you are on. A site-published build is `--zip` plus an upload, every time. [web/README.md](web/README.md#shipping-a-client-change-which-shape-you-are-on-and-what-it-costs) says how to tell which you are on in ten seconds, and why a stale build looks exactly like a change that did not work. It fetches Godot's export templates first if the machine has none — pinned to the engine's version, sha512 checked against a digest in git, and never as part of `./setup.sh`, because the archive is about a gigabyte and a server that only ever runs games should not pay for one. `tools/fetch-export-templates.sh` on its own does the same thing; `TMC_NO_DOWNLOAD` refuses both it and the runtime. It fetches Godot's export templates first if the machine has none — pinned to the engine's version, sha512 checked against a digest in git, and never as part of `./setup.sh`, because the archive is about a gigabyte and a server that only ever runs games should not pay for one. `tools/fetch-export-templates.sh` on its own does the same thing; `TMC_NO_DOWNLOAD` refuses both it and the runtime.
- **A native client, for the machines a browser tab is not.** `./server export-native` builds the same shell for Linux, Windows and macOS — one file per platform, the pack inside the executable — and prints the command that publishes each one for the desktop app to install. It is the client and not the server: the presets exclude `host/*`, `client/shell.tscn` is what a player who double-clicks gets, and the server address arrives as `-- --connect <host>:<port>`.
- **Content you publish yourself.** `./server pack <id>` turns any directory under `content/` into a signed dot-cloud pack in `dist/` — an avatar set, a prop pack, a texture set, a whole game. `content/<id>/pack.json` says what goes in it and where each file lands, so a pack is assembled from wherever the files actually live rather than from whatever happens to sit in one folder:

```json
{
    "version": "1.0.0",
    "name": "Stock avatars",
    "include": [
        "avatars/kenney",
        { "from": "avatars/head_stock.tscn", "to": "heads/stock.tscn" }
    ],
    "exclude": ["*.import", "*.uid"]
}
```

  `pack.json` also carries `exclude_dirs`, which is what a whole GAME needs: `addons`, `examples`, `tools` and the like are a tree rather than a name pattern, and shipping a second copy of every addon the client already has took arena's pack from 140 files to 768. `--source <dir>` publishes a tree that is not under `content/` — which for a game is every time, since a game lives in its own repository.

  `./server pack --all` does every one, `./server verify <id>` checks the signature. Packs are always signed: `client/content.json` ships `require_signed_manifests: true` because a pack can contain scripts, so an unsigned pack is one no client will mount — publishing without a key is refused rather than quietly producing something that works nowhere. `setup.sh` generates a key on a fresh box so that refusal never becomes the thing that stops an install.

## The layout

```
cfg.example/         the defaults, tracked. Copied into cfg/ by setup.sh, never read by a running server

cfg/                 what an operator edits. Written on first run, and not in this repository
  server.yml           name, slots, tickrate, the game to boot
  net.yml              bind address, port, bandwidth
  rcon.yml             remote console. Generated once, printed once
  auth.yml             the identity backend, or nothing and everybody is a guest
  groups.yml           groups, as sets of permissions
  vote.yml             voting for the next game: rtv, nominations, time limits
  permissions.yml      who is in which group
  content/<id>/        per-game configuration

content/             what the server serves
  global/              loaded by every game
  avatars/             cosmetic parts, published as a pack of their own
  lobby/               the lobby. The default
    game.yml             what it is, where its scene is inside the pack
    pack.json            what its pack leaves out

dist/                the published packs. Written by `./server pack`, not tracked.
  arena/manifest.json    signed; the objects it names are beside it
  arena/objects/

data/                what the server writes
  from_yaml.cfg        what your YAML became. Read this when a setting seems ignored
  admins.json  bans.json  audit.jsonl

deploy/              the root-owned half: TLS certificates, nginx in front, the S3 publish
  issue-letsencrypt.sh   a real certificate, by whichever method the box allows
  install-server-tls.sh  wss:// on a public port -> the server on the loopback
  install-game-origin.sh the game's own origin, which is a security boundary
  install-systemd.sh     the unit file, and the check that it is still running
  issue-local-cert.sh    a development certificate from a local CA

host/                the boot: YAML -> DotServer
client/              the client shell. Knows nothing about any game
web/                 the browser build, and the page that takes ?server= from the URL
```

Three directories, and the split is the point: `cfg/` and `content/` are read, `data/` is written. A container mounts the first two read-only and the third read-write, and a systemd unit points `ReadWritePaths` at exactly one directory.

**`cfg/` is written, never pulled.** `setup.sh` copies each file out of `cfg.example/` if and only if `cfg/` has not got it, generating the RCON password on the way past, and every later run leaves what it finds alone. So upgrading a running server is `git pull && ./setup.sh --no-import`: the pull cannot touch your configuration because your configuration is not tracked, and the setup run tells you which new settings the templates have grown. This is the second design — `cfg/*.yml` was committed once, which meant `git pull` on a box stopped with *your local changes to cfg/server.yml would be overwritten by merge* on the one file that was nobody's but that server's, and meant a generated RCON password reached a public repository the first time anybody ran setup where git was watching.

## Configuration

`cfg/*.yml` is a **surface over dot-server's own vocabulary**, not a second one.

Where a key names something the console already knows, it is compiled into a `.cfg` and handed to the console, which is the parser, the validator, the range clamp and the audit trail. Where it names something fixed before the console exists (the port, the bind address) it goes to the boot config. Everything else, such as groups, per-user permissions and the auth backend, is handed to whatever owns it.

`data/from_yaml.cfg` is written on every boot and is exactly what your YAML became. It is written out rather than kept in memory because "what did my configuration actually become" is the question an operator has when a setting appears not to work.

An unknown key is **reported, never fatal**. Refusing to boot because a config mentions a setting from a newer version is worse than ignoring it.

The YAML reader is a deliberately small subset and refuses everything else with a file and a line number: tabs, duplicate keys, anchors, aliases, tags, block scalars, inline mappings, document markers. See `host/tmc_yaml.gd` for why.

`vote.yml` is the one file that is not a console surface: it is dot-vote's `DotVoteRules`, applied straight onto the resource, so every setting in it is documented on the property of the same name. **Enums are written by name**, so `method: instant_runoff` rather than `method: 2`, because a config file full of enum indices is one nobody can read or diff, and renumbering an enum would silently change how a server counts votes.

## ./server

```
./server                      start it
./server check                boot, load the game, shut down. Exit 0 if it worked
./server config               the resolved configuration
./server games                what is in content/
./server export-web           build the browser client
./server export-native        build the native client, for every platform
./server --help               every option

./server --port 27015 --name "My server"
./server -- +sv_cheats 1 +changelevel lobby
```

Exit codes are meaningful, so a supervisor can tell a misconfiguration from a crash: `2` usage, `3` no runtime, `4` no project, `5` bad config, `6` port in use, `7` bad content.

**Secrets are not options.** `--rcon-password` is refused outright: argv is readable by every other process on the machine and ends up in pasted bug reports, which is why `DotConfig` refuses secrets from argv and the environment too.

## Delivering a game as a pack

A game can be **in the build** or **delivered**. Built in is the default and is what every game in `content/` is today: the code is compiled into this project, the server names an absolute `res://` scene, and the client shell has a matching entry in `BUILTIN_CLIENTS`. Delivered means the game is a signed dot-cloud pack that the server and every client download and mount at `res://dot_cloud/<id>/<version>/` — so a server owner adds a game by editing one YAML file, and a player who has never heard of it gets it on connect.

**One pack per game, and the pack is the game's own repository.** Not a directory of this project: `setup.sh` vendors all five games into one `game/` and one `scenes/`, so no directory here *is* any single game — the files are separable only by their name prefix.

**A pack's scripts may not use `class_name`.** A mounted pack's globals are not registered in the host, so every cross-file type reference inside it fails to compile: the pack mounts, the scene loads, and every script in it is dead. `preload("relative/path.gd")` and `extends "relative/path.gd"` both work, and `<Game>Paths.rebase("res://…")` moves a path string onto wherever the game landed. All five games are already written this way; `tools/check.sh` refuses a new `class_name` so they stay that way.

### The steps

1. **Publish it.** `--source` names the tree; `game.yml` still supplies the id, the version and the entry scene, so nothing is said twice.

   ```bash
   ./server pack arena --source ../game-arena
   ```

   `content/<id>/pack.json` says what not to ship:

   ```json
   {
       "exclude_dirs": ["addons", "examples", "tools", "screenshots"]
   }
   ```

   Excluding `addons/` is not optional. Without it the pack carries a second copy of every dot-\* addon the host build already has — measured at 768 files and 11.2 MiB for arena, against 140 files and 3.1 MiB with them dropped. It is also what keeps the rewrite honest: the publisher moves a `res://` reference onto the mount **only when the file it names is in the pack**, so with `addons/` out, `res://addons/dot_core/…` still means the host's copy and `res://game/arena_client.gd` becomes `res://dot_cloud/arena/0.1.0/game/arena_client.gd`.

   The pack lands in **`dist/<content id>/`**, which is not always `dist/<directory>`: hungario is three game ids over one `content_id: hungry`, because its modes are three presets of one world. Everything that looks a pack up builds `{base}/{content id}/manifest.json`, and `dist/` is one of those bases, so `dist/hungry_classic/` would be a pack nothing — not even the server that wrote it — could find. `./server verify` takes the content id for the same reason.

   Each of those three directories needs its own `pack.json`, identical: `--all` walks directories, so whichever ran without one would republish the pack without its excludes.

2. **Point `content/<id>/game.yml` at it.** Every path becomes relative — they are resolved against the mount prefix, which is not knowable when the file is written:

   ```yaml
   kind: pack
   version: 0.1.0

   scene: scenes/arena_server.tscn
   client_scene: game/arena.tscn
   module: game/arena_module.gd
   ```

   **No address**, and that is deliberate: a pack is found by its content id, against `content/` and `dist/` on this box first and then every `content_urls` entry in order. `manifest_url:` is still accepted and overrides all of that, for content that lives somewhere this server has no base for — but writing one by default put a per-deployment fact into a per-game file, and made every version bump an edit in two places.

   `client_scene` is what a built-in game must **not** have and a delivered game must: `DotClientLink._resolve_scene` refuses every absolute path outside the mount, so it is the only way a client can be told what to show. `module:` is resolved against the mount too, so it is relative for the same reason.

3. **Serve `dist/`, or do not.** `content/` and `dist/` on this box are searched before the network, so a server that published a pack already has it — a LAN deployment needs no web server at all. Clients are told where to fetch from by `content_urls` in `cfg/server.yml`, which the server passes down the connection.

4. **Check it.** `./server check` boots, mounts and loads:

   ```
   cloud.mount  mounted content=arena@0.1.0 files=140 prefix=res://dot_cloud/arena/0.1.0
   tmc.host     content ready at=res://dot_cloud/arena/0.1.0
   games        game loaded scene=res://dot_cloud/arena/0.1.0/scenes/arena_server.tscn
   ```

5. **Take it out of the build**, once it is delivered: drop its entry from `BUILTIN_CLIENTS` in `client/shell.gd` and its row from `GAMES` in `setup.sh`.

### The five, as published

Every one of these was published and booted as a pack — mounted, module loaded from the mount, scene loaded from the mount, `./server check` exit 0 — with warnings identical to the same game booted from the build.

| game.yml | `--source` | pack | `scene:` | `client_scene:` | `module:` |
| --- | --- | --- | --- | --- | --- |
| `arena` | `../game-arena` | `dist/arena` — 140 files, 3.1 MiB | `scenes/arena_server.tscn` | `game/arena.tscn` | `game/arena_module.gd` |
| `g2gfast` | `../game-g2gfast` | `dist/g2gfast` — 171 files, 3.1 MiB | `scenes/g2g_server.tscn` | `game/g2g.tscn` | `game/g2g_module.gd` |
| `playground` | `../game-playground` | `dist/playground` — 76 files, 755 KiB | `scenes/pg_server.tscn` | `game/playground.tscn` | `game/playground_module.gd` |
| `hungry_classic` `hungry_frenzy` `hungry_gauntlet` | `../game-hungario` | `dist/hungry` — 65 files, 644 KiB | `game/modes/<mode>.tscn` | `game/client/hungry_client.tscn` | `game/hungry_module.gd` |
| `lobby` | `../game-simple-lobby` | `dist/a_room` — 36 files, 399 KiB | `scenes/room_server.tscn` | `scenes/room_client.tscn` | `game/room_module.gd` |

`exclude_dirs` is `addons`, `examples`, `tools`, `screenshots` everywhere, plus `imported` for g2gfast — `maps/imported/` is 66 MB of converted geometry that is published as its own packs, and a game pack carrying it would deliver every map to every player on connect — and `web` for hungario, which has a browser build of its own in the repository.

### Signing

`cfg/content.json` and `client/content.json` both ship `require_signed_manifests: true`, and `./server pack` refuses to publish without a key rather than producing a directory that looks finished and mounts nowhere. **A pack contains scripts, so signing it is the whole security boundary** — see "Who may sign a pack" below.

## Who may sign a pack

**A pack contains scripts, and mounting one runs them.** That is the whole reason signing exists here, and it is why `require_signed_manifests` defaults to on and `./server pack` refuses to publish without a key rather than writing a directory that looks finished and mounts nowhere.

### What signing does and does not bound

Signing answers exactly one question — *did the party holding this private key produce these bytes* — and the rest is bounded by the mount, not by the signature:

- The signature is checked over the manifest **as received**, never a re-serialisation, so a manifest cannot be reformatted into something that verifies and means something else.
- Every path in a manifest goes through `DotPaths.safe_relative` before it is used, so no entry can escape the mount prefix.
- The `.pck` is assembled **by the client**, from content-addressed objects it hashed itself. A publisher never hands over a pack file.
- `allow_replace_files` is off, so a pack cannot shadow a file the build already has. A pack runs inside `res://dot_cloud/<id>/<version>/` and nowhere else.
- `trusted_keys` is in `DotCloudConfig.sensitive_keys`, so it is refused from the environment and from argv. Anything that could set a variable in the game's process would otherwise become a publisher.

So the worst a trusted-but-hostile publisher can do is **be the game you joined**. That is already bad — it is code in the player's process — but it is not the host build, and it is not the player's machine outside the sandbox the engine gives it.

### The rule today

One key. `cfg/content.json` and `client/content.json` each carry a single `trusted_keys` entry, the public half of `keys/content.key`, and the private half lives on the publishing machine and is gitignored *before* it is generated so it cannot arrive in a commit by being written first — `setup.sh` generates one on a fresh box, `chmod 600`, because a server with no key publishes nothing at all rather than publishing something that mounts nowhere. **A pack signed by anything else mounts nowhere**, which means a server owner can point a server at any content they like and still cannot deliver code nobody vouched for. That is the right default and it should stay the default.

The cost is equally plain: a server owner who writes their *own* game cannot deliver it to the stock client. They have three ways round it, in increasing order of how much they are taking on —

1. **Have it signed**, and it works in every client everywhere.
2. **Run their own client build.** `client/content.json` is baked into the export, so adding a key there and running `./server export-web` produces a client that trusts them. Their players use their page; nobody else is affected.
3. **`require_signed_manifests: false`.** LAN and development only. It logs a warning every time, and it should: it turns a content system into a remote-code-execution system with extra steps.

### A key says what it is trusted FOR

**A trusted key used to be trusted for every content id there is.** `verify_any` tried each configured key, returned whichever matched, and the caller threw the id away — nothing checked that *this* publisher was entitled to *this* content. With one key that is a distinction without a difference; with two it is the hole that lets the second publisher sign a manifest claiming `content_id: arena` and have any client that has not already mounted it take the pack.

An entry can now name its namespace:

```json
"trusted_keys": {
    "first-party": "-----BEGIN PUBLIC KEY-----\n…",
    "community-alice": {
        "key": "-----BEGIN PUBLIC KEY-----\n…",
        "content_ids": ["alice_*"]
    }
}
```

A bare PEM still means every id, because that is what every config written before this said and silently narrowing them would break deployments that are correct. The patterns are globs, because a publisher's namespace is a prefix in every deployment that has ever had one.

`verify_for` does both halves and the failure says which: a bad signature is `The manifest is not signed by any trusted key`; a good signature from the wrong key is

```
'community-alice' is not trusted to publish 'arena'.
  the signature is valid; the key is scoped to alice_*
```

**Verification first, entitlement second**, and that order is not cosmetic: a scope check on an unverified manifest is a check on a claim the attacker wrote.

`DotCloudConfig.validate()` warns about the one arrangement that is actually a hole — several keys with at least one of them unscoped — and says nothing about a single unscoped key, which is every deployment today. It warns rather than refuses: a client that will not start is worse than one that says so, and the content still has to be signed by a key in the set either way.

### The key your own box publishes with

`setup.sh` generates one on a machine that has none, because `./server pack` refuses to publish unsigned and that refusal would otherwise stop an install on a step nobody was told about. It then adds the **public** half to `cfg/content.json` under the id `local`, beside the one this repository ships — and it does that on every run, not only the first, because an upgrade keeps the `cfg/content.json` it already has.

**Without that merge a fresh install can verify nothing it just published.** The packs are signed by the new key; the trusted set holds only ours. The server finds its own manifest on disk, fails the signature, falls through to the network, and dies on

```
[forbidden] Could not get lobby's content. … <Code>AccessDenied</Code>
```

an S3 error, on a box holding every byte it needs in `dist/`. Nothing in that message points at a key, and the packs verify perfectly against the key that made them.

**A browser client needs it too, and setup cannot do that half for you.** `client/content.json` is tracked and is baked into the export, so an operator publishing their own content adds `keys/content.pub` to it under `trusted_keys` before `./server export-web`. Until they do, their players can mount our packs and not theirs. `setup.sh` says so when it generates a key.

Two unscoped keys — ours and yours — is a coherent configuration and is what a self-hosted server looks like: every publisher in the set is trusted for everything, which is what you mean by adding your own key beside ours on your own box. `DotCloudConfig` says so once at info. It *warns* only about the inconsistent set — some entries scoped and some not — where somebody restricted a publisher and left another key that can still sign the ids they just restricted.

### How to add a publisher

1. They generate a key pair and keep the private half: `godot --headless --path . --script addons/dot_cloud/publish/dot_cloud_cli.gd -- keygen --private theirs.key --public theirs.pub`.
2. Agree a namespace — a prefix on their content ids, `alice_` — and have them publish under it.
3. Add the public half to `client/content.json` **with `content_ids`**, and re-export the client. Add the same entry to `cfg/content.json` on any server that will serve their packs.

Step 3 is the one that cannot be skipped or widened. An entry without `content_ids` is a publisher who can be any game on the platform.

## The website chat box, and running a command from it

`DotChatRelay` joins this server's chat to its room on the website: what players type reaches the page, what members type reaches the game, and a line beginning with `/` or `!` can run as a console command. It needs three things, in this order, and the third one is the only one that is fiddly.

**1. A credential.** `data/listing.json` with a server-scoped integration token from the site. With none there is no backbone client, and the relay refuses to start rather than polling a URL it cannot authenticate to. This is the same file the server listing already uses.

**2. The relay turned on.** `DotChatRelayConfig` is a `DotConfig`, so it layers like everything else here: exported defaults, then `user://chat_relay.json`, then the environment, then argv:

```bash
DOT_CHAT_RELAY_ENABLED=1          # carry chat both ways
DOT_CHAT_RELAY_ALLOW_COMMANDS=1   # let `/something` run as a console command
DOT_CHAT_RELAY_COMMAND_SOURCE=2   # 2 is RCON; 3, the default, is CHAT
```

`demo.sh` exports all three. **The source is the decision.** At CHAT a relayed command reaches only what a connected player could type, and several games here deliberately withhold that from their map change, because a map change destroys every run in progress, and a records server does not let a player do that by typing. At RCON it reaches what an operator at a remote console reaches, which is what "my site admins are administrators of this server" actually means. It is not a promotion either way: the uid is still resolved from the site author and the permission answer is still this server's own files.

**3. One uid in `cfg/permissions.yml`.** And this is the fiddly part, because a site member's uid is `backbone:` plus a database id that appears on no page. So use it once and read the log: type `/map` into the server's chat box on the website, and the refusal names the exact key:

```
inf chat.relay  a relayed command was refused  uid=backbone:clx8f2k0kd command=map
                fix=add 'backbone:clx8f2k0kd' to the server's admin file with the 'rcon' flag
```

Paste that into `cfg/permissions.yml` under `users:` with a group, restart, and the same command works. The file ships with no `users:` key at all — a name written into a public template is a name anybody can register, and every server that never edited the file would hand that person its owner group — so the first entry adds the key as well as the person. There is deliberately **no** way to grant it by the name shown beside the message: a display name is a string the person can change on their own profile page, and a permission keyed on one is a permission anybody can take by renaming themselves.

Once the relay is up, the server also posts its command table to `POST /api/integration/v1/chat/commands`, and the site's chat box offers those commands when a member types `/`. The list is built at the relay's own source, so what the menu shows is what that person could actually run. Offering a command that will always be refused teaches people the site is broken.

## Upgrading a server that is already running

```bash
./upgrade.sh            # pull everything, rebuild, and say what moved
./upgrade.sh --check    # ...and boot the server once before you restart it
./upgrade.sh --dry-run  # what would be pulled, changing nothing
```

**It is a script because the one-line version was wrong in three ways and none of them errored.** That line was `git pull && ./setup.sh --no-import`, beside a loop that pulled `../dot-*`. Once the games became delivered packs: the loop never pulled `../game-*`, so an upgrade republished stale game sources; `--no-import` left the class cache stale, so the pack would not parse while the host did; and a `git pull` that stopped left one repository behind with nothing saying so. Each produced a server that booted, looked healthy, and did not work. `upgrade.sh` refuses to rebuild from a partial pull, names the repositories that would not fast-forward, and re-execs itself after pulling this one — because bash reads a script as it runs, and pulling one mid-run resumes at a byte offset that now means something else.

It does **not** restart the server: this repository cannot know whether that is systemd, `demo.sh`, a container or a terminal, and stopping the wrong thing is worse than stopping nothing.

The pull cannot touch `cfg/`, because `cfg/` is not tracked; the setup run adds any file you have not got and names any setting the templates have grown.

**That pulls this repository and nothing else, and two things live outside it.**

**`--no-import` is overridden when the class cache is stale, and you want it to be.** `.godot/global_script_class_cache.cfg` registers every `class_name` in the project, and a DELIVERED game's scripts are parsed against it at runtime — so an addon linked or pulled after that cache was built is a class the pack cannot see. The host's own scripts are already cached, so the server boots, loads the game and looks healthy; only the pack fails, as `Could not find type "DotTimerRun"` inside a mounted script, surfacing three layers up as `No G2GGame is registered`, a game with no `map` command, and a grey screen. `setup.sh` compares the cache against the newest `.gd` under `addons/` and imports anyway when it loses, saying so.

**The games are separate clones too, and the loop above says `../game-*` for that reason.** It said `../dot-*` when the games were compiled in, and that was right then: the deploy repo's own pull brought the code. It is not right now. `setup.sh` republishes every pack on an upgrade, from those clones, and `--update` is off by default — so a loop that skips them publishes **stale sources**, silently, on the command an operator runs most. A stale game still declares `class_name`, and a pack whose scripts do that mounts and is dead: the scene loads, the script does not attach, and what surfaces is `No G2GGame is registered` against a module that is fine. `./server pack` refuses such a source now, which is the backstop; pulling them is the fix.

**The addons are separate clones, one directory up.** `git pull` here updates the host and the launcher; it does not touch `../dot-server`, `../dot-cloud` or the other fifty, and a host newer than the addon it configures is a real failure mode — a setting this file reads and hands to a `DotServerConfig` that has no property for it. That is reported rather than fatal (`UNKNOWN : server.yml: … this dot-server has no …`), but it means the setting does nothing. Several servers on one box **share** those clones, so one pull fixes all of them — and changes all of them:

```bash
for d in ../dot-* ../game-*; do git -C "$d" pull --ff-only; done && ./setup.sh --no-import
```

`./setup.sh --vendor` copies the addons into this checkout instead of linking them, if one server has to be pinned while the others move.

**Every game is republished by that run, and a pull that changed one is not live until it is.** The games are packs: `setup.sh` imports each game repository and publishes it into `dist/`, so the upgrade command above is also the command that rebuilds the content this server serves. `--no-import` does not skip it — that flag is about re-importing *this* project, and a game repository that gained an asset since the last run has to be imported or its pack ships bytes nothing can open. `tools/check.sh` fails when a pack is older than its source, which is the backstop.

**The content a BROWSER client downloads is published separately, and from one place.** A server prefers `dist/` on its own box over the network, so a box publishing its own packs and a content origin publishing different ones is a server and its players running different builds of the same version — silently, since the version string is the same. Publish both from the same commit.

**The browser client is not upgraded by any of this.** `./server export-web` has to be re-run and the result *published*, and how it is published depends on the deployment shape — a site-published build is `--zip` and an upload every time. [web/README.md](web/README.md#shipping-a-client-change-which-shape-you-are-on-and-what-it-costs) has the table and the ten-second check for which shape you are on. A client change that was exported but not published looks precisely like a change that did not work: the browser runs the previous build and prints the previous errors.

**Once, on a box that ran an older `setup.sh`**, the pull stops on a uid instead:

```
error: Your local changes to the following files would be overwritten by merge:
        content/avatars/part.gd.uid
```

Discard it and pull. `setup.sh` used to delete every `.uid` under the directories it vendors into — right for a file copied from a sibling, whose uid belongs to that project, and wrong for `content/avatars/part.gd`, which is this repository's own tracked file sitting in a directory that also receives vendored content. So `--import` minted a fresh random one and left a tracked file modified after a command whose whole job is to be safe to re-run.

```bash
git checkout -- content/avatars/part.gd.uid && git pull
```

Nothing is lost: every scene that uses that script references it **by path**, so the uid is not named anywhere. The fix is in the commit you are pulling — `setup.sh` asks git which files are its own now and leaves those alone — so this is needed once per box and never again.

**Once, on a box checked out before this changed**, the pull stops on the configuration it is about to stop tracking:

```
error: Your local changes to the following files would be overwritten by merge:
        cfg/server.yml
```

Git is refusing to delete a file you edited, which is right of it. Put the configuration somewhere it is not looking, take the pull, and put it back:

```bash
cp -a cfg ../cfg.mine          # your configuration, including the RCON password
git checkout -- cfg            # let git have its copy back, so the pull can delete it
git pull
cp -a ../cfg.mine/. cfg/       # and it is yours again, now untracked
./setup.sh --no-import
```

**Then change the RCON password.** Any server set up before this shared one password with everybody who ever cloned the repository, because the first run generated it into a tracked file and it was committed. `rcon_allowed` kept it to loopback, so it is a password to rotate rather than an incident, but rotate it: a long random line in `cfg/rcon.yml`, and a restart.

## Docker

```bash
docker compose up -d
docker compose logs -f
```

The build context is the **parent** directory: every dot-* addon is its own repository and there is no way to clone the tree at once, so they are siblings rather than subdirectories.

`cfg/` and `data/` are bind mounts, so the first run writes a configuration you can edit and an RCON password that survives a rebuild. `content/` is mounted read-only. The container runs as your own uid (`UID=$(id -u) GID=$(id -g) docker compose up -d`), not as root, and drops every capability.

RCON is published on **loopback only**. It is a remote console and the password is the only thing between it and whoever finds the port; reach it through an SSH tunnel, or put an address allow-list in `cfg/rcon.yml` and widen the mapping deliberately.

## TLS, and the one question that picks the method

A page served over HTTPS may not open a plain `ws://` socket, so a browser client needs a certificate in front of this server — and the method that gets you one is decided by a single question: what can reach this box, and on which port?

```bash
# :80 is reachable and nginx already serves something there
sudo ./deploy/issue-letsencrypt.sh --domain demo.example.com --email ops@example.com

# :80 is closed, or you want *.example.com — DNS-01 is the only method that does either
sudo ./deploy/issue-letsencrypt.sh --method dns --dns-plugin cloudflare      --dns-credentials /root/.secrets/cloudflare.ini      --domain example.com --wildcard --email ops@example.com

# or as the last step of setting the project up
./setup.sh --letsencrypt --domain demo.example.com --email ops@example.com
```

`--method` is `webroot` (the default: HTTP-01 out of a directory nginx already serves, nothing restarts), `nginx` (certbot drives nginx for the length of the challenge and puts it back), `standalone` (certbot binds :80 itself, and the stop/start hooks are installed so **renewals** work too), `dns` (DNS-01 through a certbot plugin — the only method that issues a wildcard) or `manual` (it prints a TXT record and waits; fine once, and it cannot renew unattended).

**When nothing is listening on :80, it puts something there.** An HTTP-01 challenge is answered over plain HTTP, and plenty of boxes have nothing on that port: nginx freshly installed with its stock site removed, a host that serves only TLS, a vhost that answers every name but this one. The probe is what notices — and rather than reporting it, the script writes an nginx server block for the challenge path, tests the configuration before reloading, takes it straight back out if nginx refuses it, and then **leaves it there**, because the renewal in sixty days needs the same port. `--no-nginx-vhost` never touches nginx; a box whose :80 belongs to something that is not nginx is told so and pointed at `--method standalone` or `--method dns` instead.

**A certificate that is already there and not due is not requested again.** Three questions, and all three have to say yes: is there one, does it cover every name asked for, and has it more than thirty days left. A re-run on a configured box then skips the preflight entirely — it does not have to prove its webroot, its `:80` and its DNS all over again to be told nothing needs doing — and does not need certbot installed to say so. `--force-renewal` replaces it anyway.

**Use `--staging` on a name nobody has proved out yet.** The rate limits count *failed* validations — five per hostname per hour — so a webroot that is not the one nginx serves locks the name out for an hour. That is also why this script probes the challenge path with a token and a `curl` before Let's Encrypt is asked to: a wrong `--webroot` costs a second here instead of an hour there.

**The renewal hook is the part that is otherwise always missing.** A packaged certbot renews on a timer and reloads nothing: the files under `/etc/letsencrypt` change, nginx goes on serving the certificate it opened at startup, and sixty days later a browser reports an expired certificate on a box where `certbot renew` has been succeeding all along. This writes `/etc/letsencrypt/renewal-hooks/deploy/tmc-<name>.sh`, which reloads nginx and — with `--install-to` — re-copies the pair somewhere a non-root process can read, because everything under `/etc/letsencrypt/archive` is `0700 root` and a server reading `privkey.pem` straight out of it gets a permission error no config change fixes.

Then put it in front of a server:

```bash
sudo ./deploy/install-server-tls.sh --domain demo.example.com --port 6065      --backend 127.0.0.1:6071      --cert /etc/letsencrypt/live/demo.example.com/fullchain.pem      --key  /etc/letsencrypt/live/demo.example.com/privkey.pem
```

`./deploy/issue-letsencrypt.sh --help` lists every method and every option, and `--dry-run` prints the `certbot` invocation it would run and changes nothing — no probe file, no hook, no account.

## Validating

```bash
tools/check.sh          # parse, shell syntax, every suite, then a real boot
tools/package_check.sh  # vendor the addons, move the tree away from its siblings, boot it
```

| | |
| --- | --- |
| `examples/selftest.tscn` | the YAML reader, the config translation, the permission translation, the content index |
| `examples/multigame.tscn` | changing games on a running server, and the module swap that goes with it |
| `examples/live_switch.tscn` | **the same, with a real client on a real socket** |
| `examples/reconnect.tscn` | **the real shell, connected twice**, across a server that went down and came back |
| `./server check` | a real `DotServer` booting, loading the lobby, and shutting down |

The third one earns its place. Switching games under a live client segfaulted the server, twice over, once going in and once coming out, and `multigame` passes the same switch with an occupant seated in the world. An occupant is not a socket.

The fourth earns its place for the same reason one layer along: every other suite connects at most once. A shell that reconnected added a second link beside the dropped one, Godot renamed it, and the server's RPCs went on resolving to the dead node while the delivered game was handed the live one — so signon completed, the pack was already mounted and nothing downloaded, the scene instantiated, and the world was empty. No error, on either end. A refresh cleared it, which is what made it look like a browser problem.

The second one matters because a release tarball and the container have no sibling repositories to link to, and a symlink out of `addons/` dangles the moment the directory moves, leaving every `dot-*` class unresolved at once, which reads as a broken project rather than a broken link.

The browser target has its own check, because it is the one thing a headless Godot run cannot see: the WASM loading, the WebSocket handshake a browser performs, and whether anything is actually drawn:

```bash
./play.sh                  # the server and the client, both on the loopback
node tools/browser_check.mjs \
    'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6074' shot.png
```

**`failures` and `otherSocketErrors` are different things and the check keeps them apart.** A server *browser* queries servers that may be down, and a refused query is the correct outcome of asking — game-playground seeds `127.0.0.1:27015` on a first run because that is where a launcher puts a server, and nothing is listening there on a developer's machine. Counting that as a failure made this check report one every time, and a check that always fails is a check whose failures stop being read. Only the socket the page was told to open can fail the run.

## Known limits

- **One transport at a time.** A server listens on WebSocket *or* ENet, so a desktop client on UDP and a browser client on TCP cannot share a match yet. See [PLATFORM.md](../../PLATFORM.md).
- **`cfg/permissions.yml` does nothing without authentication.** `DotAdminManager` refuses permissions to any unauthenticated session, because a guest uid is a random per-device string, so granting anything to one grants it to anyone. Correct, and it looks exactly like the file being ignored.
- **No game has been delivered as a pack yet.** The lobby ships inside the build. See CLAUDE.md for the constraint that decides what a delivered game may look like.
- **No TLS in the server itself.** A page on HTTPS cannot open `ws://`, and the certificate and the reverse proxy in front of it are deployment rather than code — `deploy/issue-letsencrypt.sh` and `deploy/install-server-tls.sh` are how you get both.

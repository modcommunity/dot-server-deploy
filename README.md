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

docker compose up -d    # or the same thing in a container
```

**On a machine with no Godot on it, `./setup.sh` downloads one.** Pinned to a single version, verified against a sha512 that is checked into `tools/fetch-godot.sh` rather than fetched from beside the binary, cached in `~/.cache/tmc/godot/` so one download serves every checkout, and deleted on a mismatch. `--no-download` refuses to fetch and fails instead; `--godot PATH` uses yours and never downloads.

Windows: `setup.bat` (a shim for `setup.ps1`), then `.\server.ps1`. It takes the same commands and the same options as `./server` — `--port`, `--bind`, `--name`, `--max-players`, `--game`, `--map`, `--config`, `--content`, `--data`, `--godot`, `--verbose`, `--dry-run`, a `--` passthrough to the console — and accepts `-Port` as readily as `--port`, so a line copied out of this README works unchanged. `server.cmd` is still there and forwards to it.

## What it gives a server owner

- **One command to start.** `./setup.sh` finds a Godot runtime — or downloads the pinned one, verified — wires in the addons, writes a commented `cfg/` from `cfg.example/`, and writes `./server`. It never overwrites a config file that already exists, and it names any setting the templates have gained that your files do not mention, so an upgrade that adds one is visible rather than skipped. `cfg/` is not in this repository: it is what one deployment decided, and a tracked copy is one `git pull` on a running server stops on. RCON reaches loopback only until you widen `rcon_allowed`; `cfg/rcon.yml` says how.
- **Configuration in YAML**, in files split by subject: `server.yml`, `net.yml`, `rcon.yml`, `auth.yml`, `groups.yml` and `permissions.yml`. Anything dot-server exposes as a console variable can go in them under its own name.
- **Roles, not flags.** dot-server's permission model is flags, deliberately; `groups.yml` is the translation, so an operator writes `admin: [kick, ban, mute]` and a player gets the flags.
- **Moderation.** Bans, kicks, mutes, votes and an audit log, all dot-server's, all reachable from the console or over RCON.
- **Games loaded at runtime.** A directory under `content/` with a `game.yml` in it is a game. `changelevel` switches between them with players still connected.
- **The game, and the map it starts on.** `sv_game` and `sv_map` in `cfg/server.yml`, `--game` and `--map` on the command line, `TMC_GAME` and `TMC_MAP` in a unit file, and `-- +map <id>` for the fingers of anybody who has run a dedicated server before. A game decides whether it has maps at all, so a game with none, and an id its catalogue has never heard of, are both a line in the log rather than a refusal to boot.
- **The players choose the next game.** `!game_nominate`, `!game_rtv`, `!game_vote`, `!game_timeleft` and `!game_next`, which is the shape every server in this genre has had since 2005, over the games in `content/` rather than over maps. They are prefixed because a game may run a vote of its own over its own maps, and those own the bare `!rtv` and `!nominate` that players' fingers already know. Each game gets its own time limit, in its own `game.yml`. All of it is `cfg/vote.yml`, and `enabled: false` turns it off.
- **A browser client.** `./server export-web` builds it; one export serves every server, because the address comes from `?server=`.
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

  `./server pack --all` does every one, `./server verify <id>` checks the signature. Packs are always signed: `client/content.json` ships `require_signed_manifests: true` because a pack can contain scripts, so an unsigned pack is one no client will mount — publishing without a key is refused rather than quietly producing something that works nowhere.

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
  lobby/game.yml       the lobby. The default

data/                what the server writes
  from_yaml.cfg        what your YAML became. Read this when a setting seems ignored
  admins.json  bans.json  audit.jsonl

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
./server --help               every option

./server --port 27015 --name "My server"
./server -- +sv_cheats 1 +changelevel lobby
```

Exit codes are meaningful, so a supervisor can tell a misconfiguration from a crash: `2` usage, `3` no runtime, `4` no project, `5` bad config, `6` port in use, `7` bad content.

**Secrets are not options.** `--rcon-password` is refused outright: argv is readable by every other process on the machine and ends up in pasted bug reports, which is why `DotConfig` refuses secrets from argv and the environment too.

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
git pull && ./setup.sh --no-import
```

The pull cannot touch `cfg/`, because `cfg/` is not tracked; the setup run adds any file you have not got and names any setting the templates have grown. Nothing else is needed.

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
| `./server check` | a real `DotServer` booting, loading the lobby, and shutting down |

The third one earns its place. Switching games under a live client segfaulted the server, twice over, once going in and once coming out, and `multigame` passes the same switch with an occupant seated in the world. An occupant is not a socket.

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
- **No TLS.** A page on HTTPS cannot open `ws://`. Certificates and a reverse proxy are deployment, not code.

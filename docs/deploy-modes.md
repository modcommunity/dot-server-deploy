# Three ways to run a server: on this machine, in Docker Compose, on a Pterodactyl panel

`./setup.sh` installs on the machine you run it on, and that stays the default. If you would rather run the server in a container or on a game panel, tell it which with `--mode`; it then writes the files for that way and installs nothing.

| Mode | You get | You run |
| --- | --- | --- |
| `host` (default) | a server on this machine | `./setup.sh`, then `./server` |
| `compose` | `docker-compose.yml`, `.env`, empty `cfg/` `content/` `data/` | the compose command printed at the end |
| `pterodactyl` | `egg-tmc-server.json`, `install.sh`, `allocations.txt` | import the egg in the panel |

Run `./setup.sh --full` and the first question is this one. To skip the questions: `--mode compose --out DIR` or `--mode pterodactyl --out DIR`, plus any of `--name`, `--game`, `--games`, `--port`, `--max-players`, `--rcon-port`. Add `--dry-run` to see which files would be written without writing any.

## Docker Compose

```bash
./setup.sh --mode compose --out ~/my-server --name "Friday night" --games gamemann/game-g2gfast --game g2gfast --port 6064
cd ~/my-server
docker compose up -d --build
docker compose ps        # "healthy" once the server answers on its game port
```

Your settings are in `.env`: change a line and run `docker compose up -d` again. Everything else is in `cfg/`, which the first start fills in from the shipped templates; `content/` holds the games the server installs and `data/` what it writes (admins, bans, logs). All three are folders next to the compose file, so a backup is a copy of that folder.

The health check asks the server itself whether it is answering, so a server that started but never opened its port shows as unhealthy instead of running.

**Passwords never go in `.env` or the compose file.** The RCON password is generated once on the first start into `cfg/addon/dot_console/rcon.yml`; read it there. Nothing in this tool accepts a password, on purpose: environment variables show up in `docker inspect`.

**With a domain and nginx.** Add `--domain play.example.com`: the browser (WebSocket) port is then published on the loopback only, and the command that sets up nginx is printed. The nginx config is the same one the host install uses (`deploy/install-server-tls.sh`); it forwards to `127.0.0.1:<port>`.

## Pterodactyl

```bash
./setup.sh --mode pterodactyl --out ~/panel --name "Friday night" --max-players 32
```

1. In the panel, Nests, Import Egg, choose `egg-tmc-server.json`.
2. Create a server from it. Give it the allocations listed in `allocations.txt`: the primary one is the game port (the panel publishes it for browsers and for the desktop client), a second one is RCON.
3. Start it. The install runs `install.sh` (the same script that is inside the egg, written out so you can read it).

What you set in the panel's Startup tab lands in the server's files: the name, player slots and which platforms may join are written into `cfg/server/server.yml` every time the server starts, so editing a variable in the panel and editing the file give the same result. Everything the panel has no variable for you change in the file manager, under `cfg/`. [operator-config.md](operator-config.md) says which file holds what.

Leave the Port variable empty; the panel's primary allocation is passed to the server for you. As with the host install, passwords are not variables: set the RCON password in `cfg/addon/dot_console/rcon.yml` in the file manager.

Nginx in front of a panel server is the same config again: point `deploy/install-server-tls.sh --backend` at the node and the primary allocation.

## For developers

`tools/deploy-modes.sh` writes both modes; `setup.sh` only parses the flags and hands over. The pterodactyl mode starts from `deploy/pterodactyl-egg.json` (the one egg, never a second copy) and changes only the defaults you gave. `tools/check_deploy_modes.sh` (run by `tools/check.sh`) does a dry run per mode, validates the compose file (`docker compose config` when Docker is installed, a structural check otherwise), validates both eggs against the documented egg shape, checks every key the egg writes into `cfg/server/server.yml` exists there, and fails if a secret variable appears. The egg's startup-to-file mapping is its `config.files`.

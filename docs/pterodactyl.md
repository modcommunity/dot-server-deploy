# The Pterodactyl egg and non-interactive installs

`deploy/pterodactyl-egg.json`. Every rule here came from a real panel install that hung or died. The underlying lesson: **every non-interactive path here has to be non-interactive on purpose, because the tools it drives are all willing to stop and ask.**

## A hung install has no log

Wings writes `/var/log/pterodactyl/install/<uuid>.log` when the install container EXITS, so a hung install shows a spinner and an empty log directory. The only output that exists is `docker logs -f <uuid>_installer`.

## No `git` may ask anything

GitHub answers an unauthenticated request for a repository it will not admit to with a demand for a username, and git puts that on the terminal. On a developer box there is no terminal and it fails; an install container HAS one, so the same clone hangs for ever. Every git this project runs sets `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`, and `ssh -oBatchMode=yes` (the same hang as a host-key question). `./server install-games` in the egg is capped with `timeout`, because a headless Godot run hangs rather than failing.

The case that found it was a repository looked up under the wrong owner. `repo_url` now encodes the family rule (addons from the organisation, everything else from the games owner) instead of an exception list, and `addon_repo()` is the only place an addon name becomes a repository name ([setup.md](setup.md#one-fact-one-place)).

## A reinstall is root looking at somebody else's checkout

The install container runs as root; wings hands the volume back to the server's user afterwards. So every REINSTALL (never a first install, which has no `.git` yet) died on `fatal: detected dubious ownership in repository at '/mnt/server'`. The egg's install script runs `git config --global --add safe.directory '*'`. **It must never move into `setup.sh`**: on people's own machines this check is a real protection. In the egg it is root's config in a container destroyed minutes later, covering only repositories that script is about to create. `*` rather than `/mnt/server` because setup clones the addons underneath it too.

## A container's `/tmp` is not the machine's

Wings mounts `/tmp` as a tmpfs sized by `docker.tmpfs_size`, 100 MiB by default, and a 70 MB archive unpacks to a 146 MB binary. **`unzip` does not fail when a write fails, it asks** (`write error (disk full?). Continue? (y/n/^C)`), to a terminal nobody reads. `fetch-godot.sh` and `fetch-export-templates.sh` now stage on the destination's filesystem, run `unzip < /dev/null`, and check `df` before downloading.

## Paths must survive a remount

Pterodactyl installs with the volume at `/mnt/server` and RUNS with it at `/home/container`. An absolute runtime path baked into `./server` at install names a directory that exists only during the install, and the yolks image has no Godot on `PATH` (`no Godot runtime found`, exit 3). `$PROJECT/.runtime/*/godot` is in the launcher's search list because a project-relative path is the one form that survives. Reproduce with `env -i PATH=/usr/bin:/bin HOME=/nonexistent`.

## The startup command

- **Use `{{SERVER_PORT}}`, never `{{server.build.default.port}}`.** The dotted form is for configuration-file parsing; on the startup line it is passed through as `${...}` and the entrypoint's shell refuses it (`bad substitution`, exit 1, then wings stops retrying).
- **A server created from an old egg keeps its own copy of the startup command.** Re-importing the egg does not change it; fix it per server (admin → the server → Startup).
- The egg's `done` string is `server   ready`, three spaces: dot-log pads the channel to eight columns and Pterodactyl matches a substring.
- On a panel the derived ports (RCON at game port plus one, both query ports at the game port) are wrong for an allocation-based host, so the egg offers each as a variable (`TMC_RCON_PORT`, `TMC_QUERY_PORT`, `TMC_A2S_PORT`).

## The stop is the console's `quit`, not ^C

The egg's stop command is `quit`, typed into the server's console (wings attaches a terminal, which dot-server's stdin console reads). ^C (SIGINT) and `docker stop` (SIGTERM) end headless Godot 4.7.2 without running any shutdown: no goodbye to the issuer, so with `session_report_url` set in `auth.yml` every player on the box stays held for the issuer's lease (300 s) and is locked out of every other server. `quit` runs `DotServer.shutdown`, which reports the empty roster before the process ends. Measured 2026-10-12: ^C exits 130 with no shutdown logged; `quit` logs the shutdown and the reporter's last roster, then exits 139 on a terminal (dot-server's stdin reader is still blocked in a read the engine cannot cancel when the process ends; queued as dot-server-stdin-exit-1). A stop that hangs is still the panel's Kill.

## What the egg installs

`setup.sh --no-games` (a box that installs its games at runtime must build none: [installing-games.md](installing-games.md#a-server-that-installs-its-games-must-build-none-of-them)), then `--update` on reinstall, which moves the addons to `addons.lock`. "Update addons automatically" is `TMC_AUTO_UPDATE` ([releases.md](releases.md#a-game-that-needs-newer-addons)), and "Web loader version" is `TMC_WEB_LOADER`.

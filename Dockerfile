# A TMC server in a container.
#
#   docker compose up -d          from this directory
#
# BUILD CONTEXT IS THE PARENT DIRECTORY, not this one. Every dot-* addon is its own
# repository and there is no way to clone the tree at once, so this build takes them
# from the checkouts beside the project -- `setup.sh --addons-dir ..` below -- rather
# than cloning fifty repositories inside the image. docker-compose.yml sets
# `context: ..` for that reason; building by hand needs the same:
#
#   docker build -f dot-server-deploy/Dockerfile -t tmc-server ..
#
# If you have vendored the addons into ./addons/ instead -- which is what a release
# tarball looks like -- the sibling copy below finds nothing and setup.sh uses what is
# already there.
#
# A self-contained build -- context `.`, no siblings, setup.sh cloning the addons into
# addons/.repos/ itself -- is what setup.sh does by DEFAULT now, and it would need git
# and a network in the build stage. That is a trade this image has not made: a build
# that reaches the internet for fifty repositories is a build that fails differently
# every week.

# --- Stage 1: the runtime ---------------------------------------------------
#
# The SAME fetcher setup.sh uses, rather than a second copy of the download pinned to
# a second copy of a digest. There were two, and two pins drift: the image and the
# host would then be running different engines with nothing saying so. The version and
# the sha512 live in tools/fetch-godot.sh, in git, and this stage is one line of it.
#
# libfontconfig1 is here because the fetcher RUNS the binary to prove it works, and
# Godot links fontconfig at load time even though --headless draws nothing.

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*

COPY dot-server-deploy/tools/fetch-godot.sh /tmp/fetch-godot.sh

RUN /tmp/fetch-godot.sh --dest /usr/local/bin \
 && rm -f /tmp/fetch-godot.sh \
 && godot --version

# --- Stage 2: the project ---------------------------------------------------
#
# setup.sh runs at BUILD time, so the image ships an imported project. Godot's import
# pass registers every class_name global; without it the identifier does not resolve,
# the scene fails to load, and the process HANGS rather than exiting -- which in a
# container is a healthcheck that never fails and a server that never starts.

FROM runtime AS build

WORKDIR /src
COPY . /src

WORKDIR /src/dot-server-deploy
# --vendor COPIES the addons rather than linking them, and --addons-dir .. is where
# they are: the build context is the parent directory. The final stage copies only
# this project -- so a symlink out of it dangles, every dot-* class_name is unresolved
# at once, and the server dies at startup with what reads as a broken project rather
# than a dangling link. Found by running the container.
#
# No --games-dir, and that is deliberate: the game repositories are in the context too
# and the parent directory is already the last place setup.sh looks for one, so they are
# found before anything is cloned. What --vendor decides for them is that games/ gets no
# link into a sibling this image's final stage will not have, and is deleted if a clone
# put anything there -- what travels is dist/, the signed pack of each game.
# --- Which games this image CARRIES ------------------------------------------
#
# Two shapes of deployment, and they want opposite answers.
#
#   all  (default)  the image builds every game and ships dist/, so the container
#                   is self-contained and needs no content origin at all. This is
#                   what this image has always been and what an air-gapped or
#                   offline deployment wants.
#
#   none            `setup.sh --no-games`: nothing is cloned, nothing is imported,
#                   nothing is packed, and NO SIGNING KEY IS GENERATED. The server
#                   installs what TMC_GAMES names from the content origin at
#                   startup instead. This is what the Pterodactyl egg does, and for
#                   the reason written there: a box that only ever CONSUMES signed
#                   content should not be holding a key that can sign it, and
#                   seven game repositories are a long build for a server that was
#                   told it serves one.
#
#       docker compose build --build-arg TMC_BUILD_GAMES=none
#
# The default stays `all` so an existing `docker compose up` keeps producing the
# image it produced yesterday. Flipping it is a decision about a deployment, not
# something a rebuild should make quietly.
#
# NOT `--only-games`, in either case. The addons a build wires in are derived from
# the games being built, so a filtered build produces a shell that can parse those
# games and nothing else -- and the first game added to TMC_GAMES afterwards
# downloads, mounts, and has every script in it fail to compile. With no game
# sources at all the full addon list is wired in, which is the only answer that
# still works when the set of games is decided at run time.
ARG TMC_BUILD_GAMES=all

RUN ./setup.sh --godot /usr/local/bin/godot --vendor --addons-dir .. \
        $([ "$TMC_BUILD_GAMES" = "none" ] && echo --no-games)

# The configuration generated during the build is thrown away. cfg/ is a volume at
# run time and the RCON password printed into a build log is a password in a build
# log -- the entrypoint generates one on first run instead, into the mounted volume,
# where it survives a rebuild.
RUN rm -rf cfg data

# Proves the image can actually serve before it is tagged. A build that succeeds and
# an image that cannot boot are the same thing from CI's point of view, and this is
# the cheapest place to tell them apart.
# TMC_BUILD_GAMES is passed AGAIN here, and forgetting it is the whole trap: this
# is a second `setup.sh` invocation, so without the flag a `none` build would clone
# and publish all seven games at check time -- undoing the build above, generating
# the signing key that flag exists to avoid, and doing it in the step whose job is
# to prove the image is fine.
RUN mkdir -p cfg data && ./setup.sh --godot /usr/local/bin/godot --no-import --check \
        $([ "$TMC_BUILD_GAMES" = "none" ] && echo --no-games) \
 && rm -rf cfg data

# --- Stage 3: what actually runs --------------------------------------------

FROM debian:bookworm-slim

# libfontconfig1 is not optional even headless. Godot's headless display driver draws
# nothing, and the binary still links fontconfig at load time — so without it the
# process dies with "libfontconfig.so.1: cannot open shared object file" before a
# single line of GDScript runs. Found by running the container; the build stage did
# not catch it because that stage has the runtime image's own dependencies.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=runtime /usr/local/bin/godot /usr/local/bin/godot
COPY --from=build /src/dot-server-deploy /srv/tmc

# A writable home for whatever uid ends up running this.
#
# The container has no passwd entry for the uid the compose file supplies, so `$HOME`
# resolves to `/` — and Godot then tries to create `/.local/share/godot/app_userdata`
# for `user://`, fails, and crashes with a signal 11 several errors later. Fontconfig
# fails the same way looking for a cache directory. Mode 0777 rather than an owner,
# because the uid is not known until the container starts: this is the same shape as
# supporting an arbitrary uid anywhere else.
#
# `user://` is only ever logs here — everything the server means to keep goes to the
# data directory, which is a mount.
ENV HOME=/home/tmc \
    XDG_CACHE_HOME=/home/tmc/.cache \
    XDG_DATA_HOME=/home/tmc/.local/share

RUN mkdir -p /home/tmc/.cache /home/tmc/.local/share \
 && chmod -R 0777 /home/tmc

WORKDIR /srv/tmc

# Not root, and no user baked in either. `cfg/` and `data/` are bind mounts owned by
# whoever runs this on the host, and a uid chosen here will not be theirs — the
# server then cannot write its own generated config, its admin file or its audit log,
# and says so with a permission error that reads as a broken image.
#
# docker-compose.yml sets `user:` from the host's own uid instead. Running without
# one at all would be running as root, which for a process that accepts connections
# from strangers is the wrong default, so the compose file is where it is decided and
# `USER 1000:1000` here is the fallback for a plain `docker run`.
USER 1000:1000

# The game port, and RCON on the next one up. Both are what cfg/net.yml says by
# default; change them there and change the mapping in docker-compose.yml to match.
EXPOSE 6064/tcp 6065/tcp

# A container's PID 1 should be the server, so ctrl-c and `docker stop` reach it
# rather than a wrapper that has to forward them. ./server execs Godot for the same
# reason.
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["run"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD ["/srv/tmc/docker-healthcheck.sh"]

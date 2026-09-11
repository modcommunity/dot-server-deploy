#!/usr/bin/env bash
#
# Bring the whole demonstration up, or take it down, or say what it is doing.
#
#   ./demo.sh up        start everything and print the links
#   ./demo.sh down      stop everything this started
#   ./demo.sh status    what is running
#   ./demo.sh switch <game>   change the running game
#                             (lobby, hungry_classic, hungry_frenzy, g2gfast)
#
# WHAT THIS IS FOR
#
# The platform is twenty-one addons, five games, a server tool and a website, in
# twenty-eight repositories that cannot be cloned as one. A demonstration of it is
# five processes and a reverse proxy, and the only way to show it reliably is for one
# command to stand all of that up the same way every time.
#
# WHAT IT STARTS
#
#   the game server   dot-server, loopback :6070, serving games out of content/
#   game server 2     the same build on :6080, running hungry_classic
#   game server 3     the same build on :6090, running g2gfast at 128 ticks
#   game server 4     the same build on :6100, running playground at 128 ticks
#   game server 5     the same build on :6110, running arena at 64 ticks
#   nginx             already running; terminates TLS on :6064 -> :6070,
#                     :6065 -> :6080, :6066 -> :6090, :6067 -> :6100 and
#                     :6068 -> :6110, and serves the exported client at /game/
#   the website       website-city on :3012 against the tmc_dev database
#
# A NEW SERVER NEEDS ITS TLS LISTENER INSTALLED ONCE, and this script does not do it --
# it touches no root-owned configuration by design, and `down` deliberately leaves nginx
# alone because nginx is shared and serves more than this:
#
#     sudo ./deploy/install-server-tls.sh --domain $HOST --port 6068 \
#          --backend 127.0.0.1:6110
#
# Without it the server is up and reachable on the loopback and a browser gets nothing,
# which the nginx step below reports rather than leaving to be discovered.
#
# The database rows those servers appear as are website-city's
# `scripts/seed-godot-apps.ts --demo-servers`, which knows the PUBLIC ports above.
#
# It does NOT touch the shared dev site on :3002. That is somebody's own `dev.sh`
# session; this is a second instance beside it on its own hostname, reading the same
# database.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

HOST="${TMC_DEMO_HOST:-demo.example.com}"

# WHERE THE GAME IS SERVED FROM, and it is deliberately not $HOST.
#
# A separate registrable domain, because delivered game content executes and the
# same-origin policy is the only thing standing between it and the site's cookies,
# storage, API session and service-worker scope. A path on $HOST would be no
# boundary at all -- an origin is scheme + host + port, and a path is none of
# those. See web/README.md for the whole argument, and web/tmc-loader.js, which
# refuses to start if this ever resolves to the site's own origin.
#
# Not a subdomain either: a sibling of the site can set a `Domain=` cookie the
# site then receives, and SameSite does not distinguish siblings. Which is why
# user content lives on googleusercontent.com rather than on a subdomain.
GAME_ORIGIN="${TMC_DEMO_GAME_ORIGIN:-https://games.example.net}"
SITE_PORT="${TMC_DEMO_SITE_PORT:-3012}"
GAME_PORT="${TMC_DEMO_GAME_PORT:-6070}"
PUBLIC_PORT="${TMC_DEMO_PUBLIC_PORT:-6064}"

# A SECOND SERVER, so the demonstration has more than one thing in the list and the
# server browser is doing something rather than showing a row.
#
# It runs a different game from the first, which is the point: a dot-server is not
# "a Hungry server", it is a server currently running Hungry, and two of them side
# by side is what makes that visible. Set TMC_DEMO_GAME2 empty to run only one.
#
# The port is 6080 and NOT 6071, which is the mistake to avoid: dot-server puts RCON
# on its game port + 1, so a second server one port along collides with the first
# one's RCON and fails to bind with "Already in use" -- naming a port that is free
# as far as `ss` is concerned, because the conflict is with a listener the first
# server opened for itself.
GAME2_PORT="${TMC_DEMO_GAME2_PORT:-6080}"
GAME2_PUBLIC_PORT="${TMC_DEMO_GAME2_PUBLIC_PORT:-6065}"
GAME2="${TMC_DEMO_GAME2-hungry_classic}"
GAME2_NAME="${TMC_DEMO_GAME2_NAME:-TMC Hungry Server}"

# THE WEBSITE CHAT RELAY, and the one thing about it worth an operator's attention.
#
# Every server started here gets these in its environment, which works because
# DotChatRelayConfig is a DotConfig and a DotConfig is layered -- exported defaults, a JSON
# file, the environment, then argv. (It was NOT layered until recently: the games built the
# config with `new()` and read `.enabled` off it, so these variables reached nothing and the
# relay could not be turned on by any documented route, in any of the five games.)
#
#   ENABLED         carry chat between this server and its room on the site, both ways.
#   ALLOW_COMMANDS  let a line beginning with `/` or `!` run as a console command.
#   COMMAND_SOURCE  2 is RCON. 3, the default, is CHAT.
#
# COMMAND_SOURCE is the decision, and it is deliberate rather than convenient. At CHAT a
# relayed command reaches only what a connected player could type -- and several games here
# deliberately withhold `with_chat()` from their map change, because a map change destroys
# every run in progress and a records server does not let a player do that by typing. At
# RCON it reaches what an operator at a remote console reaches, which is what "my site
# admins are administrators of this server" actually means.
#
# It is NOT a promotion. The uid is still resolved from the site author, the permission
# answer is still this server's own `data/admins.json` through the same flags, and a person
# with no entry there can still do nothing at all. What changes is which commands are on
# the table, not who may pull them.
#
# The relay stays off regardless unless `data/listing.json` holds a server-scoped
# integration token: with no credential there is no backbone client, and a relay with no
# backbone client refuses to start rather than polling a URL it cannot authenticate to.
export DOT_CHAT_RELAY_ENABLED="${TMC_DEMO_RELAY:-1}"
export DOT_CHAT_RELAY_ALLOW_COMMANDS="${TMC_DEMO_RELAY_COMMANDS:-1}"
export DOT_CHAT_RELAY_COMMAND_SOURCE="${TMC_DEMO_RELAY_SOURCE:-2}"

# A THIRD SERVER, and the first one in this demonstration that is not a 2D game.
#
# g2gfast is the bunny-hop and surf timer: dot-player-controller, dot-timer, dot-map and
# dot-leaderboard in one process, which is four addons the other two servers never
# load. It is here because a server browser showing two games of the same shape proves
# less than one showing two of different shapes, and because the timer is the part of
# this platform with a number a player can compare against somebody else's.
#
# 6090, again not 6081: dot-server puts RCON on its game port + 1, so servers one port
# apart collide on a listener `ss` cannot see.
GAME3_PORT="${TMC_DEMO_GAME3_PORT:-6090}"
GAME3_PUBLIC_PORT="${TMC_DEMO_GAME3_PUBLIC_PORT:-6066}"
GAME3="${TMC_DEMO_GAME3-g2gfast}"
GAME3_NAME="${TMC_DEMO_GAME3_NAME:-TMC Bhop/Surf Server}"

# [b]The tick rate is the one setting this server cannot take from cfg/.[/b] All three
# share one config directory, and a timer server has to count faster than the 60 the
# others are happy with: a run is a tick count plus two sub-tick fractions, and at 60
# every record on it is quantised four times as coarsely as the 128 the genre runs.
# 128 also divides the netcode's snapshot rate of 32, which 60 does not -- an uneven
# send spacing that arrives as jitter no interpolator can remove.
#
# It goes through `+sv_tickrate`, dot-server's own command-line cvar half, which runs
# before the listener opens and is therefore inside the window a FLAG_STARTUP_ONLY
# cvar is still settable. `./server --tickrate` deliberately does not exist: TmcHost
# keeps its override flags to a port, a bind, a name and a game, and everything else
# belongs in a file somebody can read.
GAME3_TICKRATE="${TMC_DEMO_GAME3_TICKRATE:-128}"

# A FOURTH SERVER, and the first one here that is not a race against a clock.
#
# playground is the physics sandbox: dot-props, dot-player-controller, dot-timer, dot-map
# and dot-leaderboard in one process. It is here because the three servers above are all
# somebody trying to WIN something, and a server browser that only ever shows competitive
# games says nothing about whether this platform can carry the other kind. It is also the
# only one of the four whose entities are server-authoritative rigid bodies, which is a
# different netcode shape from the other three and therefore the one most likely to be
# where the next bug is.
#
# 6100, again not 6091: dot-server puts RCON on its game port + 1, so servers one port
# apart collide on a listener `ss` cannot see.
GAME4_PORT="${TMC_DEMO_GAME4_PORT:-6100}"
GAME4_PUBLIC_PORT="${TMC_DEMO_GAME4_PUBLIC_PORT:-6067}"
GAME4="${TMC_DEMO_GAME4-playground}"
GAME4_NAME="${TMC_DEMO_GAME4_NAME:-TMC Playground Server}"

# 128, like the timer server and for the same reason: pg_lobby has a jump course on its
# bonus track and a run set at 64 is quantised twice as coarsely as one set at 128. It
# also divides the netcode's snapshot rate of 32, which 60 does not.
GAME4_TICKRATE="${TMC_DEMO_GAME4_TICKRATE:-128}"

# A FIFTH SERVER, and the one that took the longest to be able to run at all.
#
# arena is the family's REFERENCE game -- the only place dot-player-controller, dot-combat,
# dot-loadout, dot-match and dot-ui are all present at once -- and until now it was the
# reference game with nothing to sit down at. It had a netcode bridge, a headless suite
# that played a whole deathmatch, and no camera rig, no input sampling and no renderer.
#
# It is here because the four servers above are a lobby, an eating game, a timer and a
# sandbox: not one of them is a game where players SHOOT each other, which is the shape
# most of dot-combat exists for and the only one that exercises lag compensation on a
# real link. It is also the only server here whose hits are rewound.
#
# 6110, again not 6101: dot-server puts RCON on its game port + 1, so servers one port
# apart collide on a listener `ss` cannot see.
GAME5_PORT="${TMC_DEMO_GAME5_PORT:-6110}"
GAME5_PUBLIC_PORT="${TMC_DEMO_GAME5_PUBLIC_PORT:-6068}"
GAME5="${TMC_DEMO_GAME5-arena}"
GAME5_NAME="${TMC_DEMO_GAME5_NAME:-TMC Arena Server}"

# 64, and deliberately NOT the 128 the two timer servers run.
#
# A deathmatch is judged by whether a shot hit, not by a time to the millisecond, and
# lag compensation does the work a higher tick rate would -- the server rewinds every
# hitbox to where the shooter saw it. 64 still divides the netcode's snapshot rate of
# 32, which is the constraint that actually matters: an uneven send spacing arrives as
# jitter no interpolator can remove. It is also the one number here that is checked
# end to end, because the client adopts it from HELLO rather than from its own export.
GAME5_TICKRATE="${TMC_DEMO_GAME5_TICKRATE:-64}"
# Where the site is reachable from a browser, which is what a sign-in code is redeemed
# against. nginx terminates 443 for $HOST and proxies to $SITE_PORT; the port is an
# implementation detail a page never sees.
SITE_URL="${TMC_DEMO_SITE_URL:-https://$HOST}"
SITE_DIR="${TMC_DEMO_SITE_DIR:-$ROOT/../../../website-city}"
PUBLISH_DIR="${TMC_DEMO_PUBLISH_DIR:-/srv/tmc-game}"
# The database, and the CDN that goes with it. THESE TWO ARE A PAIR.
#
# The site builds a web-game-loader URL as "<NEXT_PUBLIC_CDN_URL>/<FileUpload.key>", so
# the loader has to live under whatever CDN base the instance is running with. tmc_dev's
# loader is in the S3 bucket (scripts/seed-godot-apps.ts --upload put it there); a
# sandbox database seeded against a locally-served loader needs that base instead.
# Mixing them gives a Play button that fetches a 404 and a player that never starts.
DB="${TMC_DEMO_DB:-postgresql://tmc:10041@127.0.0.1:5432/tmc_dev?connection_limit=20}"
# [b]$CDN, and NOT "$GAME_ORIGIN/game", which is what this passed for months.[/b] The
# paragraph above states the rule and the line below it broke it: `$CDN` was defined
# here, documented as the pair to `$DB`, and then read by NOTHING -- the family's own
# "a setting whose name occurs once is a setting nothing reads", in the file that
# explains the setting.
#
# The symptom needed two things to be true at once, which is why it survived. The site
# builds the loader URL as "<NEXT_PUBLIC_CDN_URL>/<FileUpload.key>", tmc_dev's key is
# `public/app/godot/webGameLoader.js`, and that object is in the S3 bucket -- so against
# the game origin it 404s. A 404 is served as text/html, a browser applies Opaque
# Response Blocking to an HTML response requested as a script, and the console says
# `net::ERR_BLOCKED_BY_ORB` rather than "not found". The player shows "The game could
# not be loaded."
#
# And nobody had ever seen it, because `play.launch` was returning 500 from a schema
# drift further up: the Join button never got far enough to fetch a loader at all. One
# bug hiding behind another.
CDN="${TMC_DEMO_CDN:-https://cdn.example.net}"

# The check the whole arrangement rests on, made where a person will see it. The
# loader refuses a same-origin base too, but that failure surfaces in a player's
# browser console; this one surfaces in the terminal of whoever changed it.
if [ "${GAME_ORIGIN#*://}" = "$HOST" ] || [ "${GAME_ORIGIN#*://}" = "$HOST/" ]; then
    printf 'demo.sh: GAME_ORIGIN (%s) is the site origin (%s).\n' "$GAME_ORIGIN" "$HOST" >&2
    printf '  Serving the game from the site origin turns the iframe sandbox into a\n' >&2
    printf '  no-op. Set TMC_DEMO_GAME_ORIGIN to a domain of its own.\n' >&2
    exit 2
fi

RUN="$ROOT/data/demo"
mkdir -p "$RUN"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; DIM=$'\033[2m'; OFF=$'\033[0m'

say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YLW" "$OFF" "$1"; }
bad()  { printf '  %sxx%s   %s\n' "$RED" "$OFF" "$1"; }
step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }

# The pid, when this user is allowed to see it. `ss -p` only names a process you own,
# so nginx (root) shows a bound port with no pid at all.
port_pid() { ss -ltnp 2>/dev/null | grep -E ":$1\b" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; }

# [b]Bound, not owned.[/b] Keying this on port_pid made nginx invisible -- the demo
# reported "nothing on 6064" while nginx was serving on it, which is the one line
# somebody would act on by breaking a working proxy.
listening() { ss -ltn 2>/dev/null | grep -qE ":$1\b"; }

# Waits for a port, or gives up. A deadline rather than a fixed sleep: a cold Next.js
# route compiles on first hit and a Godot import can be slow, and "sleep 10 is surely
# enough" is the check that passes on an idle box and fails while somebody is watching.
wait_for_port() {
    local port="$1" seconds="${2:-90}" name="${3:-port $1}"
    local deadline=$(( $(date +%s) + seconds ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        listening "$port" && return 0
        sleep 1
    done
    return 1
}

# --- up --------------------------------------------------------------------

do_up() {
    step "the game server"

    if listening "$GAME_PORT"; then
        ok "already listening on $GAME_PORT"
    else
        [ -x ./server ] || { bad "./server is missing — run ./setup.sh"; exit 4; }
        nohup ./server > "$RUN/server.log" 2>&1 &
        echo $! > "$RUN/server.pid"

        if wait_for_port "$GAME_PORT" 90; then
            ok "listening on $GAME_PORT  (log: data/demo/server.log)"
        else
            bad "it did not come up — see data/demo/server.log"
            tail -20 "$RUN/server.log"
            exit 1
        fi
    fi

    if [ -n "$GAME2" ]; then
        step "the second game server ($GAME2)"

        if listening "$GAME2_PORT"; then
            ok "already listening on $GAME2_PORT"
        else
            mkdir -p data/game2
            nohup ./server --port "$GAME2_PORT" --game "$GAME2" \
                --name "$GAME2_NAME" --data data/game2 \
                > "$RUN/server2.log" 2>&1 &
            echo $! > "$RUN/server2.pid"

            if wait_for_port "$GAME2_PORT" 90; then
                ok "listening on $GAME2_PORT  (log: data/demo/server2.log)"
            else
                # Not fatal. One server is still a demonstration, and the usual
                # cause is a port collision that should not take the whole thing
                # down with it.
                warn "it did not come up — see data/demo/server2.log"
                tail -10 "$RUN/server2.log" >&2
            fi
        fi
    fi

    if [ -n "$GAME3" ]; then
        step "the third game server ($GAME3)"

        if listening "$GAME3_PORT"; then
            ok "already listening on $GAME3_PORT"
        else
            mkdir -p data/game3
            nohup ./server --port "$GAME3_PORT" --game "$GAME3" \
                --name "$GAME3_NAME" --data data/game3 \
                -- "+sv_tickrate" "$GAME3_TICKRATE" \
                > "$RUN/server3.log" 2>&1 &
            echo $! > "$RUN/server3.pid"

            if wait_for_port "$GAME3_PORT" 90; then
                ok "listening on $GAME3_PORT at $GAME3_TICKRATE ticks  (log: data/demo/server3.log)"
            else
                warn "it did not come up — see data/demo/server3.log"
                tail -10 "$RUN/server3.log" >&2
            fi
        fi
    fi

    if [ -n "$GAME4" ]; then
        step "the fourth game server ($GAME4)"

        if listening "$GAME4_PORT"; then
            ok "already listening on $GAME4_PORT"
        else
            mkdir -p data/game4
            nohup ./server --port "$GAME4_PORT" --game "$GAME4" \
                --name "$GAME4_NAME" --data data/game4 \
                -- "+sv_tickrate" "$GAME4_TICKRATE" \
                > "$RUN/server4.log" 2>&1 &
            echo $! > "$RUN/server4.pid"

            if wait_for_port "$GAME4_PORT" 90; then
                ok "listening on $GAME4_PORT at $GAME4_TICKRATE ticks  (log: data/demo/server4.log)"
            else
                warn "it did not come up — see data/demo/server4.log"
                tail -10 "$RUN/server4.log" >&2
            fi
        fi
    fi

    if [ -n "$GAME5" ]; then
        step "the fifth game server ($GAME5)"

        if listening "$GAME5_PORT"; then
            ok "already listening on $GAME5_PORT"
        else
            mkdir -p data/game5
            nohup ./server --port "$GAME5_PORT" --game "$GAME5" \
                --name "$GAME5_NAME" --data data/game5 \
                -- "+sv_tickrate" "$GAME5_TICKRATE" \
                > "$RUN/server5.log" 2>&1 &
            echo $! > "$RUN/server5.pid"

            if wait_for_port "$GAME5_PORT" 90; then
                ok "listening on $GAME5_PORT at $GAME5_TICKRATE ticks  (log: data/demo/server5.log)"
            else
                warn "it did not come up — see data/demo/server5.log"
                tail -10 "$RUN/server5.log" >&2
            fi
        fi
    fi

    step "the exported client"

    # WHICH BACKBONE THE WEB PLAYER SIGNS IN AGAINST.
    #
    # A browser has no environment and no argv, so `DOT_AUTH_BACKBONE_URL` -- which is
    # how every other deployment sets this -- cannot reach it. The shell reads
    # `res://client/auth.json` instead, shipped inside the export, and this writes it
    # before the export is built.
    #
    # $SITE_URL and NOT $GAME_ORIGIN. The game origin is a separate registrable domain
    # on purpose (see the note at the top) and is where the engine is SERVED FROM; the
    # backbone is where a single-use sign-in code is REDEEMED, and that is the site.
    # Pointing it at the game origin would send the site's own handoff codes to the
    # domain the sandbox exists to keep them away from.
    #
    # Without this the demo signed in against dot-auth's exported default, which is the
    # production site -- so a development page was starting an auth flow against
    # production, and did so on every load.
    printf '{\n  "backbone_url": "%s"\n}\n' "$SITE_URL" > client/auth.json
    ok "web player signs in against $SITE_URL"

    # [b]Rebuilt when the game is newer than the build, not only when it is missing.[/b]
    # The server runs the project directly and the browser runs an export of it, so a
    # source change moves one and not the other -- and the two then disagree about a
    # wire format or a scene while both look healthy. That is a whole evening: the
    # server ticks, the client connects, signon completes, and not one game message
    # crosses.
    # [b]Every vendored directory, and every file type, not just the scripts.[/b] This
    # watched `game scenes client host` for `.gd` and `.tscn` alone, and a browser
    # client is made of more than its scripts: the maps are 60 MB of data under
    # `maps/imported/`, the prototype textures are PNGs under `textures/`, and the
    # avatars and props are scenes and images too. Re-import a map or drop in a texture
    # and nothing here was newer, so the export was declared up to date and the browser
    # kept serving the old .pck -- while the SERVER, which runs the project directly,
    # had the new one. That is the same server-and-browser divergence the paragraph
    # above is about, arriving through the assets instead of through the code.
    #
    # `.uid` and `.import` are excluded because `setup.sh` deletes and regenerates them
    # on every run, so including them would rebuild a 110 MB export every time.
    local newest stale=0
    newest="$(find game scenes client host maps textures avatars npcs props \
        -type f ! -name '*.uid' ! -name '*.import' \
        -newer web/build/index.wasm -print -quit 2>/dev/null)"

    if [ ! -f web/build/index.wasm ]; then
        warn "no export yet; building one"
        stale=1
    elif [ -n "$newest" ]; then
        warn "the game is newer than the export ($newest); rebuilding"
        stale=1
    fi

    if [ "$stale" -eq 1 ]; then
        ./server export-web --base "$GAME_ORIGIN/game/" || exit 1
    else
        ok "up to date"
    fi

    # Published where nginx can read it. /home is not traversable by www-data, which
    # is why this is a copy and not an alias into the checkout.
    if sudo -n true 2>/dev/null; then
        sudo mkdir -p "$PUBLISH_DIR"
        sudo cp -r web/build/. "$PUBLISH_DIR"/
        sudo chmod -R a+rX "$PUBLISH_DIR"
        ok "published to $PUBLISH_DIR"
    else
        warn "no passwordless sudo; skipping publish to $PUBLISH_DIR"
    fi

    step "the website"

    if listening "$SITE_PORT"; then
        ok "already listening on $SITE_PORT"
    elif [ -d "$SITE_DIR" ]; then
        (
            cd "$SITE_DIR" || exit 1
            DATABASE_URL="$DB" \
            NEXT_PUBLIC_CDN_URL="$CDN" \
            nohup npx next dev -p "$SITE_PORT" > "$RUN/site.log" 2>&1 &
            echo $! > "$RUN/site.pid"
        )

        if wait_for_port "$SITE_PORT" 180; then
            ok "listening on $SITE_PORT  (log: data/demo/site.log)"
        else
            warn "it did not come up in time — see data/demo/site.log"
        fi
    else
        warn "website-city is not at $SITE_DIR; skipping"
    fi

    step "nginx"

    # Every public port, not only the first. A game server whose TLS listener was never
    # installed is up, healthy and reachable on the loopback, and completely invisible
    # to a browser -- and the previous version of this step checked one port and said
    # "ok", which is a check reporting its healthy case while blind to four others.
    for pair in "$PUBLIC_PORT:$GAME_PORT" \
                "$GAME2_PUBLIC_PORT:$GAME2_PORT" \
                "$GAME3_PUBLIC_PORT:$GAME3_PORT" \
                "$GAME4_PUBLIC_PORT:$GAME4_PORT" \
                "$GAME5_PUBLIC_PORT:$GAME5_PORT"; do
        local public="${pair%%:*}" backend="${pair##*:}"

        if listening "$public"; then
            ok "TLS on $public -> $backend"
        else
            warn "nothing on $public — install it once with:"
            say "  sudo ./deploy/install-server-tls.sh --domain $HOST \\"
            say "       --port $public --backend 127.0.0.1:$backend"
        fi
    done

    do_links
}

do_links() {
    cat <<LINKS

$BLD  Open one of these.$OFF

    ${BLD}https://$HOST/play?tab=servers&app=69${OFF}
        The play centre. Press Join on TMC Test Server and the game opens
        inside the site's own player.

    $GAME_ORIGIN/game/embed.html?server=wss://$HOST:$PUBLIC_PORT
        The lobby server, standalone, with no website around it.

    $GAME_ORIGIN/game/embed.html?server=wss://$HOST:$GAME2_PUBLIC_PORT
        The Hungry server, standalone.

    $GAME_ORIGIN/game/embed.html?server=wss://$HOST:$GAME3_PUBLIC_PORT
        The bhop/surf timer. WASD, hold space, Tab cycles style, R restarts.

    $GAME_ORIGIN/game/embed.html?server=wss://$HOST:$GAME4_PUBLIC_PORT
        The sandbox. Hold Q for the spawn menu, click a prop to spawn it,
        Mouse 1 grabs with the physics gun, Mouse 2 freezes, Z undoes.

    $GAME_ORIGIN/game/embed.html?server=wss://$HOST:$GAME5_PUBLIC_PORT
        The deathmatch. WASD, Mouse 1 fires, 1-4 pick a weapon, R reloads,
        Tab is the scoreboard, Esc pauses.

$DIM    The certificate is self-signed, so a browser will warn once.$OFF

$BLD  While somebody is playing:$OFF

    ./demo.sh switch hungry_classic     they move to Hungry, still connected
    ./demo.sh switch lobby              and back

LINKS
}

# --- down ------------------------------------------------------------------

do_down() {
    step "stopping"

    # [b]server2 and server3 were written and never stopped by name.[/b] Only the port
    # sweep below caught them, which works until a second server is listening on a port
    # this script does not know about -- and then it is left running with its pidfile
    # deleted, which is the state nothing can clean up.
    for name in server server2 server3 server4 server5 site; do
        local pidfile="$RUN/$name.pid"
        [ -f "$pidfile" ] || continue

        local pid
        pid="$(cat "$pidfile")"

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # The process group: ./server execs Godot and `next dev` forks a worker,
            # so killing the shell's own pid leaves the real one holding the port.
            kill -- "-$(ps -o pgid= "$pid" | tr -d ' ')" 2>/dev/null || kill "$pid" 2>/dev/null
            ok "stopped $name (pid $pid)"
        fi

        rm -f "$pidfile"
    done

    # Anything left holding the ports, whoever started it. A demo that half-stops is
    # worse than one that does not stop: the next `up` says "already listening" and
    # serves the old build.
    for port in "$GAME_PORT" "$GAME2_PORT" "$GAME3_PORT" "$GAME4_PORT" \
                "$GAME5_PORT" "$SITE_PORT"; do
        local pid
        pid="$(port_pid "$port")"
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null && ok "freed port $port (pid $pid)"; }
    done

    say "nginx is left running: it is shared, and it serves more than this."
}

# --- status ----------------------------------------------------------------

do_status() {
    step "status"

    for pair in "game server:$GAME_PORT" "game server 2:$GAME2_PORT" \
                "game server 3:$GAME3_PORT" \
                "game server 4:$GAME4_PORT" \
                "game server 5:$GAME5_PORT" \
                "website:$SITE_PORT" "nginx TLS:$PUBLIC_PORT" \
                "nginx TLS 2:$GAME2_PUBLIC_PORT" "nginx TLS 3:$GAME3_PUBLIC_PORT" \
                "nginx TLS 4:$GAME4_PUBLIC_PORT" "nginx TLS 5:$GAME5_PUBLIC_PORT"; do
        local label="${pair%%:*}" port="${pair##*:}"
        if listening "$port"; then
            local pid
            pid="$(port_pid "$port")"
            ok "$(printf '%-12s %s' "$label" "port $port${pid:+, pid $pid}")"
        else
            bad "$(printf '%-12s %s' "$label" "port $port, not listening")"
        fi
    done

    if listening "$GAME_PORT" && [ -f tools/rcon.mjs ] && command -v node >/dev/null; then
        step "the server says"
        node tools/rcon.mjs status 2>/dev/null | sed 's/^/  /' || warn "RCON did not answer"
    fi
}

# --- switch ----------------------------------------------------------------

do_switch() {
    local game="${1:-}"
    [ -n "$game" ] || { bad "which game? (lobby, hungry_classic, hungry_frenzy)"; exit 2; }

    listening "$GAME_PORT" || { bad "the game server is not running"; exit 1; }

    step "changing to $game"
    node tools/rcon.mjs "changelevel $game" 2>&1 | sed 's/^/  /'
}

case "${1:-up}" in
    up)     do_up ;;
    down)   do_down ;;
    status) do_status ;;
    switch) shift; do_switch "${1:-}" ;;
    links)  do_links ;;
    -h|--help|help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) bad "unknown command: $1  (up | down | status | switch <game>)"; exit 2 ;;
esac

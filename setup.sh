#!/usr/bin/env bash
#
# One command to go from a clone to a server you can start.
#
#   ./setup.sh                  set everything up and write ./server
#   ./setup.sh --check          set up, then boot the server once and shut it down
#   ./setup.sh --no-import      skip the Godot import pass (fast, for a re-run)
#   ./setup.sh --godot PATH     use a specific runtime
#   ./setup.sh --no-download    never fetch a runtime; fail if there is none
#   ./setup.sh --vendor         COPY the addons instead of linking them
#
# WHAT IT DOES, AND WHY EACH STEP IS HERE
#
#   1. Finds a Godot 4.7+ runtime, and DOWNLOADS the pinned one when the machine has
#      none. That download is tools/fetch-godot.sh and the verification is the whole
#      of it: one pinned version, the sha512 checked into git rather than fetched
#      from beside the binary, and no path through it that installs something
#      unverified. `--no-download` keeps the old behaviour of refusing to fetch.
#   2. Wires in the dot-* addons. Each one is a separate repository and there is no
#      way to clone the tree at once, so this is the one place that knowledge lives.
#      Symlinks when the sibling repositories are there, which is a developer
#      checkout; a copy otherwise, which is what a release tarball needs.
#   3. Copies every built-in game into the build. They are `kind: builtin`, and the
#      reason is measured rather than assumed -- see content/lobby/game.yml.
#   4. Runs Godot's import pass. Without it every class_name global is unresolved,
#      every cross-file type reference fails, and the whole thing looks like dozens
#      of unrelated errors.
#   5. Writes cfg/*.yml if they are missing, generating an RCON password ONCE if it
#      writes cfg/rcon.yml at all, and printing it once. A checkout already HAS that
#      file, shipped with RCON off, so this branch is for a release tarball rather
#      than a clone. It never overwrites a config file that exists: your edits are
#      the configuration, and regenerating on upgrade throws them away on the one run
#      nobody is watching.
#   6. Writes ./server.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

GODOT_ARG=""
DO_IMPORT=1
# A box with no network, or a policy that says binaries arrive one way and it is not
# this one. TMC_NO_DOWNLOAD is the same switch for a unit file or a CI job, which
# cannot add an argument to a line somebody else wrote.
DO_DOWNLOAD=1
[ -n "${TMC_NO_DOWNLOAD:-}" ] && DO_DOWNLOAD=0
DO_CHECK=0
VENDOR=0

while [ $# -gt 0 ]; do
    case "$1" in
        --godot)     GODOT_ARG="${2:-}"; shift 2 ;;
        --no-import) DO_IMPORT=0; shift ;;
        --no-download) DO_DOWNLOAD=0; shift ;;
        --check)     DO_CHECK=1; shift ;;
        --vendor)    VENDOR=1; shift ;;
        -h|--help)   sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; BLD=$'\033[1m'; OFF=$'\033[0m'

step() { printf '\n%s==>%s %s\n' "$BLD" "$OFF" "$1"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1"; }
die()  { printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }

# --- 1. The runtime --------------------------------------------------------

step "Godot runtime"

# The pinned version lives in tools/fetch-godot.sh, with the digest that proves it.
PINNED="$(tools/fetch-godot.sh --version 2>/dev/null)"
PINNED_CACHE="${TMC_GODOT_CACHE:-${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}/tmc/godot}/${PINNED:-none}/godot"

# Is this thing a runtime new enough to build with? Prints the version when it is,
# nothing when it is not -- so a caller can test one candidate without dying on it.
godot_version_ok() {
    local v
    v="$("$1" --version 2>/dev/null | head -1)"
    case "$v" in
        4.[7-9]*|4.[1-9][0-9]*|5.*) printf '%s' "$v" ;;
        *) return 1 ;;
    esac
}

# An explicit --godot is not a suggestion. A wrong one that silently became a
# download would be a script quietly ignoring the argument it was given, and the
# operator would never learn that the runtime they meant to test was not the one
# that ran.
if [ -n "$GODOT_ARG" ]; then
    if command -v "$GODOT_ARG" >/dev/null 2>&1; then GODOT="$(command -v "$GODOT_ARG")"
    elif [ -x "$GODOT_ARG" ]; then GODOT="$GODOT_ARG"
    else die "no runtime at $GODOT_ARG" 3
    fi
    VERSION="$(godot_version_ok "$GODOT")" \
        || die "Godot 4.7 or newer is required; $GODOT is $("$GODOT" --version 2>&1 | head -1)" 3
    ok "$GODOT ($VERSION)"
else
    # The cache first, then PATH. The downloaded one is checked BEFORE `godot` on
    # PATH because it is the version this project is pinned to and the one on PATH
    # is whatever the box happens to have -- and if the box's is fine, it was found
    # on the first run and no download ever happened.
    GODOT=""
    VERSION=""
    for candidate in "$PINNED_CACHE" "$ROOT/.godot-runtime/${PINNED:-none}/godot" godot godot4 Godot; do
        [ -n "$candidate" ] || continue
        resolved=""
        if command -v "$candidate" >/dev/null 2>&1; then resolved="$(command -v "$candidate")"
        elif [ -x "$candidate" ]; then resolved="$candidate"
        fi
        [ -n "$resolved" ] || continue
        if VERSION="$(godot_version_ok "$resolved")"; then GODOT="$resolved"; break; fi
        # Found and too old. Remembered rather than reported now: it only matters if
        # nothing better turns up, and "4.4 is too old" above "downloaded 4.7.2" is
        # an error message about a thing that did not go wrong.
        TOO_OLD="$resolved ($("$resolved" --version 2>&1 | head -1))"
    done

    if [ -n "$GODOT" ]; then
        ok "$GODOT ($VERSION)"
    elif [ "$DO_DOWNLOAD" -eq 0 ]; then
        die "No Godot 4.7+ runtime found${TOO_OLD:+ ($TOO_OLD is too old)}, and downloading is off (--no-download / TMC_NO_DOWNLOAD).

    Install Godot 4.7 or newer and put it on PATH, or:
        ./setup.sh --godot /path/to/godot" 3
    else
        # [b]This used to be where setup.sh gave up[/b], on the grounds that fetching a
        # binary means verifying it and that is a different program with different
        # risks. The reasoning was right and the conclusion was backwards: it made
        # every fresh box a manual download before anything could be tried, and the
        # verification it was avoiding is thirty lines. tools/fetch-godot.sh IS that
        # different program -- one pinned version, digests checked into git rather
        # than fetched beside the binary, and no path through it that installs
        # something unverified.
        [ -n "${TOO_OLD:-}" ] && warn "$TOO_OLD is too old"
        [ -x tools/fetch-godot.sh ] || die "tools/fetch-godot.sh is missing or not executable" 3

        warn "no Godot 4.7 or newer on this machine; fetching the pinned ${PINNED:-runtime}"
        GODOT="$(tools/fetch-godot.sh)" || exit 3
        VERSION="$(godot_version_ok "$GODOT")" || die "the fetched runtime does not report a usable version" 3
        ok "$GODOT ($VERSION)"
    fi
fi

# --- 2. The addons ---------------------------------------------------------
#
# name:repository. The repository is the name with underscores turned into hyphens,
# which holds for every one of them and is asserted rather than assumed below.

# dot_stats is here because hungry's module declares its statistics through
# DotStatsSchema. It was missing, and could not be noticed: the vendored copy of
# hungry predated that code by nine days, and the guard against a stale copy --
# tools/check.sh -- named the game repositories by their OLD names too, so it reported
# "no game repositories beside this one" on a machine where all of them were and
# compared nothing. The first `setup.sh` that copied the current hungry turned every
# type reference in its module into a parse error, and a module that will not parse is
# a module that does not load: `changelevel hungry_classic` swapped the world and left
# the lobby's module driving it.
# Every addon any vendored game names. A game that gains a dependency and is not added
# here vendors, imports, and then fails to compile every script that names the missing
# class — dozens of "not declared in the current scope" errors in files nobody touched,
# which reads as a broken project rather than as one missing folder.
ADDONS=(dot_core dot_net dot_server dot_server_query dot_server_security dot_2d dot_ui dot_auth dot_cloud dot_user
        dot_user_avatar dot_platform dot_loadout dot_match
        dot_player_controller dot_timer dot_map dot_leaderboard dot_stats
        dot_props dot_vote dot_combat dot_chat dot_voice dot_moderation
        dot_browser dot_npc dot_npc_ai dot_npc_ai_director dot_vehicle
        dot_achievements dot_objective dot_effects dot_spectate dot_economy
        dot_settings dot_console dot_audio dot_fx dot_lighting
        dot_procedural_generation dot_inventory dot_peer_to_peer dot_weapon
        dot_physics dot_spawn dot_team dot_player dot_player_class
        dot_player_char)

step "dot-* addons"
mkdir -p addons

MISSING=()
for name in "${ADDONS[@]}"; do
    repo="${name//_/-}"
    source_dir="$ROOT/../$repo/addons/$name"

    if [ -d "$source_dir" ]; then
        if [ "$VENDOR" -eq 1 ]; then
            # Copied, not linked. A symlink out of this directory is fine on a
            # developer's machine and breaks the moment the directory is moved
            # somewhere the siblings are not -- a release tarball, or a container
            # image whose final stage copies only this project. The symptom is
            # every dot-* class_name unresolved at once, which reads as a broken
            # project rather than as a dangling link.
            rm -rf "addons/$name"
            cp -rL "$source_dir" "addons/$name"
        elif [ -L "addons/$name" ] || [ ! -e "addons/$name" ]; then
            ln -sfn "../../$repo/addons/$name" "addons/$name"
        fi
    elif [ -d "addons/$name" ]; then
        : # already vendored, which is what a release tarball looks like
    else
        MISSING+=("$repo")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    die "These addon repositories are not beside this one:

        ${MISSING[*]}

    Each dot-* project is a separate repository and there is no way to clone the
    tree at once. Clone them as siblings of this directory, or vendor their
    addons/<name> folders into ./addons/." 4
fi
ok "${#ADDONS[@]} addons $([ "$VENDOR" -eq 1 ] && echo copied || echo linked)"

# --- 3. The games ----------------------------------------------------------
#
# Every game that ships INSIDE this build is copied in here, and they all land in
# one game/ directory on purpose.
#
# A game's scenes name their scripts by absolute res:// path -- that is how a .tscn
# stores a script reference and there is no relative form -- so game-simple-lobby's
# res://game/room_world.gd and game-hungario's res://game/modes/hungry_mode.gd only
# resolve if each project's game/ becomes THIS project's game/. Moving either into a
# subdirectory of its own would mean re-authoring every scene it owns.
#
# That works because no two of them share a filename: every file is prefixed with
# its own game's name, which is the family's class_name rule paying off somewhere it
# was not aimed at. The check below asserts it rather than trusting it, because the
# failure -- one game silently overwriting a file of another's -- is invisible until
# something loads.
#
# WHY BUILT IN AND NOT DELIVERED: a mounted dot-cloud pack's class_name globals are
# not registered in the host, so every cross-file type reference inside a pack fails
# to compile -- the pack mounts, its scenes load, and every script in it is dead.
# See content/lobby/game.yml.

step "games"

# repository:label[:extra directories]
#
# The repository name is the DIRECTORY beside this one, and it is not the game's
# name: `dot-a-room` and `dot-2d-hungry` were renamed to `game-simple-lobby` and
# `game-hungario` and this list was not, so every run skipped both games -- after
# the `rm -rf` below had already deleted the vendored copies. See the ordering note
# there. A stale name here is now a hard failure rather than a warning, for the same
# reason: "skipping the lobby" scrolls past and a build with no games does not.
#
# The extra field is the top-level directories a game owns beyond game/ and scenes/.
# Same reason those two are flattened into this project: a .tscn stores its script
# reference as an absolute res:// path and there is no relative form, so
# game-g2gfast's res://maps/surf_g2g_intro.gd only resolves if its maps/ becomes
# THIS project's maps/.
#
# [b]A game that grows a top-level directory has to be added here, and nothing
# reports it if it is not.[/b] game-arena and game-g2gfast both gained npcs/ and
# props/ when the NPC and prop layers landed; a build vendored without them mounts,
# loads every scene, and refuses every spawn with "that NPC's content is not loaded on
# this server" -- which is dot-npc answering correctly a question nobody meant to ask.
# The refusal is a legitimate answer, so nothing errors.
#
# Filenames are prefixed per game (`arena_grunt.tscn`, `g2g_stalker.tscn`) so the two
# can share one flattened directory, which is the collision check below.
#
# g2gfast's `textures/` is the newest of these and is the same shape of omission:
# `G2GTextures` looks its prototype set up at the fixed path `res://textures/prototype`
# and falls back to a generated grid when it is not there, so a build without it draws
# every map -- imported ones included, which is most of what that server runs -- in a
# different texture set from the one the developer looked at, and reports nothing.
GAMES=(
    "game-simple-lobby:the lobby"
    "game-hungario:hungry"
    "game-g2gfast:g2gfast:maps avatars npcs props textures"
    "game-playground:playground:maps"
    "game-arena:arena:maps avatars npcs props"
)

# --- Resolve before destroying ---------------------------------------------
#
# [b]The wipe below used to come first, and that made a stale repository name
# destructive.[/b] Both entries had been renamed, so setup.sh deleted game/ and
# scenes/, warned twice, and died with "No games were found beside this repository,
# and none are vendored" -- having just made that true. A vendored tarball, which is
# exactly the case the message is about, lost its games to the run that reported
# them missing.
#
# So: find every source first, refuse the whole run if one is missing, and only then
# remove anything.

GAME_DIRS=()
MISSING_GAMES=()
for entry in "${GAMES[@]}"; do
    repo="${entry%%:*}"
    rest="${entry#*:}"
    extra=""
    [ "$rest" != "${rest%%:*}" ] && extra="${rest#*:}"

    if [ -d "$ROOT/../$repo/game" ]; then
        GAME_DIRS+=("$extra")
    else
        MISSING_GAMES+=("$repo")
    fi
done

# Three cases, and only three. Every game beside this one is a developer's machine
# and the copy runs; none of them beside it, with a game/ already here, is a release
# tarball and the copy is skipped whole. Anything in between -- which is what a
# rename produces -- is refused, because copying the games that are still there over
# a vendored set of the ones that are not gives one build made of two vintages.
if [ ${#MISSING_GAMES[@]} -eq 0 ]; then
    # Only the directories this list declares, so a typo cannot remove anything the
    # script did not put there.
    rm -rf game scenes
    for extra in "${GAME_DIRS[@]}"; do
        for dir in $extra; do rm -rf "${ROOT:?}/$dir"; done
    done
    mkdir -p game scenes
elif [ ${#MISSING_GAMES[@]} -eq ${#GAMES[@]} ] && [ -n "$(ls -A "$ROOT/game" 2>/dev/null)" ]; then
    ok "no game repositories beside this one; keeping the vendored games"
    VENDORED_GAMES=1
else
    die "These game repositories are not beside this one:

        ${MISSING_GAMES[*]}

    Each game is a separate repository and there is no way to clone the tree at
    once. Clone them as siblings of this directory, or vendor their game/ folders.

    If one was RENAMED, fix the GAMES list in this script. A name here that no
    longer exists is how this step silently stopped copying a game -- and it used
    to delete game/ before finding out, so the run that reported the games missing
    was the run that made them missing." 4
fi

copied_any=0
[ "${VENDORED_GAMES:-0}" -eq 1 ] && copied_any=1
for entry in "${GAMES[@]}"; do
    [ "${VENDORED_GAMES:-0}" -eq 1 ] && break

    repo="${entry%%:*}"
    rest="${entry#*:}"
    label="${rest%%:*}"
    extra=""
    [ "$rest" != "$label" ] && extra="${rest#*:}"
    src="$ROOT/../$repo"

    # Refuse a collision rather than let cp resolve it. Two games contributing the
    # same filename means one of them silently loses a script, and the symptom is a
    # parse error in a file nobody edited.
    for sub in game $extra; do
        [ -d "$src/$sub" ] || continue
        while read -r f; do
            rel="${f#"$src"/}"
            if [ -e "$ROOT/$rel" ]; then
                # Byte-identical is not a collision. Two games legitimately ship the
                # same third-party asset -- both arena and g2gfast use Kenney's
                # character GLBs, copied from one source -- and vendoring them into
                # the shared tree would otherwise be refused, or force a per-game copy
                # of every byte. The rule this guards is "one of them silently loses a
                # script", and a file that is the same file loses nothing.
                if cmp -s "$f" "$ROOT/$rel"; then
                    continue
                fi
                # Godot regenerates these for THIS project on the --import below, and
                # mints a fresh uid per project while doing it -- so two games' copies
                # of the same asset always differ here and never mean anything. The
                # asset itself is compared above; this is its bookkeeping.
                case "$rel" in
                    *.import|*.uid) continue ;;
                esac
                die "$repo and an earlier game both provide $rel, with different contents.

    Every built-in game shares one game/ directory, because a .tscn names its
    scripts by absolute res:// path. Rename one of them." 4
            fi
        done < <(find "$src/$sub" -type f)
    done

    # -a preserves timestamps. Without it every setup.sh gives identical files a fresh
    # mtime, so anything that asks "is the build older than the source" -- demo.sh does,
    # to catch a stale web export -- rebuilds on every run for no reason.
    cp -a "$src/game/." game/
    [ -d "$src/scenes" ] && cp -a "$src"/scenes/*.tscn scenes/ 2>/dev/null

    for dir in $extra; do
        [ -d "$src/$dir" ] || continue
        mkdir -p "$ROOT/$dir"
        cp -a "$src/$dir/." "$ROOT/$dir/"
    done

    # Cosmetic parts a game looks for in its own build. HungryContentSource reads
    # res://content/avatars/, and content/ here is the operator's game directory --
    # so this lands beside the games and TmcContent knows it is not one.
    if [ -d "$src/content/avatars" ]; then
        mkdir -p content/avatars
        cp -a "$src/content/avatars/." content/avatars/
    fi

    ok "$label"
    copied_any=1
done

# The .uid files are Godot's own and are regenerated by --import. Copying one from a
# source project pins this build's script to that project's uid, and two games whose
# uids were generated separately can then collide.
UID_DIRS=(game scenes content/avatars)
for extra in "${GAME_DIRS[@]}"; do
    for dir in $extra; do UID_DIRS+=("$dir"); done
done
find "${UID_DIRS[@]}" -name '*.uid' -delete 2>/dev/null

if [ "$copied_any" -eq 0 ]; then
    die "No games were found beside this repository, and none are vendored." 4
fi

# --- 4. Import -------------------------------------------------------------

if [ "$DO_IMPORT" -eq 1 ]; then
    step "importing"
    # Re-run after ANY script with a new class_name is added. Without it the
    # identifier does not resolve, the scene fails to load, and the process HANGS
    # rather than exiting, because nothing ever reaches get_tree().quit().
    "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1
    ok "class_name globals registered"
fi

# --- 5. Configuration ------------------------------------------------------

step "configuration"
mkdir -p cfg cfg/content content/global data

if [ -f cfg/server.yml ]; then
    ok "cfg/ already exists and was not touched"
    NEW_CONFIG=0
else
    NEW_CONFIG=1
fi

# Written before anything goes into it, so the password is never briefly readable.
umask_old="$(umask)"
umask 077

write_if_missing() {
    [ -f "$1" ] && return 0
    cat > "$1"
    printf '    %s+%s    %s\n' "$GRN" "$OFF" "$1"
}

write_if_missing cfg/server.yml <<'YML'
# General server settings.
#
# Anything dot-server exposes as a console variable can go here too, under its own
# name -- this file is compiled to a .cfg and handed to dot-server's console, which
# is the parser and the validator. data/from_yaml.cfg is what it became; read that
# when a setting appears not to work.

sv_name: "TMC Test Server"
sv_maxplayers: 64

# Empty means anyone may join.
sv_password: ""

# Simulation rate. Higher is more responsive and costs CPU and bandwidth on every
# client as well as here. Fixed at boot.
sv_tickrate: 60

# The game to load at boot. Empty uses whichever content directory is marked
# default. A server with no game at all is legitimate and runs empty.
sv_game: ""

# The app's URL segment on the website, reported in a query as the game's name.
#
# Unique and lowercase because the site already made it so, which is the whole
# reason to reuse it rather than invent a second identifier that has to be kept in
# step. Empty falls back to the running game's id, which is the right answer on a
# box running one game.
#
# DISPLAY ONLY. A server can claim any app it likes, and nothing that has to be
# certain which app a server belongs to -- a launch resolving a build, a play grant
# -- reads this. Those ask the backbone, which knows. It is what a listing prints
# next to the hostname, and it is also A2S's `folder`, which is the field trackers
# group servers by.
#
# `sv_query_app` is also a cvar, so it can be changed on a running server.
sv_query_app: ""

sv_tags: [lobby, tmc]
YML

write_if_missing cfg/net.yml <<'YML'
# Network & Bind

net_bind_ip: "0.0.0.0"
net_port: 6064

# Uses Bind IP if not set. Only needed if the server is behind NAT. Nothing binds
# to it -- it is what the join address is printed from and what a listing reports.
net_public_ip: ""

# Performance
# -----------------------------------------
# Maximum bytes per second per client.
net_max_bps: 1000000

# Maximum number of packets per second per client.
net_max_pps: 60

# Max number of network updates per second a client can send or receive.
net_max_update_rate: 66
YML

write_if_missing cfg/auth.yml <<'YML'
# Authentication.
#
# Absent or disabled, everybody arrives as a guest with a per-device id through
# DotGuestIdentity, and the server works. That is the simplest deployment there is
# and it is deliberately a supported one.
#
# WORTH KNOWING: DotAdminManager refuses permissions to any unauthenticated
# session -- a guest uid is a random per-device string, so granting anything to one
# grants it to anyone. Until this is wired up, cfg/permissions.yml has no effect and
# the local console is the only administrator. That is correct, and it looks exactly
# like the file being ignored.

enabled: false

backend:
  type: "rest"
  url: "http://localhost:8000"
  timeout: 30
  retries: 3
  verify:
    type: "jwt"
    # A connect ticket is verified offline against a public key. A server operator
    # holds a public key and nothing else, which is what makes third-party servers
    # safe to allow at all.
    public_key_file: "cfg/issuer.pub.pem"
YML

write_if_missing cfg/groups.yml <<'YML'
# Permission groups.
#
# dot-server's model is FLAGS, not roles -- operators do not agree on what a
# "moderator" is, and a game adds "slay" or "noclip" without coordinating with
# anybody. This file is the translation: a group is a name for a set of flags.
#
# is_root is every flag there is, present and future.

groups:
  owner:
    is_root: true
    immunity: 100
  admin:
    immunity: 80
    permissions:
      - "kick"
      - "ban"
      - "mute"
      - "warn"
      - "announce"
      - "change"
  moderator:
    immunity: 50
    permissions:
      - "kick"
      - "mute"
      - "warn"
      - "announce"
YML

write_if_missing cfg/permissions.yml <<'YML'
# Who is in which group.
#
# The key is matched against a player's account uid, username and display name, in
# that order, case-insensitively -- an operator writes whichever of the three they
# know.
#
# Immunity is separate from flags because "may kick" and "may be kicked" are
# different questions. Equal immunity cannot act on equal: two admins at the same
# level kicking each other in a loop has no correct resolution, so it is forbidden
# rather than raced.
#
# See cfg/auth.yml: without authentication this file does nothing.

users:
  gamemann:
    group: owner
YML

if [ ! -f cfg/rcon.yml ]; then
    RCON_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
    cat > cfg/rcon.yml <<YML
# Remote console.
#
# An EMPTY password means the RCON listener does not open at all, which is the right
# setting for a server nobody administers remotely. There is no configuration that
# produces an unauthenticated remote console.
#
# This password was generated once, when setup.sh first ran, and printed once. Change
# it here if you like. Do NOT put it in a command line or an environment variable:
# both are readable by any other process on the machine and both end up in pasted bug
# reports, which is why ./server refuses --rcon-password outright.
#
# rcon_allowed is the control that survives a leaked password. Populate it.

rcon_password: "$RCON_PASSWORD"
rcon_port: 0            # 0 uses the game port + 1
rcon_allowed: []        # empty allows any address
rcon_websocket: false   # for a browser-based admin panel
YML
    NEW_RCON=1
fi

umask "$umask_old"
[ "$NEW_CONFIG" -eq 1 ] && ok "cfg/ written"

# --- 6. ./server -----------------------------------------------------------

step "./server"

[ -f tools/server.in ] || die "tools/server.in is missing" 1
sed "s|@GODOT@|$GODOT|g" tools/server.in > server
chmod +x server
ok "written, using $GODOT"

# --- Done ------------------------------------------------------------------

if [ "${NEW_RCON:-0}" -eq 1 ]; then
    printf '\n%s  RCON password (printed once, it is in cfg/rcon.yml):%s\n' "$BLD" "$OFF"
    printf '      %s\n' "$RCON_PASSWORD"
fi

if [ "$DO_CHECK" -eq 1 ]; then
    step "checking"
    if ./server check; then
        ok "the server boots, loads the lobby, and shuts down"
    else
        die "the server did not come up. Run ./server check --verbose" 1
    fi
fi

cat <<DONE

$BLD  Ready.$OFF

    ./server                 start it
    ./server check           boot once and exit, for CI
    ./server config          what your YAML became
    ./server --help          every option

    docker compose up -d     the same thing in a container

DONE

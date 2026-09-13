#!/usr/bin/env bash
#
# Make this server a service that comes back after a reboot.
#
#   sudo ./deploy/install-systemd.sh
#   sudo ./deploy/install-systemd.sh --name arena --user games --no-start
#
# Writes /etc/systemd/system/<name>.service, enables it, starts it, and then CHECKS
# THAT IT IS STILL RUNNING -- an installer that reports success while the unit
# crash-loops has told you the opposite of what happened, and systemd's own
# `systemctl enable --now` exits 0 for a service that died a second later.
#
# It runs ./server, which is one `exec` away from the engine, so SIGTERM reaches the
# server itself and `systemctl stop` is a clean shutdown rather than a kill.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; DIM=$'\e[2m'; BLD=$'\e[1m'; OFF=$'\e[0m'
die()  { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }

NAME="${TMC_UNIT_NAME:-dot-server}"
# The user this runs as, and the default is the one that OWNS THE PROJECT rather
# than the one typing. sudo makes $USER root, and a game server running as root is
# a choice nobody makes on purpose -- it is what happens when an installer takes the
# invoking user and the invoking user is sudo's.
RUN_USER="${TMC_UNIT_USER:-$(stat -c '%U' "$ROOT" 2>/dev/null || echo root)}"
DESC=""
START=1
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name)        NAME="${2:?--name needs a value}"; shift 2 ;;
        --user)        RUN_USER="${2:?--user needs a value}"; shift 2 ;;
        --description) DESC="${2:?--description needs a value}"; shift 2 ;;
        --no-start)    START=0; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown argument: $1" 2 ;;
    esac
done

case "$NAME" in
    ''|*/*|*.service) die "--name is a bare unit name, without .service: $NAME" 2 ;;
esac

command -v systemctl >/dev/null 2>&1 || die "no systemctl here; this box does not use systemd" 1
[ -x "$ROOT/server" ] || die "no ./server yet. Run ./setup.sh first." 1
id "$RUN_USER" >/dev/null 2>&1 || die "no such user: $RUN_USER" 2

RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null)"
DESC="${DESC:-dot-server ($NAME)}"
UNIT="/etc/systemd/system/$NAME.service"

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

cat > "$rendered" <<UNITFILE
# Written by dot-server-deploy/deploy/install-systemd.sh.
[Unit]
Description=$DESC
# network-online.target, not network.target: the server binds an address at
# startup, and network.target is reached while the interfaces are still coming
# up -- which is a bind failure on about one boot in ten and never on one
# anybody is watching.
After=network-online.target
Wants=network-online.target

# A server that cannot start must not restart forever: five tries in a minute
# and systemd gives up and says so, which is a failed unit somebody can see --
# instead of a log that scrolls the same error past for a week. These are
# [Unit] keys, not [Service] ones; systemd has parsed them here since v230 and
# answers a copy in [Service] with "Unknown key name" in the journal, which is
# a rate limit that was never applied and a complaint nobody reads.
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$ROOT
ExecStart=$ROOT/server
Restart=on-failure
RestartSec=5s

# ProtectSystem=full, not strict. Full makes /usr, /boot and /etc read-only, which
# this never writes to. Strict would make the WHOLE filesystem read-only bar what is
# listed -- and the engine writes its import cache into the project directory, so
# the list would have to include the project itself and the protection would be
# worth nothing.
ProtectSystem=full
ProtectHome=false
PrivateTmp=true
NoNewPrivileges=true

StandardOutput=journal
StandardError=journal
SyslogIdentifier=$NAME

[Install]
WantedBy=multi-user.target
UNITFILE

if [ -n "$DRY_RUN" ]; then cat "$rendered"; exit 0; fi

$SUDO install -m 644 "$rendered" "$UNIT" || die "could not write $UNIT"
ok "$UNIT"

# The data directory is the only thing this writes, and it has to belong to the user
# the unit runs as. Set up as somebody else -- root, usually, because the rest of
# this needed sudo -- it is a permission error on the first boot and nowhere else.
if [ -d "$ROOT/data" ]; then
    owner="$(stat -c '%U' "$ROOT/data" 2>/dev/null)"
    if [ "$owner" != "$RUN_USER" ]; then
        $SUDO chown -R "$RUN_USER:$RUN_GROUP" "$ROOT/data" \
            && ok "data/ now belongs to $RUN_USER" \
            || warn "could not give data/ to $RUN_USER; the server will fail to write"
    fi
fi

$SUDO systemctl daemon-reload || die "systemctl daemon-reload failed"
$SUDO systemctl enable "$NAME" >/dev/null 2>&1 || die "could not enable $NAME"
ok "enabled at boot"

[ "$START" -eq 1 ] || { printf '\n  start it with: sudo systemctl start %s\n\n' "$NAME"; exit 0; }

$SUDO systemctl restart "$NAME" || die "could not start $NAME"

# `systemctl start` returns as soon as the process has been forked, so asking right
# here whether it is active answers "yes" for a server that is about to exit 1 on a
# configuration error. Give it a moment, then ask.
sleep 3

if $SUDO systemctl is-active --quiet "$NAME"; then
    ok "$NAME is running"
    printf '\n  %slogs%s   sudo journalctl -u %s -f\n' "$DIM" "$OFF" "$NAME"
    printf '  %sstop%s   sudo systemctl stop %s\n\n' "$DIM" "$OFF" "$NAME"
else
    printf '\n'
    $SUDO journalctl -u "$NAME" -n 20 --no-pager 2>/dev/null
    die "$NAME started and then stopped. The last twenty lines are above." 1
fi

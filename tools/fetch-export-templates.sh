#!/usr/bin/env bash
#
# Fetch the pinned Godot export templates, verify them, and install them where the
# engine looks.
#
#   tools/fetch-export-templates.sh            install them if they are not there
#   tools/fetch-export-templates.sh --check    say whether they are, and exit
#   tools/fetch-export-templates.sh --force    reinstall even if they are
#   tools/fetch-export-templates.sh --dest DIR install somewhere other than the default
#
# WHY THIS EXISTS
#
# `./server export-web` on a box that has never exported fails like this:
#
#     ERROR: Cannot export project with preset "Web" due to configuration errors:
#     No export template found at the expected path:
#     ~/.local/share/godot/export_templates/4.7.2.stable/web_nothreads_debug.zip
#
# which names a path nobody configured, for a file nothing in this repository ever
# downloaded. The runtime had this exact hole and tools/fetch-godot.sh closed it; the
# templates are the other half of the same job and were left out. Worse, the error
# `./server export-native` printed pointed at `./setup.sh`, which does not install
# them either -- so the one hint an operator got sent them somewhere that could not
# help.
#
# The verification doctrine is fetch-godot.sh's, for the same reasons, in the same
# order:
#
#   1. ONE VERSION, PINNED -- and pinned in ONE place. The version comes from
#      fetch-godot.sh, because templates that do not match the engine are refused by
#      the engine and two pins drift.
#   2. THE DIGEST IS IN THIS FILE, in git, reviewed. Not fetched from beside the
#      archive.
#   3. A MISMATCH IS FATAL AND THE FILE IS DELETED. No --force past a bad digest;
#      --force only re-does an install that already verified.
#
# To move the pin: change the version in fetch-godot.sh, then take the digest from the
# release's own SHA512-SUMS.txt, read it with your own eyes, and paste it below.
#
#   curl -fsSL https://github.com/godotengine/godot/releases/download/4.7.2-stable/SHA512-SUMS.txt
#
# It is about a gigabyte, which is why nothing downloads it as part of setting the
# project up: a server that will never export a client should not pay for one. The
# export commands fetch it at the moment it is first needed instead.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; DIM=$'\e[2m'; BLD=$'\e[1m'; OFF=$'\e[0m'
say()  { printf '    %s%s%s\n' "$DIM" "$1" "$OFF" >&2; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$OFF" "$1" >&2; }
warn() { printf '    %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }
die()  { printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }

# sha512(Godot_v<version>_export_templates.tpz), from the release's SHA512-SUMS.txt.
SHA512_TEMPLATES="ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079"

# One pin, and it is not this file's. A template set that does not match the engine is
# refused by the engine, so the two cannot be allowed to disagree -- and the way to
# guarantee that is to have only one of them be writable.
GODOT_VERSION="$("$ROOT/tools/fetch-godot.sh" --version 2>/dev/null)"
[ -n "$GODOT_VERSION" ] || die "could not read the pinned version from tools/fetch-godot.sh" 1

# `4.7.2-stable` is what the release is called; `4.7.2.stable` is what the engine
# calls the directory it looks in. The difference is one character and it is the whole
# reason an install can look complete and still not be found.
VERSION_DIR="${GODOT_VERSION%-*}.${GODOT_VERSION##*-}"

ASSET="Godot_v${GODOT_VERSION}_export_templates.tpz"
BASE_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}"

DEST_ROOT="${TMC_TEMPLATES_DIR:-${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}/godot/export_templates}"
CHECK_ONLY=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK_ONLY=1; shift ;;
        --force)   FORCE=1; shift ;;
        --dest)    DEST_ROOT="${2:?--dest needs a value}"; shift 2 ;;
        --version) printf '%s\n' "$GODOT_VERSION"; exit 0 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown argument: $1" 2 ;;
    esac
done

DEST="$DEST_ROOT/$VERSION_DIR"

# [b]Present means the files the presets actually name are present.[/b] A directory
# that exists proves nothing: a half-finished extract, an interrupted download or a
# `--dest` that was wrong once all leave one behind, and the engine then reports a
# missing template for a version that looks installed.
#
# The web presets here are the NOTHREADS ones -- the browser build ships without
# thread support, which is `DotScheduler`'s whole reason for slicing on the main
# thread -- and those are separate files from the threaded ones. Checking for the
# wrong one is an install that passes its own check and fails the export.
templates_present() {
    [ -d "$DEST" ] || return 1
    local f
    for f in web_nothreads_debug.zip web_nothreads_release.zip \
             linux_debug.x86_64 linux_release.x86_64; do
        [ -f "$DEST/$f" ] || return 1
    done
    return 0
}

if templates_present && [ "$FORCE" -eq 0 ]; then
    ok "export templates for $VERSION_DIR are installed"
    say "$DEST"
    exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "no export templates for $VERSION_DIR in $DEST_ROOT"
    exit 1
fi

# --- What it takes to do this safely ---------------------------------------

if   command -v curl >/dev/null 2>&1; then FETCH=curl
elif command -v wget >/dev/null 2>&1; then FETCH=wget
else die "need curl or wget to download the export templates" 3
fi

if   command -v sha512sum >/dev/null 2>&1; then SHA="sha512sum"
elif command -v shasum    >/dev/null 2>&1; then SHA="shasum -a 512"
elif command -v openssl   >/dev/null 2>&1; then SHA="openssl-512"
else die "need sha512sum, shasum or openssl to verify the download.

    This script will not install templates it cannot check." 3
fi

if   command -v unzip   >/dev/null 2>&1; then UNZIP=unzip
elif command -v python3 >/dev/null 2>&1; then UNZIP=python3
else die "need unzip or python3 to unpack the download" 3
fi

# --- Download ---------------------------------------------------------------

TMP="$(mktemp -d "${TMPDIR:-/tmp}/godot-templates.XXXXXX")" || die "could not make a temporary directory" 1
trap 'rm -rf "$TMP"' EXIT

say "downloading $ASSET (about a gigabyte)"
say "from $BASE_URL"

case "$FETCH" in
    curl) curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$TMP/$ASSET" "$BASE_URL/$ASSET" 2>"$TMP/fetch.err" ;;
    wget) wget -q --tries=3 --timeout=20 -O "$TMP/$ASSET" "$BASE_URL/$ASSET" 2>"$TMP/fetch.err" ;;
esac

if [ $? -ne 0 ] || [ ! -s "$TMP/$ASSET" ]; then
    die "could not download $BASE_URL/$ASSET

    $(head -3 "$TMP/fetch.err" 2>/dev/null)

    No network, or a proxy in the way. Download it by hand on a machine that has
    one, unzip it, and put the contents at:
        $DEST" 3
fi

# --- Verify -----------------------------------------------------------------
#
# Before anything is unpacked. A .tpz is a zip, parsed by a C library, and these
# files are handed to the engine to produce executables -- a tampered template is a
# tampered game on every platform this exports to.

case "$SHA" in
    openssl-512) GOT="$(openssl dgst -sha512 "$TMP/$ASSET" 2>/dev/null | awk '{print $NF}')" ;;
    *)           GOT="$($SHA "$TMP/$ASSET" 2>/dev/null | awk '{print $1}')" ;;
esac

[ -n "$GOT" ] || die "could not compute a digest of the download" 3

if [ "$GOT" != "$SHA512_TEMPLATES" ]; then
    rm -f "$TMP/$ASSET"
    die "CHECKSUM MISMATCH on $ASSET -- the file has been deleted.

    expected  $SHA512_TEMPLATES
    got       $GOT

    This is either a corrupted download, or a file that is not the one this script
    was pinned to. Re-run once; if it happens again, do NOT work around it." 4
fi

ok "sha512 verified"

# --- Unpack -----------------------------------------------------------------
#
# The archive holds one top-level `templates/` directory; the engine wants its
# CONTENTS in a directory named for the version. Extracting it as-is gives
# `.../4.7.2.stable/templates/web_nothreads_debug.zip`, one level too deep, and every
# preset then reports a missing template beside a directory full of them.

case "$UNZIP" in
    unzip)   unzip -q -o "$TMP/$ASSET" -d "$TMP/x" || die "could not unpack $ASSET" 3 ;;
    python3) python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
                 "$TMP/$ASSET" "$TMP/x" || die "could not unpack $ASSET" 3 ;;
esac

[ -d "$TMP/x/templates" ] || die "the archive did not contain a templates/ directory" 3

mkdir -p "$DEST_ROOT" || die "could not create $DEST_ROOT" 1

# Into place in one move, from the same filesystem, so an interrupted install cannot
# leave a half-populated version directory that `templates_present` would later have
# to be clever about.
STAGE="$DEST_ROOT/.$VERSION_DIR.incoming.$$"
rm -rf "$STAGE"
mv "$TMP/x/templates" "$STAGE" 2>/dev/null || cp -r "$TMP/x/templates" "$STAGE" \
    || die "could not stage the templates in $DEST_ROOT" 1

rm -rf "$DEST"
mv "$STAGE" "$DEST" || die "could not install the templates at $DEST" 1

if ! templates_present; then
    die "the templates installed at $DEST but the files the presets name are not there" 3
fi

ok "export templates installed at $DEST"
printf '%s\n' "$DEST"

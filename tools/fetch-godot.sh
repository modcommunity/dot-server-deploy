#!/usr/bin/env bash
#
# Fetch the pinned Godot runtime, verify it, and print the path to it on stdout.
#
#   tools/fetch-godot.sh                 into the cache, printing the path
#   tools/fetch-godot.sh --dest DIR      unpack the binary into DIR instead
#   tools/fetch-godot.sh --version       print the pinned version and exit
#
# Everything it says to a person goes to stderr, because stdout is the path and a
# caller reads it with $(...).
#
# WHY THIS EXISTS
#
# setup.sh used to refuse to download a runtime, and the reason it gave was right:
# fetching a binary means verifying it, and a script that fetches without verifying
# is a supply chain with nobody in it. That is an argument for doing the verification,
# though, not for making every operator do the download by hand -- which is what it
# had become, on every fresh box, before anything else could be tried.
#
# So the verification is the program:
#
#   1. ONE VERSION, PINNED. Not "latest". A digest only means something against a
#      file that cannot change, and `latest` changes.
#   2. THE DIGESTS ARE IN THIS FILE, in git, reviewed. They are NOT fetched from
#      beside the binary: a SHA512-SUMS.txt served by whoever served the zip is
#      checked by whoever would have had to tamper with both, which is one thing.
#      Trust is established once, here, by a person, and every later run is an
#      equality test against it.
#   3. A MISMATCH IS FATAL AND THE FILE IS DELETED. There is no --force, no "checksum
#      unavailable, continuing", and no path through this script that installs an
#      unverified binary. That is the entire value of the thing.
#
# To move the pin: change GODOT_VERSION, then take the digests from the release's own
# SHA512-SUMS.txt, read them with your own eyes, and paste them below.
#
#   curl -fsSL https://github.com/godotengine/godot/releases/download/4.8-stable/SHA512-SUMS.txt

set -uo pipefail

# The version the family targets. docs/engine.md says why, and the Dockerfile's
# GODOT_VERSION is this same string -- it builds its runtime stage with this script.
GODOT_VERSION="4.7.2-stable"

# sha512(file), from the release's SHA512-SUMS.txt. See the note above.
SHA512_linux_x86_64="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"
SHA512_linux_arm64="dd59918da086bd49bde2f5450b5e567ff8650cbde9abbd7b8f4ca1197ff8c609baa38834666d032deafb47099078d7822279e2a0e06e5665745468f26533e7e2"
SHA512_macos_universal="38aa16e5bba2083941fc5b3e54be0089bd4cc35e32415f5b9fd9a8a6a7b9818255d44532ea8ef94b5aef56c4b407c2d634fa4f657e4ebe681ebbf59b7bac69ca"

BASE_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}"

DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)    DEST="${2:-}"; shift 2 ;;
        --version) printf '%s\n' "$GODOT_VERSION"; exit 0 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say()  { printf '    %s%s%s\n' "$DIM" "$1" "$OFF" >&2; }
die()  { printf '\n    %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }

## Install a system package, if this machine lets us without asking a human.
##
## Returns non-zero and says nothing when it cannot, so the caller falls through to
## printing the command for a person to run.
install_package() {
    local deb="$1" rpm="$2" arch="$3" sudo_cmd=""

    if [ "$(id -u)" = "0" ]; then
        sudo_cmd=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo_cmd="sudo"
    else
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1 && [ -n "$deb" ]; then
        say "installing $deb"
        $sudo_cmd apt-get update -qq >/dev/null 2>&1
        # shellcheck disable=SC2086
        $sudo_cmd apt-get install -y -qq --no-install-recommends $deb >/dev/null 2>&1 || return 1
    elif command -v dnf >/dev/null 2>&1 && [ -n "$rpm" ]; then
        say "installing $rpm"
        # shellcheck disable=SC2086
        $sudo_cmd dnf install -y -q $rpm >/dev/null 2>&1 || return 1
    elif command -v pacman >/dev/null 2>&1 && [ -n "$arch" ]; then
        say "installing $arch"
        # shellcheck disable=SC2086
        $sudo_cmd pacman -S --needed --noconfirm $arch >/dev/null 2>&1 || return 1
    else
        return 1
    fi

    return 0
}


# --- Which build ------------------------------------------------------------

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS:$ARCH" in
    Linux:x86_64|Linux:amd64)   ASSET="Godot_v${GODOT_VERSION}_linux.x86_64.zip"; BINARY="Godot_v${GODOT_VERSION}_linux.x86_64";  WANT="$SHA512_linux_x86_64" ;;
    Linux:aarch64|Linux:arm64)  ASSET="Godot_v${GODOT_VERSION}_linux.arm64.zip";  BINARY="Godot_v${GODOT_VERSION}_linux.arm64";   WANT="$SHA512_linux_arm64" ;;
    Darwin:*)                   ASSET="Godot_v${GODOT_VERSION}_macos.universal.zip"; BINARY="Godot.app/Contents/MacOS/Godot";     WANT="$SHA512_macos_universal" ;;
    *)
        die "No pinned Godot build for $OS $ARCH.

    Install Godot ${GODOT_VERSION%%-*} or newer yourself and pass it:
        ./setup.sh --godot /path/to/godot

    Only the builds this script has a checked-in digest for can be downloaded, and
    adding one without a digest would be the thing this script exists not to do." 3
        ;;
esac

# --- Where it lands ---------------------------------------------------------
#
# The cache, not the project: the same runtime serves every checkout on the box, and
# a `rm -rf` of one deployment does not mean downloading 100 MB again. TMC_GODOT_CACHE
# moves it; a home directory that cannot be written -- a container running as a uid
# with no passwd entry, which is a case this project already handles elsewhere --
# falls back to the project.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -n "$DEST" ]; then
    CACHE="$DEST"
else
    CACHE="${TMC_GODOT_CACHE:-${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}/tmc/godot}/$GODOT_VERSION"
    mkdir -p "$CACHE" 2>/dev/null || CACHE="$ROOT/.godot-runtime/$GODOT_VERSION"
fi
mkdir -p "$CACHE" || die "could not create $CACHE" 1

TARGET="$CACHE/godot"

# Already here and working. Checked by RUNNING it rather than by the file existing:
# a half-written download from an interrupted run is a file too.
if [ -x "$TARGET" ] && "$TARGET" --version >/dev/null 2>&1; then
    say "using the cached runtime at $TARGET"
    printf '%s\n' "$TARGET"
    exit 0
fi

# --- The tools this needs ---------------------------------------------------

if   command -v curl    >/dev/null 2>&1; then FETCH=curl
elif command -v wget    >/dev/null 2>&1; then FETCH=wget
else die "need curl or wget to download a runtime (or install Godot yourself and use --godot)" 3
fi

if   command -v sha512sum >/dev/null 2>&1; then SHA="sha512sum"
elif command -v shasum    >/dev/null 2>&1; then SHA="shasum -a 512"
elif command -v openssl   >/dev/null 2>&1; then SHA="openssl-512"
else die "need sha512sum, shasum or openssl to verify the download.

    This script will not install a binary it cannot check." 3
fi

if   command -v unzip   >/dev/null 2>&1; then UNZIP=unzip
elif command -v python3  >/dev/null 2>&1; then UNZIP=python3
else die "need unzip or python3 to unpack the download" 3
fi

# --- Download ---------------------------------------------------------------

# --- Staged BESIDE the destination, not in /tmp -----------------------------
#
# [b]A container's /tmp is not the machine's /tmp.[/b] Pterodactyl's wings mounts one as a
# tmpfs sized by `docker.tmpfs_size` -- 100 MiB by default -- and this downloads a 70 MB
# archive and unpacks a 130 MB binary out of it. So the extraction ran out of room on a
# host with 201 GB free, and `unzip` does not fail when a write fails: it asks.
#
#     write error (disk full?).  Continue? (y/n/^C)
#
# on a terminal nobody is watching, in an install container, which is a panel stuck on
# "installing" for ever and a log file that does not exist yet.
#
# The cache is the right filesystem for this on every machine, not only that one: it is
# where the binary is going, it was just created and is therefore known writable, and
# staging there makes the last step a rename within one filesystem instead of a copy
# across two. TMPDIR is still honoured when it is set, because an operator who points it
# somewhere has a reason.
TMP="$(mktemp -d "${TMPDIR:-$CACHE}/godot-fetch.XXXXXX")" \
    || die "could not make a temporary directory in ${TMPDIR:-$CACHE}" 1
trap 'rm -rf "$TMP"' EXIT

# And say so BEFORE downloading, rather than half way through unpacking. `df -Pk` is the
# portable spelling; a df that cannot answer is not a reason to refuse to try.
AVAIL_KB="$(df -Pk "$TMP" 2>/dev/null | awk 'NR==2 {print $4}')"

if [ -n "${AVAIL_KB:-}" ] && [ "$AVAIL_KB" -lt 409600 ] 2>/dev/null; then
    die "only $((AVAIL_KB / 1024)) MB free on the filesystem holding $TMP.

    The runtime needs about 400 MB to download and unpack. If this is a container,
    that is very likely a small tmpfs rather than the machine's disk -- wings sizes
    /tmp with docker.tmpfs_size, 100 MiB by default. Set TMC_GODOT_CACHE, or TMPDIR,
    to somewhere on the real volume." 1
fi

say "downloading $ASSET"
say "from $BASE_URL"

case "$FETCH" in
    curl) curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$TMP/$ASSET" "$BASE_URL/$ASSET" 2>"$TMP/fetch.err" ;;
    wget) wget -q --tries=3 --timeout=20 -O "$TMP/$ASSET" "$BASE_URL/$ASSET" 2>"$TMP/fetch.err" ;;
esac

if [ $? -ne 0 ] || [ ! -s "$TMP/$ASSET" ]; then
    die "could not download $BASE_URL/$ASSET

    $(head -3 "$TMP/fetch.err" 2>/dev/null)

    No network, or a proxy in the way. Download it by hand on a machine that has
    one, and point at the unpacked binary:
        ./setup.sh --godot /path/to/godot" 3
fi

# --- Verify -----------------------------------------------------------------
#
# Before anything is unpacked, let alone executed. A zip is parsed by a C library
# and a malicious one is a bug in that library away from being a problem, so the
# digest gates the unpack too, not just the install.

case "$SHA" in
    openssl-512) GOT="$(openssl dgst -sha512 "$TMP/$ASSET" 2>/dev/null | awk '{print $NF}')" ;;
    *)           GOT="$($SHA "$TMP/$ASSET" 2>/dev/null | awk '{print $1}')" ;;
esac

if [ -z "$GOT" ]; then
    die "could not compute a digest of the download" 3
fi

if [ "$GOT" != "$WANT" ]; then
    rm -f "$TMP/$ASSET"
    die "CHECKSUM MISMATCH on $ASSET -- the file has been deleted.

    expected  $WANT
    got       $GOT

    This is either a corrupted download, or a file that is not the one this script
    was pinned to. Re-run once; if it happens again, do NOT work around it. Install
    Godot yourself from a source you trust and pass it with --godot." 4
fi

say "sha512 verified"

# --- Unpack -----------------------------------------------------------------

case "$UNZIP" in
    # `< /dev/null` is not decoration. unzip answers a write error with an interactive
    # "Continue? (y/n/^C)" rather than an exit code, so with a terminal attached it hangs
    # instead of failing. Closed stdin turns that back into the error it should have been.
    unzip)   unzip -q -o "$TMP/$ASSET" -d "$TMP/x" < /dev/null \
                 || die "could not unpack $ASSET (out of space in $TMP?)" 3 ;;
    python3) python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
                 "$TMP/$ASSET" "$TMP/x" || die "could not unpack $ASSET" 3 ;;
esac

[ -f "$TMP/x/$BINARY" ] || die "the archive did not contain $BINARY.

    The pin and the layout of the release disagree, which means the version above
    was changed without changing the binary name beside it." 4

chmod +x "$TMP/x/$BINARY"

# Moved into place last, and through a temporary name in the SAME directory so the
# rename is atomic: two setup.sh runs at once, or one interrupted, must never leave a
# half-copied file at a path the next run will trust because it is executable.
mv -f "$TMP/x/$BINARY" "$TARGET.partial" || die "could not write $TARGET.partial" 1
mv -f "$TARGET.partial" "$TARGET"        || die "could not write $TARGET" 1

# --- Prove it runs ----------------------------------------------------------
#
# An unpacked binary is not a working one. The Linux build links fontconfig at load
# time even though headless draws nothing, so on a minimal server it dies with
# "libfontconfig.so.1: cannot open shared object file" before a line of GDScript
# runs -- found by running the container, and the same hole is in every fresh VM.

if ! VERSION="$("$TARGET" --version 2>"$TMP/run.err" | head -1)" || [ -z "$VERSION" ]; then
    MISSING="$(sed -n 's/.*error while loading shared libraries: \([^:]*\).*/\1/p' "$TMP/run.err" | head -1)"
    if [ -n "$MISSING" ]; then
        case "$MISSING" in
            libfontconfig*) PKG_DEB="libfontconfig1";  PKG_RPM="fontconfig";      PKG_ARCH="fontconfig" ;;
            libX11*|libXcursor*|libXinerama*|libXrandr*|libXi*)
                            PKG_DEB="libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6"
                            PKG_RPM="libX11 libXcursor libXinerama libXrandr libXi"
                            PKG_ARCH="libx11 libxcursor libxinerama libxrandr libxi" ;;
            libGL*)         PKG_DEB="libgl1";          PKG_RPM="mesa-libGL";      PKG_ARCH="mesa" ;;
            libasound*)     PKG_DEB="libasound2";      PKG_RPM="alsa-lib";        PKG_ARCH="alsa-lib" ;;
            libpulse*)      PKG_DEB="libpulse0";       PKG_RPM="pulseaudio-libs"; PKG_ARCH="libpulse" ;;
            *)              PKG_DEB=""; PKG_RPM=""; PKG_ARCH="" ;;
        esac

        # [b]Install it, when this machine can do that without asking anybody.[/b] The
        # point of this script is that one command gets you a working runtime, and
        # "now go and run one more command as root" is the same dead end the download
        # used to be.
        #
        # Root, or passwordless sudo, and nothing else. `sudo` WITHOUT `-n` would sit
        # there waiting for a password in the middle of a setup script -- on a box with
        # no terminal attached that is a hang, not a prompt.
        if [ -n "$PKG_DEB" ] && install_package "$PKG_DEB" "$PKG_RPM" "$PKG_ARCH"; then
            if "$TARGET" --version >/dev/null 2>&1; then
                VERSION="$("$TARGET" --version 2>/dev/null | head -1)"
                say "installed the missing $MISSING"
                say "installed $VERSION at $TARGET"
                printf '%s\n' "$TARGET"
                exit 0
            fi
        fi

        HINT="    Install the library it is missing."
        [ -n "$PKG_DEB" ] && HINT="    Debian/Ubuntu:  sudo apt-get install -y $PKG_DEB
    Fedora/RHEL:    sudo dnf install -y $PKG_RPM
    Arch:           sudo pacman -S --needed $PKG_ARCH"

        die "the runtime downloaded and verified, but will not start: $MISSING is missing.

$HINT

    Godot links this even with --headless, which draws nothing -- so a minimal
    server image hits it before any of this project's code runs. Install it and
    re-run setup.sh; the download is cached and will not happen again." 5
    fi

    die "the runtime downloaded and verified, but --version failed:

    $(head -3 "$TMP/run.err" 2>/dev/null)" 5
fi

say "installed $VERSION at $TARGET"
printf '%s\n' "$TARGET"

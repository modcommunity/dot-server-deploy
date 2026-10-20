#!/usr/bin/env bash
#
# The fingerprint of everything the web shell is exported from, and the record of it
# that sits beside web/shell-build.
#
#   tools/shell-inputs.sh print      the fingerprint of this working tree
#   tools/shell-inputs.sh write      write it to web/shell-build.inputs
#   tools/shell-inputs.sh check      exit 0 when web/shell-build.inputs matches this tree,
#                                    1 when it does not, 2 when there is no record
#   tools/shell-inputs.sh compare F  exit 0 when record F (a build's shell-inputs.txt)
#                                    matches this tree, 1 when it does not
#   tools/shell-inputs.sh paths      the files the fingerprint covers, one per line
#
# WHY
#
# Game packs carry no addons: a game runs on the addon code compiled into the shell, and
# a pack that needs a newer addon API level than the shell has is refused at Play. So a
# release whose addons.lock moved and whose web/shell-build still names the previous
# shell is a release no new game can be played on. On 2026-10-20 a dot-combat API bump
# was locked and released while the live shell predated it, and every game built on it
# was refused until a shell was exported and pinned by hand.
#
# The fingerprint is written into every export (`./server export-web` puts it in the
# build as shell-inputs.txt), copied into web/shell-build.inputs when that build is
# pinned, and checked by the release workflow, by the web-shell workflow (which exports
# and pins when it does not match), by `./server`'s auto-update (which does not adopt a
# lock whose shell is not pinned yet), and by dot-ci's server-compat check (which skips
# a release whose recorded lock is not the lock it ships). Two lines:
#
#   lock    sha256 of addons.lock alone, so a check that can fetch one file
#           (raw.githubusercontent) can compare it without a checkout
#   inputs  sha256 over every input below, which is what decides "a new shell is needed"
#
# WHAT IS AN INPUT: the files releases.md "What needs a new shell" lists that live in
# this repository -- the lock (which names every addon's ref), the shell's own client/
# code, project.godot, the tracked presets, the page the engine runs in and the loader
# template export-web stamps into the build (web/tmc-loader.js) -- plus the
# engine version. Tracked files only, as they are in the working tree: an export is made
# from the working tree, and client/auth.json and export_presets.cfg are a deployment's
# own answers, untracked on purpose. tools/server.in is not an input although its
# export-web stage writes into the build: it is the whole launcher, and a rebuilt shell
# for every launcher edit would be a new release per typo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD="$ROOT/web/shell-build.inputs"

# Paths (git pathspecs) whose tracked files are inputs. Keep in step with the
# web-shell workflow's `paths:` filter, which is a copy (a workflow cannot run a script
# to decide whether it triggers); tools/check_lists.sh is not taught it because the
# filter only decides when to look, and the job itself always compares this.
INPUT_PATHS=(addons.lock client project.godot export_presets.example.cfg web/embed.html web/tmc-loader.js)

die() { printf 'shell-inputs: %s\n' "$*" >&2; exit 3; }

sha() { sha256sum | cut -d' ' -f1; }

paths() {
    git -C "$ROOT" ls-files -- "${INPUT_PATHS[@]}" | LC_ALL=C sort
}

engine() {
    grep -oE '^GODOT_VERSION="[^"]+"' "$ROOT/tools/fetch-godot.sh" | head -1
}

fingerprint() {
    local lock list
    [ -f "$ROOT/addons.lock" ] || die "no addons.lock in $ROOT"
    git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout"
    lock="$(sha < "$ROOT/addons.lock")"
    list="$(paths)"
    [ -n "$list" ] || die "no tracked inputs found"
    # One line per input: "<sha256>  <path>", then the engine pin; hashed together.
    inputs="$(
        cd "$ROOT"
        while IFS= read -r f; do
            # A tracked file deleted in the working tree is not exported either.
            [ -f "$f" ] && printf '%s  %s\n' "$(sha < "$f")" "$f"
        done <<< "$list"
        printf 'engine  %s\n' "$(engine)"
    )"
    printf 'lock\t%s\ninputs\t%s\n' "$lock" "$(printf '%s\n' "$inputs" | sha)"
}

# The two values out of a record, ignoring comments and anything else it carries.
values() {
    grep -E '^(lock|inputs)	' "$1" | LC_ALL=C sort
}

compare() {
    local record="$1" want
    [ -f "$record" ] || return 2
    want="$(fingerprint | LC_ALL=C sort)"
    if [ "$(values "$record")" = "$want" ]; then
        return 0
    fi
    printf 'recorded (%s):\n%s\nthis tree:\n%s\n' "$record" "$(values "$record")" "$want" >&2
    return 1
}

case "${1:-}" in
    print) fingerprint ;;
    paths) paths; printf '(engine) %s\n' "$(engine)" ;;
    write)
        {
            printf '# The fingerprint of the tree the shell in web/shell-build was exported from.\n'
            printf '# Written by tools/shell-inputs.sh when the build is pinned; do not edit.\n'
            fingerprint
        } > "$RECORD"
        ;;
    check)
        rc=0; compare "$RECORD" || rc=$?
        [ "$rc" = 2 ] && printf 'shell-inputs: no %s yet\n' "${RECORD#"$ROOT"/}" >&2
        exit "$rc"
        ;;
    compare)
        [ -n "${2:-}" ] || die "compare needs a record file"
        [ -f "$2" ] || die "no such record: $2"
        compare "$2"
        ;;
    *)
        sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac

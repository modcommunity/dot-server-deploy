#!/usr/bin/env bash
# Builds addons/ from the exact tags in addons.lock (git archive of each sibling repo), so a
# suite can run against what servers install, not the working trees check.sh links.
#   tools/check-pinned.sh [DIR]   DIR defaults to ./addons; existing links are replaced
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIB="${TMC_SIBLINGS:-$ROOT/..}"
OUT="${1:-$ROOT/addons}"
mkdir -p "$OUT"
bad=0
while IFS=$'\t' read -r repo tag; do
    case "$repo" in ''|\#*) continue ;; esac
    [ -d "$SIB/$repo/.git" ] || { echo "missing sibling $repo" >&2; bad=1; continue; }
    git -C "$SIB/$repo" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null \
        || { echo "no tag $tag in $repo" >&2; bad=1; continue; }
    # The repo's own addon only (zee-dot-weapons -> zee_weapons); some carry nested copies.
    d="$(echo "$repo" | tr - _ | sed 's/_dot//')"
    rm -rf "$OUT/$d"
    git -C "$SIB/$repo" archive "$tag" "addons/$d" | tar -x -C "$OUT" --strip-components=1 \
        || { echo "no addons/$d at $tag in $repo" >&2; bad=1; }
done < "$ROOT/addons.lock"
exit $bad

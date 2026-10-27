#!/usr/bin/env bash
# Makes data/content.json exist and trust extra PUBLIC keys, in plain shell (the runtime image has no python3).
#   tools/content_trust.sh [PROJECT_DIR]
# Base: client/content.json when data/content.json is missing. Extra keys: every keys/trusted/*.pub and the file named by
# $TMC_TRUSTED_KEYS_FILE (one PEM, or a directory of .pub files). The key id is the file name without .pub. A key that is
# not a PUBLIC KEY PEM is refused and never printed. The key itself is never an env value: trusted_keys is refused from env.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DST="$ROOT/data/content.json"
mkdir -p "$ROOT/data"
if [ ! -f "$DST" ]; then
    if [ -f "$ROOT/client/content.json" ]; then cp "$ROOT/client/content.json" "$DST"
    else printf '{\n    "require_signed_manifests": true,\n    "trusted_keys": {\n    }\n}\n' > "$DST"; fi
fi
add_key() {
    local file="$1" id pem
    id="$(basename "$file")"; id="${id%.pub}"; id="${id//[^A-Za-z0-9_-]/_}"
    if [ "$(head -n1 "$file")" != "-----BEGIN PUBLIC KEY-----" ] || grep -q 'PRIVATE KEY' "$file"; then
        printf 'content_trust: %s is not a public key PEM, skipped\n' "$id" >&2; return
    fi
    pem="$(awk 'NF{printf "%s%s", sep, $0; sep="\\n"}' "$file")"
    grep -qF "\"$pem\"" "$DST" && return
    grep -q "^        \"$id\":" "$DST" && { printf 'content_trust: id %s already trusts a different key, skipped\n' "$id" >&2; return; }
    # Insert as the first entry; a trailing comma is needed only when other keys follow.
    if awk '/"trusted_keys"/{f=1;next} f&&/^        "/{found=1} f&&/^    }/{exit} END{exit !found}' "$DST"; then c=","; else c=""; fi
    ID="$id" PEM="$pem" C="$c" awk '{print} /"trusted_keys": \{/ && !d {printf "        \"%s\": \"%s\"%s\n", ENVIRON["ID"], ENVIRON["PEM"], ENVIRON["C"]; d=1}' "$DST" > "$DST.tmp" && mv "$DST.tmp" "$DST"
    printf 'content_trust: now trusting public key "%s"\n' "$id"
}
shopt -s nullglob
for f in "$ROOT"/keys/trusted/*.pub; do add_key "$f"; done
if [ -n "${TMC_TRUSTED_KEYS_FILE:-}" ]; then
    if [ -d "$TMC_TRUSTED_KEYS_FILE" ]; then for f in "$TMC_TRUSTED_KEYS_FILE"/*.pub; do add_key "$f"; done
    elif [ -f "$TMC_TRUSTED_KEYS_FILE" ]; then add_key "$TMC_TRUSTED_KEYS_FILE"
    else printf 'content_trust: TMC_TRUSTED_KEYS_FILE does not exist\n' >&2; fi
fi
exit 0

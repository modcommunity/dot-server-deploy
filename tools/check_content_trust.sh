#!/usr/bin/env bash
# tools/content_trust.sh: data/content.json appears, merges public keys from a directory or $TMC_TRUSTED_KEYS_FILE, refuses private keys, is idempotent.
#   tools/check_content_trust.sh      exit 0 when it holds
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0; n=0
chk() { n=$((n+1)); if eval "$2"; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fails=$((fails+1)); fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/client" "$T/keys/trusted" "$T/tools"
cp client/content.json "$T/client/"
openssl genrsa -out "$T/k.key" 2048 2>/dev/null && openssl rsa -in "$T/k.key" -pubout -out "$T/keys/trusted/dev.pub" 2>/dev/null
valid() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["require_signed_manifests"] is True; [d["trusted_keys"][k] for k in sys.argv[2:]]' "$T/data/content.json" "${@:2}" 2>/dev/null; }
tools/content_trust.sh "$T" > "$T/out" 2>&1
chk "content.json created with default and dev keys" 'valid x default dev'
chk "pem round-trips exactly" 'python3 -c "import json,sys; sys.exit(json.load(open(sys.argv[1]))[\"trusted_keys\"][\"dev\"].strip() != open(sys.argv[2]).read().strip())" "$T/data/content.json" "$T/keys/trusted/dev.pub"'
before="$(sha256sum < "$T/data/content.json")"
tools/content_trust.sh "$T" > "$T/out" 2>&1
chk "second run changes nothing" '[ "$before" = "$(sha256sum < "$T/data/content.json")" ]'
cp "$T/keys/trusted/dev.pub" "$T/other.pub"; openssl genrsa 2048 2>/dev/null | openssl rsa -pubout -out "$T/env1.pub" 2>/dev/null
TMC_TRUSTED_KEYS_FILE="$T/env1.pub" tools/content_trust.sh "$T" > "$T/out" 2>&1
chk "TMC_TRUSTED_KEYS_FILE adds a key" 'valid x default dev env1'
cp "$T/k.key" "$T/priv.pub"
TMC_TRUSTED_KEYS_FILE="$T/priv.pub" tools/content_trust.sh "$T" > "$T/out" 2>&1
chk "a private key is refused and not printed" '! grep -q "BEGIN" "$T/out" && grep -q "not a public key" "$T/out" && ! grep -q priv "$T/data/content.json"'
rm -rf "$T/data" "$T/client" "$T/keys/trusted/dev.pub"
tools/content_trust.sh "$T" > "$T/out" 2>&1
chk "no client file: an empty trust file, still valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$T/data/content.json"'
echo "content_trust: $((n-fails))/$n passed"
[ $fails -eq 0 ]

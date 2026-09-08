#!/usr/bin/env bash
#
# Issue a certificate from the local development CA.
#
#   ./deploy/issue-local-cert.sh example.com '*.example.com' www.example.com
#
# The first name is the CN and names the files; every name given becomes a SAN.
# The CA is the one deploy/install-game-origin.sh --local-ca creates, so a machine
# that already trusts it trusts these too, with nothing further to import.
#
# This exists because the game origin is not the only thing on a development box
# behind TLS, and the failures elsewhere are quieter. A bad certificate on the
# WebSocket the game dials produces NO prompt and NO interstitial: the handshake
# fails and the game reports that it cannot reach a server that is running.
#
# Development only. A real deployment has a real issuer.

set -uo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; OFF=$'\e[0m'
die() { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
ok()  { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

CA_CERT="${TMC_LOCAL_CA_CERT:-/opt/tmc-local-ca.crt}"
CA_KEY="${TMC_LOCAL_CA_KEY:-/opt/tmc-local-ca.key}"
OUT_DIR="${TMC_CERT_DIR:-/opt}"
OUT_NAME=""

names=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ca-cert) CA_CERT="${2:?--ca-cert needs a value}"; shift 2 ;;
        --ca-key)  CA_KEY="${2:?--ca-key needs a value}"; shift 2 ;;
        --out-dir) OUT_DIR="${2:?--out-dir needs a value}"; shift 2 ;;
        --name)    OUT_NAME="${2:?--name needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        -*)        die "unknown argument: $1" 2 ;;
        *)         names+=("$1"); shift ;;
    esac
done

[ "${#names[@]}" -gt 0 ] || die "give at least one name: ./deploy/issue-local-cert.sh example.test" 2
[ -f "$CA_CERT" ] && [ -f "$CA_KEY" ] || die "no local CA at $CA_CERT.
  Make one with: ./deploy/install-game-origin.sh --local-ca --domain <game domain>"

CN="${names[0]}"
# The CN may be a wildcard, which is not a filename anybody wants.
BASE="${OUT_NAME:-$(printf '%s' "$CN" | sed 's/^\*\.//')}"
CRT="$OUT_DIR/$BASE.crt"
KEY="$OUT_DIR/$BASE.key"

san=""
for n in "${names[@]}"; do
    [ -n "$san" ] && san="$san,"
    san="${san}DNS:$n"
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/ext" <<EXT
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
EXT

sudo openssl req -newkey rsa:2048 -nodes -keyout "$KEY" -out "$tmpdir/csr" \
    -subj "/CN=$CN/O=TMC Development" >/dev/null 2>&1 \
    || die "could not create a key at $KEY"

# 825 days: the ceiling Apple and Chrome enforce on server certificates. A longer
# one is silently rejected, which looks like a configuration fault rather than a
# date.
sudo openssl x509 -req -in "$tmpdir/csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$CRT" -days 825 -sha256 -extfile "$tmpdir/ext" >/dev/null 2>&1 \
    || die "could not sign a certificate for $CN"

sudo chmod 640 "$KEY"; sudo chmod 644 "$CRT"

ok "issued $CRT"
ok "        $KEY"
printf '  %snames%s  %s\n' "$BLD" "$OFF" "${names[*]}"
printf '  %sissuer%s %s\n\n' "$BLD" "$OFF" "$(openssl x509 -in "$CA_CERT" -noout -subject | sed 's/^subject=//')"

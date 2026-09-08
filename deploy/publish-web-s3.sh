#!/usr/bin/env bash
#
# Publish web/build to an S3 bucket, as the game content origin.
#
#   ./deploy/publish-web-s3.sh --bucket my-games --region us-east-1
#   ./deploy/publish-web-s3.sh --bucket my-games --prefix game/ --public-base https://games.example.net/game/
#
# The alternative to `install-game-origin.sh`, which puts nginx in front of a
# directory on this box. A bucket behind a CDN is the better shape for anything
# real: the engine is tens of megabytes of static bytes, it never changes between
# exports, and serving it from the machine that also runs the game servers spends
# their bandwidth on downloads.
#
# WHAT IT DOES THAT `aws s3 sync` DOES NOT DO FOR YOU
#
#   * Sets a real Content-Type per extension. `.wasm` must be `application/wasm`
#     or `WebAssembly.instantiateStreaming` refuses the response and the game
#     never starts; `.pck` is unknown to every tool and has to be named. S3
#     stores whatever you tell it and infers nothing.
#   * Optionally pre-compresses (`--gzip`). S3 does not compress on the fly, and
#     an uncompressed Godot `.wasm` is several times the size it needs to be. A
#     CDN in front can do this instead -- pick one, not both.
#   * Warns when the loader's baked engine base does not match where you are
#     publishing, which is the mistake that produces a game that loads the
#     PREVIOUS deployment and no error anywhere.
#
# WHAT A BUCKET CANNOT DO, AND YOU HAVE TO PUT SOMEWHERE ELSE
#
# The nginx origin sends a Content-Security-Policy -- including `frame-ancestors`,
# which is the only thing stopping any site on the internet embedding your player
# and dressing it up as their own -- plus `Cross-Origin-Resource-Policy`. S3 has
# no way to send those. On CloudFront they belong in a Response Headers Policy;
# on another CDN, whatever it calls the same thing. This script prints the set it
# would have sent so they can be copied.
#
# It also cannot make the objects READABLE. A fresh bucket blocks public access,
# and every file here 403s until either a bucket policy grants `s3:GetObject` on
# the prefix or a CloudFront distribution reads it through an Origin Access
# Control. Uploading works long before reading does, which makes this the failure
# that looks like a broken export: the publish says ok and the browser gets 403
# for `index.wasm`.
#
# COOP/COEP are NOT in that list, deliberately: they are only needed by an export
# built with thread support, and this project's preset has it off. Turn threads on
# and you need them, and then a bare bucket is no longer enough on its own.
#
# CREDENTIALS come from the environment, never from an argument -- an argument is
# in the shell history and in `ps`:
#
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  (+ AWS_SESSION_TOKEN if temporary)
#   S3_ACCESS_KEY / S3_ACCESS_SECRET           (the website's own names, accepted
#                                               so one .env can drive both)
#
# It signs its own requests (SigV4, curl + openssl) rather than requiring the AWS
# CLI, for the reason the rest of this project has no dependencies: a game server
# is a box with curl on it, and "install a Python toolchain first" is how a deploy
# step stops being run. `--use-cli` opts into `aws s3api` where it is installed
# and preferred.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLD=$'\e[1m'; OFF=$'\e[0m'
die()  { printf '\n  %s%s%s\n\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %s!!%s   %s\n' "$YLW" "$OFF" "$1" >&2; }

BUCKET="${TMC_S3_BUCKET:-}"
REGION="${TMC_S3_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PREFIX="${TMC_S3_PREFIX:-game/}"
ENDPOINT="${TMC_S3_ENDPOINT:-}"
PUBLIC_BASE="${TMC_S3_PUBLIC_BASE:-}"
CACHE_CONTROL="${TMC_S3_CACHE_CONTROL:-no-store}"
SOURCE="$ROOT/web/build"
GZIP=""
USE_CLI=""
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --bucket)      BUCKET="${2:?--bucket needs a value}"; shift 2 ;;
        --region)      REGION="${2:?--region needs a value}"; shift 2 ;;
        --prefix)      PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --endpoint)    ENDPOINT="${2:?--endpoint needs a value}"; shift 2 ;;
        --public-base) PUBLIC_BASE="${2:?--public-base needs a value}"; shift 2 ;;
        --cache)       CACHE_CONTROL="${2:?--cache needs a value}"; shift 2 ;;
        --source)      SOURCE="${2:?--source needs a value}"; shift 2 ;;
        --gzip)        GZIP=1; shift ;;
        --use-cli)     USE_CLI=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     sed -n '2,52p' "$0"; exit 0 ;;
        *)             die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$BUCKET" ] || die "--bucket is the S3 bucket to publish into" 2
[ -d "$SOURCE" ] || die "no export at $SOURCE -- run ./server export-web first"
[ -f "$SOURCE/index.html" ] || die "$SOURCE has no index.html; is it an export?"

# A prefix is a directory, so it ends in a slash and never starts with one.
PREFIX="${PREFIX#/}"
case "$PREFIX" in ""|*/) ;; *) PREFIX="$PREFIX/" ;; esac

ACCESS_KEY="${AWS_ACCESS_KEY_ID:-${S3_ACCESS_KEY:-}}"
SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-${S3_ACCESS_SECRET:-}}"
SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

[ -n "$ACCESS_KEY" ] || die "no credentials: set AWS_ACCESS_KEY_ID or S3_ACCESS_KEY" 2
[ -n "$SECRET_KEY" ] || die "no credentials: set AWS_SECRET_ACCESS_KEY or S3_ACCESS_SECRET" 2

command -v curl >/dev/null    || die "curl is required"
command -v openssl >/dev/null || die "openssl is required"

if [ -n "$ENDPOINT" ]; then
    HOST="${ENDPOINT#*://}"; HOST="${HOST%%/*}"
    SCHEME="${ENDPOINT%%://*}"
    # Path style, because an S3-compatible endpoint (MinIO, a local test rig) is
    # usually one host serving every bucket rather than a bucket per hostname.
    URL_BASE="$SCHEME://$HOST/$BUCKET"
else
    HOST="$BUCKET.s3.$REGION.amazonaws.com"
    SCHEME="https"
    URL_BASE="https://$HOST"
fi

# Where a browser will fetch this from. Defaults to the bucket's own URL, which
# is right for a bare-bucket deployment and wrong the moment a CDN is in front --
# hence the flag.
[ -n "$PUBLIC_BASE" ] || PUBLIC_BASE="$URL_BASE/$PREFIX"
case "$PUBLIC_BASE" in */) ;; *) PUBLIC_BASE="$PUBLIC_BASE/" ;; esac

# --------------------------------------------------------------- content types
#
# The two that matter are `.wasm` and `.pck`; the rest are here so nothing lands
# as the default and gets sniffed (or refused -- `nosniff` is set by every CDN
# worth using).
content_type_for() {
    case "$1" in
        *.html)  printf 'text/html; charset=utf-8' ;;
        *.js)    printf 'text/javascript; charset=utf-8' ;;
        *.json)  printf 'application/json; charset=utf-8' ;;
        *.wasm)  printf 'application/wasm' ;;
        *.png)   printf 'image/png' ;;
        *.jpg|*.jpeg) printf 'image/jpeg' ;;
        *.svg)   printf 'image/svg+xml' ;;
        *.ico)   printf 'image/x-icon' ;;
        *.css)   printf 'text/css; charset=utf-8' ;;
        *.wav)   printf 'audio/wav' ;;
        *.ogg)   printf 'audio/ogg' ;;
        # `.pck` and anything else. Octet-stream is correct for a pack: it is
        # bytes the engine reads, and nothing should try to render it.
        *)       printf 'application/octet-stream' ;;
    esac
}

# Worth compressing, and worth NOT compressing. A `.png` and a `.pck` are already
# compressed, and gzipping them spends CPU to make them slightly bigger.
compressible() {
    case "$1" in
        *.wasm|*.js|*.html|*.json|*.css|*.svg) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------- signing
#
# SigV4, the smallest correct version of it: one PUT, one region, no chunking.
# Every value that goes into the string-to-sign is one the request actually
# carries -- a signature over headers you did not send is the single hardest
# thing to debug here, because S3 answers it with the same 403 as a wrong key.
hmac_hex() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -hex | sed 's/^.*= //'; }
hmac_key()  { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "key:$1" -hex | sed 's/^.*= //'; }
sha256_file() { openssl dgst -sha256 -hex "$1" | sed 's/^.*= //'; }
sha256_str()  { printf '%s' "$1" | openssl dgst -sha256 -hex | sed 's/^.*= //'; }

uri_encode_path() {
    # Only the characters an export actually produces need escaping, and a path
    # is encoded segment by segment -- the slashes stay slashes or the canonical
    # request does not match what S3 built from the URL.
    printf '%s' "$1" | sed -e 's/ /%20/g'
}

put_object() {
    local file="$1" key="$2" ctype="$3" encoding="$4"

    local amzdate datestamp payload_hash canonical_uri
    amzdate="$(date -u +%Y%m%dT%H%M%SZ)"
    datestamp="${amzdate%%T*}"
    payload_hash="$(sha256_file "$file")"

    if [ -n "$ENDPOINT" ]; then
        canonical_uri="/$BUCKET/$(uri_encode_path "$key")"
    else
        canonical_uri="/$(uri_encode_path "$key")"
    fi

    # Signed headers, in the order SigV4 requires: lower-cased and sorted.
    local canonical_headers signed_headers
    canonical_headers="cache-control:$CACHE_CONTROL
content-type:$ctype
host:$HOST
x-amz-content-sha256:$payload_hash
x-amz-date:$amzdate
"
    signed_headers="cache-control;content-type;host;x-amz-content-sha256;x-amz-date"

    if [ -n "$encoding" ]; then
        canonical_headers="cache-control:$CACHE_CONTROL
content-encoding:$encoding
content-type:$ctype
host:$HOST
x-amz-content-sha256:$payload_hash
x-amz-date:$amzdate
"
        signed_headers="cache-control;content-encoding;content-type;host;x-amz-content-sha256;x-amz-date"
    fi

    if [ -n "$SESSION_TOKEN" ]; then
        canonical_headers="$canonical_headers"$'x-amz-security-token:'"$SESSION_TOKEN"$'\n'
        signed_headers="$signed_headers;x-amz-security-token"
    fi

    local canonical_request creq_hash scope string_to_sign
    canonical_request="PUT
$canonical_uri

$canonical_headers
$signed_headers
$payload_hash"

    creq_hash="$(sha256_str "$canonical_request")"
    scope="$datestamp/$REGION/s3/aws4_request"
    string_to_sign="AWS4-HMAC-SHA256
$amzdate
$scope
$creq_hash"

    local k
    k="$(hmac_key "AWS4$SECRET_KEY" "$datestamp")"
    k="$(hmac_hex "$k" "$REGION")"
    k="$(hmac_hex "$k" "s3")"
    k="$(hmac_hex "$k" "aws4_request")"
    local signature; signature="$(hmac_hex "$k" "$string_to_sign")"

    local args=(
        -sS -X PUT "$URL_BASE/$(uri_encode_path "$key")"
        --data-binary "@$file"
        -H "Host: $HOST"
        -H "Cache-Control: $CACHE_CONTROL"
        -H "Content-Type: $ctype"
        -H "x-amz-content-sha256: $payload_hash"
        -H "x-amz-date: $amzdate"
        -H "Authorization: AWS4-HMAC-SHA256 Credential=$ACCESS_KEY/$scope, SignedHeaders=$signed_headers, Signature=$signature"
        -o /dev/null -w '%{http_code}'
    )

    [ -n "$encoding" ] && args+=(-H "Content-Encoding: $encoding")
    [ -n "$SESSION_TOKEN" ] && args+=(-H "x-amz-security-token: $SESSION_TOKEN")

    curl "${args[@]}"
}

put_object_cli() {
    local file="$1" key="$2" ctype="$3" encoding="$4"
    local args=(s3api put-object --bucket "$BUCKET" --key "$key" --body "$file"
                --content-type "$ctype" --cache-control "$CACHE_CONTROL")

    [ -n "$encoding" ] && args+=(--content-encoding "$encoding")
    [ -n "$ENDPOINT" ] && args+=(--endpoint-url "$ENDPOINT")
    [ -n "$REGION" ] && args+=(--region "$REGION")

    if aws "${args[@]}" >/dev/null 2>&1; then printf '200'; else printf 'ERR'; fi
}

if [ -n "$USE_CLI" ]; then
    command -v aws >/dev/null || die "--use-cli was given but no aws CLI is installed"
fi

# ------------------------------------------------------------------ the loader
#
# The engine's location is BAKED into the loader the website serves (see
# `stamp_loader` in ./server), so publishing to a new origin without re-stamping
# gives you a loader pointing at the old one -- which loads, runs, and is the
# previous deployment. Checked rather than fixed: this script does not know
# whether the base or the bucket is the thing that is wrong.
if [ -f "$SOURCE/tmc-loader.js" ]; then
    baked="$(sed -n "s/.*var ENGINE_BASE = '\([^']*\)'.*/\1/p" "$SOURCE/tmc-loader.js" | head -1)"

    if [ -z "$baked" ] || [ "$baked" = "@ENGINE_BASE@" ]; then
        warn "tmc-loader.js has no engine base baked in; it will refuse to start"
    elif [ "$baked" != "$PUBLIC_BASE" ]; then
        warn "loader points at $baked but you are publishing to $PUBLIC_BASE"
        warn "re-stamp it: ./server stamp-loader --base $PUBLIC_BASE"
    fi
fi

printf '\n  %sPublishing%s %s\n' "$BLD" "$OFF" "$SOURCE"
printf '  bucket   %s (%s)\n' "$BUCKET" "$REGION"
printf '  prefix   %s\n' "${PREFIX:-<root>}"
printf '  public   %s\n' "$PUBLIC_BASE"
printf '  cache    %s\n\n' "$CACHE_CONTROL"

tmp=""
cleanup() { [ -n "$tmp" ] && rm -f "$tmp"; }
trap cleanup EXIT

failed=0
count=0

for file in "$SOURCE"/*; do
    [ -f "$file" ] || continue

    name="$(basename "$file")"

    # Godot writes a `.import` beside every source asset. They are editor
    # bookkeeping, they are not read at runtime, and publishing them tells
    # anybody who looks what your project tree is called.
    case "$name" in *.import) continue ;; esac

    key="$PREFIX$name"
    ctype="$(content_type_for "$name")"
    body="$file"
    encoding=""

    if [ -n "$GZIP" ] && compressible "$name"; then
        tmp="$(mktemp)"
        gzip -9 -c "$file" > "$tmp"
        body="$tmp"
        encoding="gzip"
    fi

    size="$(wc -c < "$body" | tr -d ' ')"

    if [ -n "$DRY_RUN" ]; then
        printf '  would put  %-34s %-38s %8s bytes%s\n' \
            "$key" "$ctype" "$size" "${encoding:+ (gzip)}"
        count=$((count + 1))
        [ -n "$tmp" ] && { rm -f "$tmp"; tmp=""; }
        continue
    fi

    if [ -n "$USE_CLI" ]; then
        code="$(put_object_cli "$body" "$key" "$ctype" "$encoding")"
    else
        code="$(put_object "$body" "$key" "$ctype" "$encoding")"
    fi

    [ -n "$tmp" ] && { rm -f "$tmp"; tmp=""; }

    case "$code" in
        200|201)
            ok "$(printf '%-34s %-30s %8s bytes%s' "$key" "$ctype" "$size" "${encoding:+ gzip}")"
            count=$((count + 1))
            ;;
        *)
            warn "$key failed (HTTP $code)"
            failed=$((failed + 1))
            ;;
    esac
done

printf '\n'

[ "$failed" -gt 0 ] && die "$failed file(s) failed; nothing was rolled back"

if [ -n "$DRY_RUN" ]; then
    ok "$count file(s) would be published"
    exit 0
fi

ok "$count file(s) published"

cat <<EOF

  ${BLD}The bucket cannot send these, and they are not optional:${OFF}

    Content-Security-Policy: frame-ancestors <your site origins>; default-src 'self' blob: data:;
      script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' blob:; style-src 'self' 'unsafe-inline';
      img-src 'self' data: blob:; media-src 'self' data: blob:; worker-src 'self' blob:;
      connect-src 'self' https: wss:; base-uri 'none'; form-action 'none'
    Cross-Origin-Resource-Policy: cross-origin
    X-Content-Type-Options: nosniff

  Put them in the CDN's response headers policy. \`frame-ancestors\` is the only
  thing stopping another site embedding your player as its own; without it the
  bucket is a less safe origin than the nginx one it replaced.

  ${BLD}And check the files are readable:${OFF}

    curl -sI ${PUBLIC_BASE}index.wasm

  A 403 there is not a failed upload -- writing is allowed long before reading
  is. Grant \`s3:GetObject\` on the prefix in the bucket policy, or serve it
  through CloudFront with an Origin Access Control.

  Then point the site's loader at it:

    ./server stamp-loader --base $PUBLIC_BASE

  and upload web/build/tmc-loader.js as the app's web game loader.
EOF

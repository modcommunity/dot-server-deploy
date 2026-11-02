#!/usr/bin/env bash
# Uploads an exported web shell (./server export-web --zip) to the games bucket the way
# website-city's publisher lays a build out -- game/<app url>/<build id>/, one content
# type per file, immutable cache -- and, with --pin, writes web/shell-build and its
# record, commits, tags the next v0.1.x and pushes.
#
#   tools/publish-web-shell.sh --zip web/build.zip --pin
#
# The web-shell workflow runs this on every push that changes the shell's inputs
# (docs/releases.md, "Publishing the web build"); by hand it is the fallback, and
# ~/godot/deploy-web-shell.sh on a developer box is a wrapper that passes its .env.
#
# Two upload paths. With --api SITE (SHELL_API) the files go through website-city's web
# build API (docs/web-shell-api.md): the site hands out presigned PUTs, so the games store
# can be storez and this machine holds no storage credentials, only SHELL_PUBLISH_TOKEN.
# Without it the legacy `aws s3` path runs (GAMES_S3_ACCESS_KEY, GAMES_S3_ACCESS_SECRET,
# GAMES_S3_BUCKET, GAMES_S3_REGION), which only works while the store is S3.
# Credentials come from the environment or --env FILE. Order: file < environment <
# command line. Credentials are never taken from an argument (an argument is in `ps`
# and shell history) and never printed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# --env has to be known before anything else is read, because the file it names
# supplies the defaults for everything else.
ENV_FILE=${SHELL_ENV_FILE:-}
for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = --env ]; then j=$((i + 1)); ENV_FILE=${!j:-}; fi
done
if [ -n "$ENV_FILE" ]; then
    [ -f "$ENV_FILE" ] || { echo "error: no such env file: $ENV_FILE" >&2; exit 1; }
    # The environment wins over the file: remember what was already set.
    _keep=$(export -p | grep -E '^declare -x (SHELL_|GAMES_S3_)' || true)
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
    eval "$_keep"
fi

usage() {
    cat <<'EOF'
Usage: publish-web-shell.sh --zip FILE [options]

  --zip FILE        the export-web zip                         (SHELL_ZIP, required)
  --build ID        build id; default: UTC now, YYYYMMDD-HHMM   (SHELL_BUILD)
  --app SEGMENT     the app's URL segment under game/; default: (SHELL_APP)
                    the folder holding the --like build
  --like ID         a build already in the bucket, used to find  (SHELL_LIKE, 20261014-0448)
                    the app folder when --app is not given
  --api SITE        publish through the site's web build API    (SHELL_API)
                    (https://tmcdev.net); needs SHELL_PUBLISH_TOKEN
                    in the environment or --env FILE; no S3 needed
  --env FILE        GAMES_S3_* credentials and SHELL_* defaults (SHELL_ENV_FILE)
  --bucket NAME     default: $GAMES_S3_BUCKET                   (SHELL_BUCKET)
  --region NAME     default: $GAMES_S3_REGION, else us-east-1   (SHELL_REGION)
  --origin URL      the content origin serving game/ (no        (SHELL_ORIGIN)
                    trailing game/); when given, the upload is
                    read back from it before anything is pinned
  --notes TEXT      notes column of the WebGameBuild row        (SHELL_NOTES)
  --pin             after the upload, write web/shell-build and  (SHELL_PIN=1)
                    web/shell-build.inputs in --repo, commit, tag
                    the next v0.1.x and push the branch and tag.
                    Refused unless the zip's shell-inputs.txt
                    matches --repo (it was exported from this lock)
  --no-push         with --pin: commit and tag, push nothing      (SHELL_NO_PUSH=1)
  --repo DIR        dot-server-deploy checkout for --pin         (SHELL_DEPLOY_REPO,
                                                                 this script's own)
  --wait-registered [SEC]
                    after the upload, poll read-only (default 300 s)  (SHELL_WAIT_REGISTERED)
                    until the origin serves the build and, when
                    SHELL_REGISTERED_URL names a page that lists the
                    site's current build ids, until it shows this id.
                    Exits 1 saying what is missing. Needs --origin
  --manifest-only   print the latest.json that --pin would write and exit  (needs --app)
  --dry-run         print what would be uploaded, upload nothing
  -h, --help
EOF
}

ZIP=${SHELL_ZIP:-}
BUILD=${SHELL_BUILD:-}
APP=${SHELL_APP:-}
LIKE=${SHELL_LIKE:-20261014-0448}
BUCKET=${SHELL_BUCKET:-}
REGION=${SHELL_REGION:-}
ORIGIN=${SHELL_ORIGIN:-}
API=${SHELL_API:-}
NOTES=${SHELL_NOTES:-}
PIN=${SHELL_PIN:-0}
NO_PUSH=${SHELL_NO_PUSH:-0}
REPO=${SHELL_DEPLOY_REPO:-$(cd "$HERE/.." && pwd)}
DRY=0
MANIFEST_ONLY=0
WAIT=${SHELL_WAIT_REGISTERED:-}
REGISTERED_URL=${SHELL_REGISTERED_URL:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --zip) ZIP=$2; shift 2 ;;
        --build) BUILD=$2; shift 2 ;;
        --app) APP=$2; shift 2 ;;
        --like) LIKE=$2; shift 2 ;;
        --env) shift 2 ;; # read above, before the defaults
        --bucket) BUCKET=$2; shift 2 ;;
        --region) REGION=$2; shift 2 ;;
        --origin) ORIGIN=$2; shift 2 ;;
        --api) API=$2; shift 2 ;;
        --notes) NOTES=$2; shift 2 ;;
        --pin) PIN=1; shift ;;
        --no-push) NO_PUSH=1; shift ;;
        --repo) REPO=$2; shift 2 ;;
        --wait-registered)
            if [[ ${2:-} =~ ^[0-9]+$ ]]; then WAIT=$2; shift 2; else WAIT=300; shift; fi ;;
        --dry-run) DRY=1; shift ;;
        --manifest-only) MANIFEST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

[ -n "$ZIP" ] || { usage >&2; die "--zip is required"; }
[ -f "$ZIP" ] || die "no such zip: $ZIP"
BUILD=${BUILD:-$(date -u +%Y%m%d-%H%M)}
ORIGIN=${ORIGIN%/}
API=${API%/}
if [ -n "$API" ]; then
    : "${SHELL_PUBLISH_TOKEN:?SHELL_PUBLISH_TOKEN is not set (environment or --env FILE)}"
    [ -n "$APP" ] || die "--api needs --app (the site cannot be asked which folder holds a build)"
fi

# A build id and an app segment are each one path segment; anything else would write
# outside the build's own prefix.
for v in "$BUILD" "$APP"; do
    case "$v" in */*|*..*|*" "*) die "not a single path segment: '$v'" ;; esac
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/build"
unzip -qo "$ZIP" -d "$work/build"
[ -f "$work/build/embed.html" ] && ENTRY=embed.html || ENTRY=index.html
[ -f "$work/build/$ENTRY" ] || die "the zip has no embed.html or index.html at its root"

NOTES=${NOTES:-Shell uploaded from $(basename "$ZIP")}

# The pointer the site's web-build-register job reads (game/<app>/latest.json) so a shell
# that no game server runs is still registered. "lock" is the sha256 of the record the
# build carries, so the pointer names the tree the build was exported from.
manifest_json() {
    local lock=
    [ -f "$work/build/shell-inputs.txt" ] && lock=$(sha256sum "$work/build/shell-inputs.txt" | cut -d' ' -f1)
    python3 -I -c 'import json,sys;print(json.dumps(dict(zip(("build","entry","notes","lock"),sys.argv[1:])),indent=2))' \
        "$BUILD" "$ENTRY" "$NOTES" "$lock"
}

if [ "$MANIFEST_ONLY" = 1 ]; then
    [ -n "$APP" ] || die "--manifest-only needs --app"
    manifest_json
    exit 0
fi

# Checked before a byte is uploaded, so a pin that cannot happen does not leave a
# build in the bucket that nothing points at.
if [ "$PIN" = 1 ]; then
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "--repo $REPO is not a git checkout"
    [ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
        || die "$REPO has uncommitted changes; commit or stash them first"
    BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD) || die "$REPO is on a detached HEAD"
    if [ "$NO_PUSH" = 0 ]; then
        git -C "$REPO" fetch -q --tags origin "$BRANCH" \
            || die "cannot fetch $REPO from origin, so it could not push either (GitHub credentials on this machine?)"
        git -C "$REPO" merge-base --is-ancestor HEAD "origin/$BRANCH" \
            || die "$REPO has commits origin/$BRANCH does not; push or reconcile them first"
        [ "$DRY" = 1 ] || git -C "$REPO" merge -q --ff-only "origin/$BRANCH"
    fi

    # [b]The build has to have been exported from the tree it is pinned in.[/b] The
    # merge above can move the lock under an export made before it, and that is a pin
    # naming a shell built from the previous lock: the 2026-10-20 failure, where every
    # game built on the new lock was refused at Play. export-web writes the record.
    [ -f "$work/build/shell-inputs.txt" ] \
        || die "the zip carries no shell-inputs.txt, so nothing says which lock it was exported from.
       Export it again with a current ./server (re-run ./setup.sh --no-games if ./server
       predates tools/shell-inputs.sh), then pin."
    ! grep -q '^addons	off-lock' "$work/build/shell-inputs.txt" \
        || die "this build was exported with addons that are not at addons.lock (tools/addons-lock.sh check);
       a pinned shell has to be the lock's. Check out the locked refs, export again, then pin."
    "$REPO/tools/shell-inputs.sh" compare "$work/build/shell-inputs.txt" \
        || die "this build was not exported from $REPO as it is now (above); export again, then pin"
fi

if [ -z "$API" ] && ! command -v aws >/dev/null && { [ "$DRY" = 0 ] || [ -z "$APP" ]; }; then
    echo "installing the AWS CLI (needs sudo)"
    tmp=$(mktemp -d)
    curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o "$tmp/awscli.zip"
    unzip -q "$tmp/awscli.zip" -d "$tmp"
    sudo "$tmp/aws/install" >/dev/null
    rm -rf "$tmp"
fi

if [ -z "$API" ] && { [ "$DRY" = 0 ] || [ -z "$APP" ]; }; then
    export AWS_ACCESS_KEY_ID="${GAMES_S3_ACCESS_KEY:?GAMES_S3_ACCESS_KEY is not set (environment or --env FILE)}"
    export AWS_SECRET_ACCESS_KEY="${GAMES_S3_ACCESS_SECRET:?GAMES_S3_ACCESS_SECRET is not set (environment or --env FILE)}"
    export AWS_DEFAULT_REGION="${REGION:-${GAMES_S3_REGION:-us-east-1}}"
    BUCKET=${BUCKET:-${GAMES_S3_BUCKET:?no --bucket and no GAMES_S3_BUCKET}}
fi

if [ -z "$APP" ]; then
    APP=$(aws s3 ls "s3://$BUCKET/game/" --recursive \
        | awk -v like="/$LIKE/" 'index($4, like) { split($4, p, "/"); print p[2]; exit }')
    [ -n "$APP" ] || die "no folder under game/ holds build $LIKE; pass --app"
fi

PREFIX="game/$APP/$BUILD/"
if [ "$DRY" = 0 ] && [ -z "$API" ] && aws s3 ls "s3://$BUCKET/$PREFIX" >/dev/null 2>&1; then
    die "s3://$BUCKET/$PREFIX already exists; builds are immutable, pick another --build"
fi

if [ -n "$API" ]; then echo "api     $API"; else echo "bucket  ${BUCKET:-(dry run)} (${AWS_DEFAULT_REGION:-})"; fi
echo "target  $PREFIX  entry $ENTRY"

# The same table as website-city's GameFileContentType: S3 infers nothing, and a .wasm
# that is not application/wasm never starts.
content_type() {
    case "${1,,}" in
        *.wasm) echo application/wasm ;;
        *.js|*.mjs) echo text/javascript ;;
        *.html) echo text/html ;;
        *.css) echo text/css ;;
        *.json|*.map) echo application/json ;;
        *.png) echo image/png ;;
        *.jpg|*.jpeg) echo image/jpeg ;;
        *.svg) echo image/svg+xml ;;
        *.ico) echo image/x-icon ;;
        *.wav) echo audio/wav ;;
        *.ogg) echo audio/ogg ;;
        *.txt) echo text/plain ;;
        *) echo application/octet-stream ;;
    esac
}

brotli_file() {
    if command -v brotli >/dev/null 2>&1; then brotli -q 11 -c "$1" > "$2"
    elif python3 -c 'import brotli' >/dev/null 2>&1; then
        python3 -I -c 'import brotli,sys;open(sys.argv[2],"wb").write(brotli.compress(open(sys.argv[1],"rb").read(),quality=11,lgwin=24))' "$1" "$2"
    elif command -v node >/dev/null 2>&1; then
        node -e 'const z=require("zlib"),f=require("fs");f.writeFileSync(process.argv[2],z.brotliCompressSync(f.readFileSync(process.argv[1]),{params:{[z.constants.BROTLI_PARAM_QUALITY]:11,[z.constants.BROTLI_PARAM_LGWIN]:24}}))' "$1" "$2"
    else return 1; fi
}

# The site's web build API (docs/web-shell-api.md): one JSON POST per step, the token in a
# curl config on stdin so it is never in `ps` or the shell history.
api_call() {
    local out code
    out=$(mktemp -p "$work")
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$SHELL_PUBLISH_TOKEN" \
        | curl -sS -K - -o "$out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            --data-binary @"$1" "$API/api/app/v1/web/build") || die "cannot reach $API"
    case "$code" in 2??) cat "$out" ;; *) die "web build API answered $code: $(head -c 300 "$out")" ;; esac
}

# Files to upload, one line each: key (relative to game/<app>/), local file, content type,
# content encoding (may be empty), size, sha256 of the bytes sent.
UPLIST=$work/uplist.tsv
: > "$UPLIST"
queue() { # key src type enc
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(stat -c %s "$2")" "$(sha256sum "$2" | cut -d' ' -f1)" >> "$UPLIST"
}

# Sends UPLIST through the API: begin names the files, the site answers with a presigned PUT
# for each one it does not already hold; finalize makes it check them all and, with pin, write
# the pointer. A PUT carries exactly the headers the site returned.
api_publish() {
    python3 -I - "$UPLIST" "$APP" "$BUILD" "$ENTRY" "$PIN" "$work/begin.json" <<'PY'
import json, sys
up, app, build, entry, pin, out = sys.argv[1:]
files = []
for line in open(up):
    k, _src, t, enc, size, sha = line.rstrip("\n").split("\t")
    files.append(dict(key=k, contentType=t, contentEncoding=enc or None, size=int(size), sha256=sha))
json.dump(dict(action="begin", app=app, build=build, entry=entry, files=files), open(out, "w"))
PY
    api_call "$work/begin.json" > "$work/begin.out"
    python3 -I - "$work/begin.out" "$UPLIST" "$work/puts.tsv" <<'PY'
import json, sys
res = json.load(open(sys.argv[1]))
src = {l.split("\t")[0]: l.split("\t")[1] for l in open(sys.argv[2])}
with open(sys.argv[3], "w") as o:
    for p in res.get("puts", []):
        h = "".join("\t%s: %s" % kv for kv in sorted(p.get("headers", {}).items()))
        o.write("%s\t%s\t%s%s\n" % (p["key"], src[p["key"]], p["url"], h))
print("api: %d files, %d to upload, %d already held" % (len(src), len(res.get("puts", [])), len(src) - len(res.get("puts", []))))
PY
    local key file url hdrs
    while IFS=$'\t' read -r key file url hdrs; do
        [ -n "$key" ] || continue
        # The URL carries the signature; it goes to curl through a config on stdin too.
        { printf 'url = "%s"\n' "$url"; printf '%s' "$hdrs" | tr '\t' '\n' | sed 's/.*/header = "&"/'; echo; } \
            | curl -sS -f -K - -X PUT -T "$file" -o /dev/null || die "PUT $key failed"
    done < "$work/puts.tsv"
    printf '{"action":"finalize","app":"%s","build":"%s","entry":"%s","pin":%s,"manifest":%s}' \
        "$APP" "$BUILD" "$ENTRY" "$([ "$PIN" = 1 ] && echo true || echo false)" "$(manifest_json | python3 -I -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" > "$work/fin.json"
    api_call "$work/fin.json" > "$work/fin.out"
    python3 -I -c 'import json,sys;r=json.load(open(sys.argv[1]));print("api: finalized build %s (%s)" % (r.get("build","?"), r.get("status","?")))' "$work/fin.out"
}

# [b]The engine is shared across builds[/b]: index.wasm and the worklets come from the stock
# template, so they go once under a content hash and the page points `executable` there.
# A returning player then re-downloads only the pck when a new shell is published.
ENGINE_FILES=(index.wasm index.audio.worklet.js index.audio.position.worklet.js)
engine_hash=
if [ "$ENTRY" = embed.html ] && [ "${SHELL_SHARED_ENGINE:-1}" = 1 ] && [ "${SHELL_NO_BROTLI:-0}" != 1 ] \
    && grep -q '^ *executable: "index",' "$work/build/embed.html"; then
    engine_hash=$(cd "$work/build" && cat "${ENGINE_FILES[@]}" 2>/dev/null | sha256sum | cut -c1-16)
    for e in "${ENGINE_FILES[@]}"; do [ -f "$work/build/$e" ] || engine_hash=; done
fi
if [ -n "$engine_hash" ]; then
    eng="../engine/$engine_hash/index"
    sed -i -e "s#^\( *\)executable: \"index\",#\1executable: \"$eng\", mainPack: \"index.pck\",#" \
        -e "s#\"index.wasm\":#\"$eng.wasm\":#" "$work/build/embed.html"
    echo "engine  game/$APP/engine/$engine_hash/ (shared by every build with this template)"
    if [ "$DRY" = 0 ] && [ -n "$API" ]; then
        for e in "${ENGINE_FILES[@]}"; do
            brotli_file "$work/build/$e" "$work/eng-$e" || die "cannot brotli $e"
            queue "engine/$engine_hash/$e" "$work/eng-$e" "$(content_type "$e")" br
        done
    elif [ "$DRY" = 0 ] && ! aws s3 ls "s3://$BUCKET/game/$APP/engine/$engine_hash/index.wasm" >/dev/null 2>&1; then
        for e in "${ENGINE_FILES[@]}"; do
            brotli_file "$work/build/$e" "$work/file.br" || die "cannot brotli $e"
            aws s3 cp "$work/file.br" "s3://$BUCKET/game/$APP/engine/$engine_hash/$e" --only-show-errors \
                --content-type "$(content_type "$e")" --content-encoding br \
                --cache-control "public, max-age=31536000, immutable"
            rm -f "$work/file.br"
        done
    fi
fi

count=0
while IFS= read -r -d '' f; do
    rel=${f#"$work/build"/}
    t=$(content_type "$rel")
    printf '  %-40s %s\n' "$rel" "$t"
    count=$((count + 1))
    [ "$DRY" = 1 ] && continue
    count_src=$count
    # Precompressed: S3 and the CDN in front compress nothing (CloudFront skips files over
    # 10 MB), so an unencoded index.wasm is 39.5 MB on the wire against 6.9 MB brotli.
    # Content-Type stays the real type; only Content-Encoding says it is compressed.
    enc=()
    src=$f
    case "${rel,,}" in
        *.wasm|*.js|*.mjs|*.html|*.css|*.json|*.pck)
            if [ "${SHELL_NO_BROTLI:-0}" != 1 ] && brotli_file "$f" "$work/file.br"; then
                src=$work/file.br; enc=(--content-encoding br)
            fi ;;
    esac
    if [ -n "$API" ]; then
        # Kept until api_publish has sent it, so each file is copied aside.
        ln -f "$src" "$work/q-$count_src" 2>/dev/null || cp "$src" "$work/q-$count_src"
        queue "$BUILD/$rel" "$work/q-$count_src" "$t" "${enc[1]:-}"
    else
        aws s3 cp "$src" "s3://$BUCKET/$PREFIX$rel" --only-show-errors \
            --content-type "$t" --cache-control "public, max-age=31536000, immutable" "${enc[@]}"
    fi
    rm -f "$work/file.br"
done < <(find "$work/build" -type f -print0 | sort -z)

if [ "$DRY" = 1 ]; then
    echo "dry run: $count files, nothing uploaded"
    if [ "$PIN" = 1 ]; then
        echo "would write game/$APP/latest.json (with --pin):"
        manifest_json
    fi
else
    if [ -n "$API" ]; then
        api_publish
        echo "uploaded $count files to $PREFIX through $API"
    else
        echo "uploaded $count files to s3://$BUCKET/$PREFIX"
    fi
fi

# [b]Read it back through the origin players load it from[/b], when we know it: the
# site's web-build-register job does exactly this fetch before it registers the build,
# so a build that fails here is a pin the site would never honour.
if [ "$DRY" = 0 ] && [ -n "$ORIGIN" ]; then
    url="$ORIGIN/$APP/$BUILD"
    ok=0
    for _ in 1 2 3 4 5 6; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$url/$ENTRY" || true)
        if [ "$code" = 200 ] || [ "$code" = 206 ]; then ok=1; break; fi
        sleep 10
    done
    [ "$ok" = 1 ] || die "$url/$ENTRY does not answer (last status $code); not pinning"
    if [ -n "$engine_hash" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$ORIGIN/$APP/engine/$engine_hash/index.wasm" || true)
        [ "$code" = 200 ] || [ "$code" = 206 ] || die "$ORIGIN/$APP/engine/$engine_hash/index.wasm does not answer ($code); not pinning"
    fi
    if [ -f "$work/build/shell-inputs.txt" ]; then
        if ! curl -fsS "$url/shell-inputs.txt" -o "$work/served.txt" || ! cmp -s "$work/served.txt" "$work/build/shell-inputs.txt"; then
            die "$url/shell-inputs.txt is not the record this zip carries; not pinning"
        fi
    fi
    echo "served  $url/$ENTRY"
fi

# [b]The pointer comes last and only with --pin[/b]: it is the one mutable document in an
# otherwise immutable tree, and it names the build the site should serve to solo play.
# Short cache so the job sees a new pin within a minute; no brotli, the job reads it as is.
if [ "$DRY" = 0 ] && [ "$PIN" = 1 ] && [ -n "$API" ]; then
    echo "manifest  game/$APP/latest.json -> $BUILD (written by the site on finalize)"
elif [ "$DRY" = 0 ] && [ "$PIN" = 1 ]; then
    manifest_json > "$work/latest.json"
    aws s3 cp "$work/latest.json" "s3://$BUCKET/game/$APP/latest.json" --only-show-errors \
        --content-type application/json --cache-control "public, max-age=60"
    echo "manifest  game/$APP/latest.json -> $BUILD"
fi

echo "build id: $BUILD (entry $ENTRY)"
cat <<EOT

-- Registration is automatic but not immediate: website-city's web-build-register cron job
-- (every minute) writes the WebGameBuild row once the entry answers on the content origin
-- AND either a game SERVER reports this id as sv_web_build or, with --pin, game/<app>/latest.json
-- names it (no server needed). Without --pin only a server's report registers it. Check with --wait-registered, or in Admin > Apps > Play (builds list).
-- Only if that job is off, register it by hand (website-city prod database):
INSERT INTO "WebGameBuild" (id, "appId", build, entry, status, notes, "createdAt", "updatedAt")
SELECT 'wgb' || substr(md5(random()::text), 1, 22), id, '$BUILD', '$ENTRY', 'ACTIVE',
       '${NOTES//\'/\'\'}', now(), now()
FROM "App" WHERE url = '$APP'
ON CONFLICT ("appId", build) DO NOTHING;
EOT

if [ -n "$WAIT" ] && [ "$DRY" = 1 ]; then
    echo "dry run: would wait up to ${WAIT}s for $BUILD to be registered"
    WAIT=
fi
if [ -n "$WAIT" ]; then
    [ -n "$ORIGIN" ] || die "--wait-registered needs --origin (nowhere to read the build back from)"
    echo
    echo "waiting up to ${WAIT}s for $BUILD ..."
    deadline=$((SECONDS + WAIT))
    served=no; listed=n/a
    [ -z "$REGISTERED_URL" ] || listed=no
    while :; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$ORIGIN/$APP/$BUILD/$ENTRY" || true)
        if [ "$code" = 200 ] || [ "$code" = 206 ]; then served=yes; else served="no (HTTP $code)"; fi
        if [ -n "$REGISTERED_URL" ]; then
            if curl -fsS --max-time 20 "$REGISTERED_URL" 2>/dev/null | grep -qF "$BUILD"; then listed=yes; else listed=no; fi
        fi
        if [ "$served" = yes ] && [ "$listed" != no ]; then break; fi
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 10
    done
    if [ "$served" != yes ] || [ "$listed" = no ]; then
        die "$BUILD is not live after ${WAIT}s: origin serves $ENTRY: $served; listed by ${REGISTERED_URL:-(no SHELL_REGISTERED_URL)}: $listed.
       The WebGameBuild row appears when a game server reports sv_web_build=$BUILD or (with --pin) game/$APP/latest.json names it, and the
       web-build-register job (every minute) finds the entry on the origin. Restart or update a
       server onto the pinned shell, check the job is enabled (Admin > Cron), or insert the row above."
    fi
    echo "live: origin serves $ORIGIN/$APP/$BUILD/$ENTRY; site listing: $listed"
    [ "$listed" != n/a ] || echo "-- (set SHELL_REGISTERED_URL to also confirm the site lists it; the row itself is not readable without admin)"
fi

if [ "$PIN" = 0 ] || [ "$DRY" = 1 ]; then
    echo
    echo "-- Then: --pin (writes web/shell-build and web/shell-build.inputs, commits, tags, pushes)."
    exit 0
fi

# The pin. A server reports web/shell-build as sv_web_build and the site frames that
# build for it once it has a WebGameBuild row. web/shell-build.inputs says which tree it
# was exported from; the release workflow refuses a tag where the two disagree.
echo "$BUILD" > "$REPO/web/shell-build"
"$REPO/tools/shell-inputs.sh" write
if git -C "$REPO" diff --quiet -- web/shell-build web/shell-build.inputs \
        && git -C "$REPO" ls-files --error-unmatch web/shell-build.inputs >/dev/null 2>&1; then
    echo "web/shell-build already names $BUILD; nothing to commit"
else
    git -C "$REPO" add web/shell-build web/shell-build.inputs
    git -C "$REPO" commit -q -m "Pin the web shell $BUILD" \
        -m "web/shell-build names the shell exported from addons.lock at $(git -C "$REPO" rev-parse --short HEAD), uploaded to $PREFIX."
fi
next_tag() {
    local last
    last=$(git -C "$REPO" tag -l 'v*' | sort -V | tail -1)
    last=${last:-v0.0.0}
    echo "${last%.*}.$(( ${last##*.} + 1 ))"
}
TAG=$(next_tag)
git -C "$REPO" tag -a "$TAG" -m "Web shell $BUILD"
echo
if [ "$NO_PUSH" = 1 ]; then
    echo "pinned: $REPO web/shell-build = $BUILD, tagged $TAG; nothing pushed (--no-push)"
    exit 0
fi

# [b]The branch and the tag move together or not at all.[/b] Somebody can push or tag
# while the export runs; a plain two-ref push then lands the pin without its tag, or the
# tag without the pin, and nothing would put it right. On a rejection: drop the local
# tag, take what origin has, replay the pin on it, and try again with the next free tag
# -- unless origin's new commits changed the shell's inputs, in which case this build is
# no longer the tree's, and the run that push started builds the right one.
for attempt in 1 2 3 4 5; do
    if git -C "$REPO" push -q --atomic origin "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"; then
        echo "pinned: $REPO web/shell-build = $BUILD, tagged $TAG, pushed $BRANCH and $TAG"
        echo "-- Servers on TMC_AUTO_UPDATE=when-needed move on their next start."
        exit 0
    fi
    [ "$attempt" = 5 ] && break
    echo "push rejected (attempt $attempt): origin moved; replaying the pin on it"
    git -C "$REPO" tag -d "$TAG" >/dev/null
    git -C "$REPO" fetch -q --tags origin "$BRANCH" || die "cannot fetch origin/$BRANCH"
    git -C "$REPO" rebase -q "origin/$BRANCH" \
        || { git -C "$REPO" rebase --abort 2>/dev/null; die "the pin does not replay on origin/$BRANCH; nothing pushed"; }
    "$REPO/tools/shell-inputs.sh" compare "$work/build/shell-inputs.txt" \
        || die "origin/$BRANCH changed the shell's inputs since this export; nothing pushed (the run for that push builds it). $PREFIX is uploaded and unpinned."
    TAG=$(next_tag)
    git -C "$REPO" tag -a "$TAG" -m "Web shell $BUILD"
done
die "could not push the pin and $TAG after 5 attempts; $PREFIX is uploaded and unpinned"

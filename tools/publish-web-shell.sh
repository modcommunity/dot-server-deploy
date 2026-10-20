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
# Credentials come from the environment (GAMES_S3_ACCESS_KEY, GAMES_S3_ACCESS_SECRET,
# GAMES_S3_BUCKET, GAMES_S3_REGION), or from --env FILE. Order: file < environment <
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
NOTES=${SHELL_NOTES:-}
PIN=${SHELL_PIN:-0}
NO_PUSH=${SHELL_NO_PUSH:-0}
REPO=${SHELL_DEPLOY_REPO:-$(cd "$HERE/.." && pwd)}
DRY=0

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
        --notes) NOTES=$2; shift 2 ;;
        --pin) PIN=1; shift ;;
        --no-push) NO_PUSH=1; shift ;;
        --repo) REPO=$2; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

[ -n "$ZIP" ] || { usage >&2; die "--zip is required"; }
[ -f "$ZIP" ] || die "no such zip: $ZIP"
BUILD=${BUILD:-$(date -u +%Y%m%d-%H%M)}
ORIGIN=${ORIGIN%/}

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

if ! command -v aws >/dev/null && { [ "$DRY" = 0 ] || [ -z "$APP" ]; }; then
    echo "installing the AWS CLI (needs sudo)"
    tmp=$(mktemp -d)
    curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o "$tmp/awscli.zip"
    unzip -q "$tmp/awscli.zip" -d "$tmp"
    sudo "$tmp/aws/install" >/dev/null
    rm -rf "$tmp"
fi

if [ "$DRY" = 0 ] || [ -z "$APP" ]; then
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
if [ "$DRY" = 0 ] && aws s3 ls "s3://$BUCKET/$PREFIX" >/dev/null 2>&1; then
    die "s3://$BUCKET/$PREFIX already exists; builds are immutable, pick another --build"
fi

echo "bucket  ${BUCKET:-(dry run)} (${AWS_DEFAULT_REGION:-})"
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

count=0
while IFS= read -r -d '' f; do
    rel=${f#"$work/build"/}
    t=$(content_type "$rel")
    printf '  %-40s %s\n' "$rel" "$t"
    count=$((count + 1))
    [ "$DRY" = 1 ] && continue
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
    aws s3 cp "$src" "s3://$BUCKET/$PREFIX$rel" --only-show-errors \
        --content-type "$t" --cache-control "public, max-age=31536000, immutable" "${enc[@]}"
    rm -f "$work/file.br"
done < <(find "$work/build" -type f -print0 | sort -z)

if [ "$DRY" = 1 ]; then
    echo "dry run: $count files, nothing uploaded"
else
    echo "uploaded $count files to s3://$BUCKET/$PREFIX"
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
    if [ -f "$work/build/shell-inputs.txt" ]; then
        curl -fsS "$url/shell-inputs.txt" -o "$work/served.txt" \
            && cmp -s "$work/served.txt" "$work/build/shell-inputs.txt" \
            || die "$url/shell-inputs.txt is not the record this zip carries; not pinning"
    fi
    echo "served  $url/$ENTRY"
fi

NOTES=${NOTES:-Shell uploaded from $(basename "$ZIP")}
cat <<EOF

-- The site registers this build itself (website-city's web-build-register job, every
-- minute) once a server reports it as sv_web_build and its entry answers on the origin.
-- Only if that job is off, register it by hand (website-city prod database):
INSERT INTO "WebGameBuild" (id, "appId", build, entry, status, notes, "createdAt", "updatedAt")
SELECT 'wgb' || substr(md5(random()::text), 1, 22), id, '$BUILD', '$ENTRY', 'ACTIVE',
       '${NOTES//\'/\'\'}', now(), now()
FROM "App" WHERE url = '$APP'
ON CONFLICT ("appId", build) DO NOTHING;
EOF

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

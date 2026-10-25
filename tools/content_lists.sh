# The download lists, read from bash: cfg/content/addons.yml and cfg/content/games.yml.
#
#   . tools/content_lists.sh
#   content_list games [CONFIG_DIR]      TSV: kind  id  pin  content  layer  (one entry per line)
#   content_game_entries [CONFIG_DIR]    repo:content directory, the shape games.list gave
#   content_addon_repos [CONFIG_DIR]     addon repository names, list order
#
# SOURCED. The schema and the GDScript reader are host/tmc_content_lists.gd and
# docs/content-lists.md; this is the same layering for setup.sh, check.sh and the check
# scripts, which have no engine. It reads the subset every shipped file and the docs use
# (shorthand `name@pin`, `repo:`/`pack:`/`pin:`/`content:` mappings, flow or block `remove:`);
# `maps:` and `rotation:` on a games entry are read by the server, not here.
#
# Layers, weakest first: content-lists/<file> (shipped), <cfg>/content/<file>, <cfg>/server/content/<file>.
# A file without `merge: true` replaces everything below it.
#
# LEGACY: a games.list at the project root (the format before these files) is read only when
# the operator has no cfg/content/games.yml, until 2026-12-31 (content_legacy_notice prints
# the one WARN); after that it is ignored with an ERROR. See docs/content-lists.md.

CL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CL_LEGACY_UNTIL="2026-12-31"

content_list() {
    local kind="$1" cfg="${2:-${CONFIG_DIR:-$CL_ROOT/cfg}}" file="$1.yml" f files=()
    case "$kind" in addons|games) ;; *) echo "content_lists: unknown list '$kind'" >&2; return 2 ;; esac
    for f in "$CL_ROOT/content-lists/$file" "$cfg/content/$file" "$cfg/server/content/$file"; do
        [ -f "$f" ] && files+=("$f")
    done
    if [ "$kind" = games ] && _cl_legacy_active "$cfg"; then
        awk '!/^[[:space:]]*(#|$)/ { printf "repo\t%s\t\t%s\tlegacy\n", $1, $2 }' "$CL_ROOT/games.list"
        return 0
    fi
    [ ${#files[@]} -gt 0 ] || { echo "content_lists: no $file found" >&2; return 1; }
    awk -v root="$CL_ROOT/content-lists/" -v kind="$kind" '
    function fail(msg) { printf "content_lists: %s: %s\n", FILENAME, msg > "/dev/stderr"; bad = 1; exit 1 }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); gsub(/^["\047]|["\047]$/, "", s); return s }
    function flush(   id, p, at) {
        if (!have) return
        have = 0
        if ((repo == "") == (pack == "")) fail("entry " (nent + 1) ": give exactly one of repo and pack")
        if (repo ~ /\//) fail("entry " (nent + 1) ": repo \047" repo "\047 has a slash; use pack: for an owner/pack id")
        id = (repo != "") ? repo : pack
        if (id !~ /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)?$/ || id ~ /\.\./) fail("entry " (nent + 1) ": \047" id "\047 is not a repository name or an owner/pack id")
        if (pin ~ /[^A-Za-z0-9._+-]/) fail("entry " (nent + 1) ": \047" pin "\047 is not a version, tag or commit")
        nent++
        dk[nd, nent] = (repo != "") ? "repo" : "pack"; di[nd, nent] = id; dp[nd, nent] = pin; dc[nd, nent] = content
        dn[nd] = nent
    }
    function addbare(rest) {
        flush(); have = 1; repo = ""; pack = ""; pin = ""; content = ""
        if (index(rest, "@")) { pin = substr(rest, index(rest, "@") + 1); rest = substr(rest, 1, index(rest, "@") - 1) }
        if (rest ~ /\//) pack = rest; else repo = rest
    }
    function setkey(k, v) {
        v = trim(v)
        if ((k == "repo" || k == "pack") && index(v, "@")) { pin = substr(v, index(v, "@") + 1); v = substr(v, 1, index(v, "@") - 1) }
        if (k == "repo") repo = v
        else if (k == "pack") pack = v
        else if (k == "pin") pin = v
        else if (k == "content") content = v
    }
    FNR == 1 {
        flush(); nd++; nent = 0; mode = ""; edash = -1; dm[nd] = 0; dh[nd] = 0
        dl[nd] = (index(FILENAME, root) == 1) ? "default" : "operator"
        dr[nd] = ""
    }
    { line = $0; sub(/(^|[[:space:]])#.*/, "", line) }
    line ~ /^[[:space:]]*$/ { next }
    match(line, /^[^[:space:]]/) {
        flush(); mode = ""
        if (line ~ /^merge:[[:space:]]*true/) dm[nd] = 1
        else if (line ~ /^remove:/) {
            dh[nd] = 1
            v = line; sub(/^remove:[[:space:]]*/, "", v)
            if (v ~ /^\[/) { gsub(/[\[\]]/, "", v); n = split(v, parts, ","); for (i = 1; i <= n; i++) { t = trim(parts[i]); sub(/@.*/, "", t); if (t != "") dr[nd] = dr[nd] " " t " " } }
            else mode = "remove"
        }
        else if (line ~ /^entries:/) {
            dh[nd] = 1
            v = line; sub(/^entries:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
            if (v == "") { mode = "entries"; edash = -1 }
            else if (v ~ /^\[.*\]$/) { gsub(/[\[\]]/, "", v); n = split(v, parts, ","); for (i = 1; i <= n; i++) { t = trim(parts[i]); if (t != "") addbare(t) } flush() }
            else fail("entries: must be a block list (one \"- item\" per line) or a one-line [a, b] list, not \047" v "\047")
        }
        next
    }
    mode == "remove" && line ~ /^[[:space:]]*-/ { t = line; sub(/^[[:space:]]*-[[:space:]]*/, "", t); t = trim(t); sub(/@.*/, "", t); dr[nd] = dr[nd] " " t " "; next }
    mode == "entries" {
        match(line, /^[[:space:]]*/); ind = RLENGTH
        if (line ~ /^[[:space:]]*-[[:space:]]/ && (edash < 0 || ind == edash)) {
            edash = ind; flush(); have = 1; repo = ""; pack = ""; pin = ""; content = ""
            rest = line; sub(/^[[:space:]]*-[[:space:]]+/, "", rest); rest = trim(rest)
            if (rest ~ /^(repo|pack|pin|content|maps|rotation):/) { k = rest; sub(/:.*/, "", k); setkey(k, substr(rest, length(k) + 2)) }
            else { if (index(rest, "@")) { pin = substr(rest, index(rest, "@") + 1); rest = substr(rest, 1, index(rest, "@") - 1) } if (rest ~ /\//) pack = rest; else repo = rest }
            next
        }
        if (have && line ~ /^[[:space:]]+[a-z_]+:/ && ind > edash) { k = line; sub(/^[[:space:]]+/, "", k); sub(/:.*/, "", k); v = line; sub(/^[[:space:]]+[a-z_]+:[[:space:]]*/, "", v); setkey(k, v) }
    }
    END {
        if (bad) exit 1
        flush()
        start = 1
        for (d = nd; d >= 1; d--) if (dh[d] && !dm[d]) { start = d; break }
        for (d = start; d <= nd; d++) {
            if (!dh[d]) continue
            for (j = 1; j <= n_out; j++) if (index(dr[d], " " oid[j] " ")) { odel[j] = 1 }
            for (e = 1; e <= dn[d]; e++) {
                at = 0
                for (j = 1; j <= n_out; j++) if (!odel[j] && oid[j] == di[d, e]) { at = j; break }
                if (!at) at = ++n_out
                oid[at] = di[d, e]; okind[at] = dk[d, e]; opin[at] = dp[d, e]; ocon[at] = dc[d, e]; olayer[at] = dl[d]; odel[at] = 0
            }
        }
        for (j = 1; j <= n_out; j++) if (!odel[j]) printf "%s\t%s\t%s\t%s\t%s\n", okind[j], oid[j], opin[j], ocon[j], olayer[j]
    }' "${files[@]}"
}

# True while the old games.list is the list in force: it exists, the operator has no games.yml,
# and the shim has not expired.
_cl_legacy_active() {
    local cfg="${1:-${CONFIG_DIR:-$CL_ROOT/cfg}}"
    [ -f "$CL_ROOT/games.list" ] && [ ! -f "$cfg/content/games.yml" ] && [ ! -f "$cfg/server/content/games.yml" ] \
        && ! [ "$(date +%Y-%m-%d)" \> "$CL_LEGACY_UNTIL" ]
}

## Prints the one WARN (or ERROR once expired) about a games.list. Call it once per script run.
content_legacy_notice() {
    local cfg="${1:-${CONFIG_DIR:-$CL_ROOT/cfg}}"
    [ -f "$CL_ROOT/games.list" ] && [ ! -f "$cfg/content/games.yml" ] && [ ! -f "$cfg/server/content/games.yml" ] || return 0
    if _cl_legacy_active "$cfg"; then
        echo "WARN content_lists: games.list is the old games list and is still read; move it to $cfg/content/games.yml before $CL_LEGACY_UNTIL" >&2
    else
        echo "ERROR content_lists: games.list is no longer read (removed after $CL_LEGACY_UNTIL); move it to $cfg/content/games.yml" >&2
    fi
}

content_game_entries() {
    content_list games "$@" | awk -F'\t' '$1 == "repo" { c = ($4 != "") ? $4 : $2; print $2 ":" c }'
}

content_addon_repos() {
    content_list addons "$@" | awk -F'\t' '$1 == "repo" { print $2 }'
}

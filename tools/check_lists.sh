#!/usr/bin/env bash
#
# The lists that are written down more than once agree.
#
#   tools/check_lists.sh      exit 0 when they do, 1 naming each difference
#
# cfg/content/addons.yml (shipped content-lists/addons.yml) and setup.sh's addon_repo() are the facts
# (docs/setup.md, "One fact, one place"). Another place cannot read them and so carries a copy:
#
#   - setup.ps1's $addons and Get-AddonRepo: PowerShell has never run here, so it does not
#     parse a bash array; its copy had stopped at dot_friends, nineteen names, with no
#     dot_sql or dot_menu, and nothing noticed because nothing on this machine runs it.
#
# Also: tools/addons-lock.sh and tools/package_check.sh read the same list through
# tools/content_lists.sh, so no addon can fall out of the lock and the staged tree.
#
# And cfg/content/games.yml, the list of games setup.sh publishes, against what it describes: every
# content/<dir>/pack.json is published by an entry (directly, or by a directory sharing its
# content id, as hungario's do), every line names a content directory with a pack.json,
# and every game repository beside this one (a zees-games line in dot-bootstrap's
# projects.tsv whose checkout has a game.yml) has a line. Six finished games were missing
# from the old hand-written array, which nothing could see.
#
# Arm it by deleting a name from setup.ps1's list, the zee line from Get-AddonRepo, or a
# game's line from games.yml.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

. tools/content_lists.sh
# The addon names setup.sh derives (ADDONS_ALL): repository names with underscores, in list order.
mapfile -t SH_LIST < <(content_addon_repos "$PWD/cfg" | sed 's/^zee-dot-weapons$/zee_weapons/; s/^zed-dot-weapons$/zed_weapons/; s/-/_/g')
# Every quoted name between `$addons = @(` and `)`.
mapfile -t PS_LIST < <(tr -d '\r' < setup.ps1 | sed -n '/^\$addons = @(/,/)/p' | grep -oE "'[^']+'" | tr -d "'")

if [ ${#SH_LIST[@]} -eq 0 ]; then
    bad "could not read cfg/content/addons.yml"
elif [ ${#PS_LIST[@]} -eq 0 ]; then
    bad "could not read \$addons out of setup.ps1"
elif [ "$(printf '%s\n' "${SH_LIST[@]}" | sort)" = "$(printf '%s\n' "${PS_LIST[@]}" | sort)" ]; then
    good "setup.ps1's addon list is the addons.yml list (${#SH_LIST[@]} names; order does not matter)"
else
    only_sh=$(comm -23 <(printf '%s\n' "${SH_LIST[@]}" | sort -u) <(printf '%s\n' "${PS_LIST[@]}" | sort -u) | tr '\n' ' ')
    only_ps=$(comm -13 <(printf '%s\n' "${SH_LIST[@]}" | sort -u) <(printf '%s\n' "${PS_LIST[@]}" | sort -u) | tr '\n' ' ')
    bad "setup.ps1's addon list differs from the addons.yml list (${#PS_LIST[@]} vs ${#SH_LIST[@]}); only in setup.sh: ${only_sh:-none}; only in setup.ps1: ${only_ps:-none}"
fi

# name=repo for each exception, sorted.
sh_ex=$(sed -n '/^addon_repo() {/,/^}/p' setup.sh | grep -oE "^ +[a-z0-9_]+\) +printf '[^'\\\\]+" \
    | sed -E "s/^ +([a-z0-9_]+)\) +printf '([^'\\\\]+)/\1=\2/" | sort)
ps_ex=$(tr -d '\r' < setup.ps1 | sed -n '/^function Get-AddonRepo/,/^}/p' | grep -oE "'[a-z0-9_]+' +\{ +return '[^']+'" \
    | sed -E "s/'([a-z0-9_]+)' +\{ +return '([^']+)'/\1=\2/" | sort)
if [ -z "$sh_ex" ]; then
    bad "could not read addon_repo()'s exceptions out of setup.sh"
else
    [ "$sh_ex" = "$ps_ex" ] && good "setup.ps1's Get-AddonRepo has addon_repo()'s exceptions ($(echo $sh_ex))" \
        || bad "setup.ps1's Get-AddonRepo exceptions ($(echo ${ps_ex:-none})) are not addon_repo()'s ($(echo $sh_ex))"
    for f in tools/addons-lock.sh tools/package_check.sh; do
        grep -q 'content_addon_repos' "$f" && good "$f reads the addon list from cfg/content/addons.yml" \
            || bad "$f does not read cfg/content/addons.yml (content_addon_repos)"
    done
fi

# --- games.yml --------------------------------------------------------------
# The pack id a content directory publishes: a game's game.yml content_id, else a data
# pack's pack.json id.
pack_id() {
    local d="content/$1" id=""
    [ -f "$d/game.yml" ] && id=$(sed -nE 's/^content_id:[[:space:]]*"?([^"#[:space:]]+).*/\1/p' "$d/game.yml" | head -1)
    [ -z "$id" ] && [ -f "$d/pack.json" ] && id=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$d/pack.json" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    printf '%s\n' "$id"
}

content_legacy_notice "$PWD/cfg"
if ! mapfile -t GL_ENTRIES < <(content_game_entries "$PWD/cfg") || [ ${#GL_ENTRIES[@]} -eq 0 ]; then
    bad "cfg/content/games.yml (or the shipped content-lists/games.yml) is missing or names no games"
else
    GL_REPOS=("${GL_ENTRIES[@]%%:*}")
    GL_DIRS=("${GL_ENTRIES[@]#*:}")

    listed_ids=" "; nodesc=""
    for d in "${GL_DIRS[@]}"; do
        if [ -f "content/$d/pack.json" ]; then listed_ids="$listed_ids$(pack_id "$d") "
        else nodesc="$nodesc $d"; fi
    done
    [ -z "$nodesc" ] && good "every games.yml line names a content directory with a pack.json (${#GL_DIRS[@]})" \
        || bad "games.yml names content directories with no pack.json:$nodesc"

    unlisted=""
    for f in content/*/pack.json; do
        d=$(basename "$(dirname "$f")"); id=$(pack_id "$d")
        case "$listed_ids" in *" $id "*) ;; *) unlisted="$unlisted $d(${id:-no id})" ;; esac
    done
    [ -z "$unlisted" ] && good "every content/<dir>/pack.json is published by a games.yml line" \
        || bad "content directories no games.yml line publishes:$unlisted"

    TSV=../dot-bootstrap/projects.tsv
    if [ -f "$TSV" ]; then
        missing=""; strange=""
        while IFS=$'\t' read -r repo url; do
            case "$repo" in ''|'#'*) continue ;; esac
            case "$url" in *zees-games/*) ;; *) continue ;; esac
            [ -f "../$repo/game.yml" ] || continue
            printf '%s\n' "${GL_REPOS[@]}" | grep -qxF "$repo" || missing="$missing $repo"
        done < "$TSV"
        for repo in "${GL_REPOS[@]}"; do
            grep -qE "^$repo"$'\t' "$TSV" || strange="$strange $repo"
        done
        [ -z "$missing" ] && good "every game repository in projects.tsv with a game.yml is in games.yml" \
            || bad "game repositories with a game.yml that games.yml does not name:$missing"
        [ -z "$strange" ] && good "every games.yml repository is in dot-bootstrap's projects.tsv" \
            || bad "games.yml names repositories projects.tsv does not:$strange"
    else
        echo "  --   no ../dot-bootstrap/projects.tsv: game repositories not compared"
    fi
fi

exit $((fails > 0))

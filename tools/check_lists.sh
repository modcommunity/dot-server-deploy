#!/usr/bin/env bash
#
# The lists that are written down more than once agree.
#
#   tools/check_lists.sh      exit 0 when they do, 1 naming each difference
#
# cfg/content/addons.yml (shipped: content-lists/addons.yml) and setup.sh's addon_repo() are
# the facts (docs/setup.md, "One fact, one place"). One other place cannot read them and so
# carries a copy: setup.ps1's $addons and Get-AddonRepo. PowerShell has never run here, so it
# does not parse yml; its copy had stopped at dot_friends, nineteen names, with no dot_sql or
# dot_menu, and nothing noticed because nothing on this machine runs it.
#
# And the games list (cfg/content/games.yml, shipped content-lists/games.yml) against what it
# describes: every content/<dir>/pack.json is published by a line (directly, or by a directory
# sharing its content id, as hungario's do), every line names a content directory with a
# pack.json, and every game repository beside this one (a zees-games line in dot-bootstrap's
# projects.tsv whose checkout has a game.yml) has a line. Six finished games were missing
# from the old hand-written array, which nothing could see.
#
# Arm it by deleting a name from setup.ps1's list, the zee line from Get-AddonRepo, or a
# game's entry from content-lists/games.yml.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. tools/content_lists.sh
content_legacy_notice

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

# The repository names setup.sh's addon_repo() writes out as exceptions: name=repo.
sh_ex=$(sed -n '/^addon_repo() {/,/^}/p' setup.sh | grep -oE "^ +[a-z0-9_]+\) +printf '[^'\\]+" \
    | sed -E "s/^ +([a-z0-9_]+)\) +printf '([^'\\]+)/\1=\2/" | sort)
repo_of_name() {
    local n="$1" e
    for e in $sh_ex; do [ "${e%%=*}" = "$n" ] && { printf '%s\n' "${e#*=}"; return; }; done
    printf '%s\n' "${n//_/-}"
}

mapfile -t SH_LIST < <(content_addon_repos)
# Every quoted name between `$addons = @(` and `)`, as the repository it stands for.
mapfile -t PS_LIST < <(tr -d '\r' < setup.ps1 | sed -n '/^\$addons = @(/,/)/p' | grep -oE "'[^']+'" | tr -d "'" \
    | while read -r n; do repo_of_name "$n"; done)

if [ ${#SH_LIST[@]} -eq 0 ]; then
    bad "could not read the addons list (cfg/content/addons.yml) "
elif [ ${#PS_LIST[@]} -eq 0 ]; then
    bad "could not read \$addons out of setup.ps1"
elif [ "$(printf '%s\n' "${SH_LIST[@]}" | sort)" = "$(printf '%s\n' "${PS_LIST[@]}" | sort)" ]; then
    good "setup.ps1's addon list is the addons list (${#SH_LIST[@]} repositories)"
else
    only_sh=$(comm -23 <(printf '%s\n' "${SH_LIST[@]}" | sort -u) <(printf '%s\n' "${PS_LIST[@]}" | sort -u) | tr '\n' ' ')
    only_ps=$(comm -13 <(printf '%s\n' "${SH_LIST[@]}" | sort -u) <(printf '%s\n' "${PS_LIST[@]}" | sort -u) | tr '\n' ' ')
    bad "setup.ps1's addon list differs from addons.yml (${#PS_LIST[@]} vs ${#SH_LIST[@]}); only in addons.yml: ${only_sh:-none}; only in setup.ps1: ${only_ps:-none}"
fi

ps_ex=$(tr -d '\r' < setup.ps1 | sed -n '/^function Get-AddonRepo/,/^}/p' | grep -oE "'[a-z0-9_]+' +\{ +return '[^']+'" \
    | sed -E "s/'([a-z0-9_]+)' +\{ +return '([^']+)'/\1=\2/" | sort)
if [ -z "$sh_ex" ]; then
    bad "could not read addon_repo()'s exceptions out of setup.sh"
else
    [ "$sh_ex" = "$ps_ex" ] && good "setup.ps1's Get-AddonRepo has addon_repo()'s exceptions ($(echo $sh_ex))" \
        || bad "setup.ps1's Get-AddonRepo exceptions ($(echo ${ps_ex:-none})) are not addon_repo()'s ($(echo $sh_ex))"
    for f in tools/addons-lock.sh tools/package_check.sh; do
        grep -q 'content_addon_repos' "$f" && good "$f reads the addons list (no copy of it)" \
            || bad "$f does not read the addons list through content_addon_repos"
    done
    # The reverse mapping setup.sh uses for ADDONS_ALL must agree with addon_repo().
    bad_rev=""
    for e in $sh_ex; do
        grep -q "${e#*=}) *printf '${e%%=*}" setup.sh || bad_rev="$bad_rev ${e#*=}"
    done
    [ -z "$bad_rev" ] && good "setup.sh's addon_name() inverts addon_repo()'s exceptions" \
        || bad "setup.sh's addon_name() lacks the inverse of:$bad_rev"
fi

# --- the games list (cfg/content/games.yml) -------------------------------------------------------------
# The pack id a content directory publishes: a game's game.yml content_id, else a data
# pack's pack.json id.
pack_id() {
    local d="content/$1" id=""
    [ -f "$d/game.yml" ] && id=$(sed -nE 's/^content_id:[[:space:]]*"?([^"#[:space:]]+).*/\1/p' "$d/game.yml" | head -1)
    [ -z "$id" ] && [ -f "$d/pack.json" ] && id=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$d/pack.json" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    printf '%s\n' "$id"
}

mapfile -t GL_ENTRIES < <(content_game_entries)
if [ ${#GL_ENTRIES[@]} -eq 0 ]; then
    bad "the games list (cfg/content/games.yml) is empty or unreadable"
else
    GL_REPOS=(); GL_DIRS=()
    for e in "${GL_ENTRIES[@]}"; do GL_REPOS+=("${e%%:*}"); GL_DIRS+=("${e#*:}"); done

    listed_ids=" "; nodesc=""
    for d in "${GL_DIRS[@]}"; do
        if [ -f "content/$d/pack.json" ]; then listed_ids="$listed_ids$(pack_id "$d") "
        else nodesc="$nodesc $d"; fi
    done
    [ -z "$nodesc" ] && good "every games.yml entry names a content directory with a pack.json (${#GL_DIRS[@]})" \
        || bad "the games list names content directories with no pack.json:$nodesc"

    unlisted=""
    for f in content/*/pack.json; do
        d=$(basename "$(dirname "$f")"); id=$(pack_id "$d")
        case "$listed_ids" in *" $id "*) ;; *) unlisted="$unlisted $d(${id:-no id})" ;; esac
    done
    [ -z "$unlisted" ] && good "every content/<dir>/pack.json is published by a games.yml entry" \
        || bad "content directories no the games list line publishes:$unlisted"

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
        [ -z "$missing" ] && good "every game repository in projects.tsv with a game.yml is in the games list" \
            || bad "game repositories with a game.yml that the games list does not name:$missing"
        [ -z "$strange" ] && good "every games.yml repository is in dot-bootstrap's projects.tsv" \
            || bad "the games list names repositories projects.tsv does not:$strange"
    else
        echo "  --   no ../dot-bootstrap/projects.tsv: game repositories not compared"
    fi
fi

exit $((fails > 0))

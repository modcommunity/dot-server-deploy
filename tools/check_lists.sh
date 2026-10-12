#!/usr/bin/env bash
#
# The lists that are written down more than once agree.
#
#   tools/check_lists.sh      exit 0 when they do, 1 naming each difference
#
# setup.sh's ADDONS_ALL and addon_repo() are the facts (docs/setup.md, "One fact, one
# place"). Two other places cannot read them and so carry copies:
#
#   - setup.ps1's $addons and Get-AddonRepo: PowerShell has never run here, so it does not
#     parse a bash array; its copy had stopped at dot_friends, nineteen names, with no
#     dot_sql or dot_menu, and nothing noticed because nothing on this machine runs it.
#   - the name-to-repository exceptions that tools/addons-lock.sh and tools/package_check.sh
#     apply with sed after reading ADDONS_ALL.
#
# Also: every ADDONS_ALL name must be one those two scripts' read actually picks up, so an
# addon whose name does not start the way the others do cannot silently fall out of the
# lock and the staged tree.
#
# Arm it by deleting a name from setup.ps1's list, or the zee line from Get-AddonRepo.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad() { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }

# Every token between `ADDONS_ALL=(` and `)`, whatever it starts with.
mapfile -t SH_LIST < <(sed -n '/^ADDONS_ALL=(/,/)/p' setup.sh | sed 's/^ADDONS_ALL=(//; s/).*$//; s/#.*$//' | tr -s ' \t' '\n' | grep -v '^$')
# Every quoted name between `$addons = @(` and `)`.
mapfile -t PS_LIST < <(tr -d '\r' < setup.ps1 | sed -n '/^\$addons = @(/,/)/p' | grep -oE "'[^']+'" | tr -d "'")

if [ ${#SH_LIST[@]} -eq 0 ]; then
    bad "could not read ADDONS_ALL out of setup.sh"
elif [ ${#PS_LIST[@]} -eq 0 ]; then
    bad "could not read \$addons out of setup.ps1"
elif [ "${SH_LIST[*]}" = "${PS_LIST[*]}" ]; then
    good "setup.ps1's addon list is setup.sh's ADDONS_ALL (${#SH_LIST[@]} names, same order)"
else
    only_sh=$(comm -23 <(printf '%s\n' "${SH_LIST[@]}" | sort -u) <(printf '%s\n' "${PS_LIST[@]}" | sort -u) | tr '\n' ' ')
    only_ps=$(comm -13 <(printf '%s\n' "${SH_LIST[@]}" | sort -u) <(printf '%s\n' "${PS_LIST[@]}" | sort -u) | tr '\n' ' ')
    bad "setup.ps1's addon list differs from setup.sh's ADDONS_ALL (${#PS_LIST[@]} vs ${#SH_LIST[@]}); only in setup.sh: ${only_sh:-none}; only in setup.ps1: ${only_ps:-none}"
    [ -z "$only_sh$only_ps" ] && echo "       same names, different order"
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
        ex=$(grep -oE 's/\^[a-z0-9_]+\$/[a-z0-9-]+/' "$f" | sed -E 's#s/\^([a-z0-9_]+)\$/([a-z0-9-]+)/#\1=\2#' | sort -u)
        [ "$ex" = "$sh_ex" ] && good "$f maps the same names to repositories" \
            || bad "$f maps ($(echo ${ex:-none})), addon_repo() maps ($(echo $sh_ex))"
        # The pattern each script reads ADDONS_ALL with, run on the real list.
        pat=$(grep -oE "grep -oE '[^']+'" "$f" | head -1 | sed -E "s/grep -oE '([^']+)'/\1/")
        missed=""
        for n in "${SH_LIST[@]}"; do
            [ "$(printf '%s\n' "$n" | grep -oE "$pat")" = "$n" ] || missed="$missed $n"
        done
        [ -z "$missed" ] && good "$f's read of ADDONS_ALL ('$pat') picks up every name" \
            || bad "$f's read of ADDONS_ALL ('$pat') misses:$missed"
    done
fi

exit $((fails > 0))

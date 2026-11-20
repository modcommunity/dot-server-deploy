# Source me. Gamespice environment names: GS_X is read first, the old DOT_X keeps working.
#
#   . "$ROOT/tools/gs-env.sh"; gs_env_alias BOOTSTRAP NATIVES NATIVES_BASE
#
# For each NAME: when GS_NAME is set, DOT_NAME is exported with its value, so everything below
# (including GameSpice Bootstrap, which still reads DOT_*) sees the GS value. When only DOT_NAME is set
# one deprecation line goes to stderr. Silence with GS_QUIET_DEPRECATION=1.
gs_env_alias() {
    local n gs old
    for n in "$@"; do
        gs="GS_$n"; old="DOT_$n"
        if [ -n "${!gs+x}" ]; then
            export "$old=${!gs}"
        elif [ -n "${!old+x}" ] && [ -z "${GS_QUIET_DEPRECATION:-}" ]; then
            printf "WARN gs.config: environment variable %s is deprecated, set %s instead (the old name still works)\n" "$old" "$gs" >&2
        fi
    done
}

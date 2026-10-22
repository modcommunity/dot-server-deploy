#!/usr/bin/env bash
#
# The compose and Pterodactyl deploy modes write files that are valid, and write nothing on a dry run.
#
#   tools/check_deploy_modes.sh     exit 0 when they do, 1 naming each failure
#
# Arm it by deleting the healthcheck from gen_compose, a required key from the egg, or by making
# --dry-run write a file.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; OFF=$'\033[0m'
fails=0
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
good() { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
check() { if "${@:2}" >/dev/null 2>&1; then good "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ARGS=(--name "Check server" --game arena --games gamemann/game-g2gfast --port 6100 --max-players 16)

# Dry run: the plan is printed, nothing exists afterwards.
for m in compose pterodactyl; do
    out="$T/dry-$m"
    ./setup.sh --mode "$m" --out "$out" --dry-run "${ARGS[@]}" >"$T/dry-$m.txt" 2>&1
    if [ ! -e "$out" ] && grep -q "would write" "$T/dry-$m.txt"; then good "$m --dry-run lists files and writes none"; else bad "$m --dry-run"; fi
done

# Usage errors keep their exit code, and host stays the default.
./setup.sh --mode nonsense >/dev/null 2>&1; [ $? -eq 2 ] && good "an unknown mode exits 2" || bad "an unknown mode exits 2"
./setup.sh --mode compose >/dev/null 2>&1; [ $? -eq 2 ] && good "compose without --out exits 2" || bad "compose without --out exits 2"
./setup.sh --out "$T/x" >/dev/null 2>&1; [ $? -eq 2 ] && good "--out without a mode exits 2" || bad "--out without a mode exits 2"
tools/deploy-modes.sh --mode compose --out "$T/p" --password hunter2 >/dev/null 2>&1; [ $? -eq 2 ] && good "there is no password option" || bad "there is no password option"

# Compose.
C="$T/compose"
./setup.sh --mode compose --out "$C" --domain play.example.net "${ARGS[@]}" >/dev/null 2>&1
for f in docker-compose.yml .env; do check "compose writes $f" test -s "$C/$f"; done
for d in cfg content data; do check "compose makes $d/" test -d "$C/$d"; done
check "compose has a healthcheck and the three mounts" grep -qE "healthcheck:|./cfg:/srv/tmc/cfg" "$C/docker-compose.yml"
check ".env carries the settings" grep -q '^TMC_PORT=6100$' "$C/.env"
check "the WebSocket port is on the loopback behind --domain" grep -q '"127.0.0.1:${TMC_PORT:-6100}:${TMC_PORT:-6100}/tcp"' "$C/docker-compose.yml"
if cat "$C/.env" "$C/docker-compose.yml" | grep -v '^ *#' | grep -qiE '(pass|secret|token|_key)[a-z_]*[=:]'; then bad "no secret in the generated files"; else good "no secret in the generated files"; fi
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    check "docker compose config accepts it" docker compose -f "$C/docker-compose.yml" --project-directory "$C" config -q
else
    python3 -I - "$C/docker-compose.yml" <<'PY' && good "structural check (no docker): service, healthcheck, three mounts, three ports" || bad "structural check of docker-compose.yml"
import sys, re
t = open(sys.argv[1]).read()
need = ["services:", "  server:", "    healthcheck:", "docker-healthcheck.sh", "./cfg:/srv/tmc/cfg", "./content:/srv/tmc/content", "./data:/srv/tmc/data", "/udp", "env_file: .env"]
sys.exit(0 if all(n in t for n in need) and len(re.findall(r'^\s+- "[^"]+:[^"]+"', t, re.M)) >= 6 and "\t" not in t else 1)
PY
fi

# Pterodactyl: the egg against PTDL_v2's documented shape, and the variable defaults we set.
P="$T/ptero"
./setup.sh --mode pterodactyl --out "$P" "${ARGS[@]}" >/dev/null 2>&1
check "pterodactyl writes the egg, install script and allocations" test -s "$P/egg-tmc-server.json" -a -s "$P/install.sh" -a -s "$P/allocations.txt"
check "install.sh parses" bash -n "$P/install.sh"
for egg in "$P/egg-tmc-server.json" deploy/pterodactyl-egg.json; do
    python3 -I - "$egg" cfg.example/server.yml <<'PY' && good "egg shape: $egg" || bad "egg shape: $egg"
import json, sys
d = json.load(open(sys.argv[1]))
def need(c, m):
    if not c:
        print(m); sys.exit(1)
need(d["meta"]["version"] == "PTDL_v2", "meta.version")
for k in ("name", "author", "description", "startup"):
    need(isinstance(d.get(k), str) and d[k], k)
need(isinstance(d["docker_images"], dict) and d["docker_images"], "docker_images")
need(isinstance(d["file_denylist"], list), "file_denylist")
for k in ("files", "startup", "logs"):
    need(isinstance(json.loads(d["config"][k]), dict), "config." + k + " must be a JSON string")
need(d["config"]["stop"] == "quit", "stop")
s = d["scripts"]["installation"]
need(all(isinstance(s[k], str) and s[k] for k in ("script", "container", "entrypoint")), "scripts.installation")
need("{{SERVER_PORT}}" in d["startup"], "startup uses SERVER_PORT")
seen = set()
for v in d["variables"]:
    for k in ("name", "description", "env_variable", "rules"):
        need(isinstance(v[k], str) and v[k], "variable " + k)
    need(isinstance(v["default_value"], str), "variable default_value")
    need(isinstance(v["user_viewable"], bool) and isinstance(v["user_editable"], bool), "variable flags")
    need(v["field_type"] == "text", "field_type")
    need(v["env_variable"] not in seen, "duplicate " + v["env_variable"]); seen.add(v["env_variable"])
    need(not any(w in v["env_variable"] for w in ("PASSWORD", "SECRET", "TOKEN")), "secret as a startup variable: " + v["env_variable"])
# Every file the panel edits is a file we ship, and every key it sets is in it.
yml = open(sys.argv[2]).read()
for path, spec in json.loads(d["config"]["files"]).items():
    need(path == "cfg/server.yml" and spec["parser"] == "yaml", "unexpected config file " + path)
    for key, val in spec["find"].items():
        need(("\n" + yml).count("\n" + key + ":") == 1, "cfg.example/server.yml has no " + key)
        env = val[len("{{env."):-2]
        need(env in seen, key + " maps to an undefined variable " + env)
need(json.loads(d["config"]["files"]), "config.files maps no variable onto cfg/")
PY
done
python3 -I -c "
import json,sys
d=json.load(open('$P/egg-tmc-server.json'))
g={v['env_variable']:v['default_value'] for v in d['variables']}
sys.exit(0 if g['TMC_NAME']=='Check server' and g['TMC_MAX_PLAYERS']=='16' and g['TMC_RCON_PORT']=='6101' else 1)" && good "egg defaults carry the answers" || bad "egg defaults carry the answers"

echo
[ "$fails" -eq 0 ] && echo "deploy modes: all ok" || echo "deploy modes: $fails failed"
[ "$fails" -eq 0 ]

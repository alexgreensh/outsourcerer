#!/usr/bin/env bash
# `mc` starts a hub in the background and polls serve.log for its URL. The background redirect
# truncated the log only once the subshell ran, so the poll could read a DEAD hub's old URL and
# report Mission Control up before the new server existed (serve.json still missing). Seen as the
# test_release_0175 restart flake. mc must empty the log first and print only the new hub's URL.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SRC="$PWD/outsourcerer.sh"
T="$(mktemp -d)"; trap 'kill $(cat "$T/pids" 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home" OSRC_HOME="$T/osrc"; mkdir -p "$HOME" "$OSRC_HOME/hub" "$OSRC_HOME/disk-policy"
# This suite is not about the disk gate; never let the host's free space decide it.
printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$OSRC_HOME/disk-policy/settings"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# A python3 that starts the real hub 2 s late, so the stale-log window is wide open.
real="$(command -v python3)"; mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\ncase " $* " in *hub_server.py*) sleep 2 ;; esac\nexec "%s" "$@"\n' "$real" > "$T/bin/python3"
chmod +x "$T/bin/python3"
stale="http://127.0.0.1:9/?t=0123456789abcdef0123456789abcdef"
printf '[outsourcerer] hub: %s\n' "$stale" > "$OSRC_HOME/hub/serve.log"
port="$("$real" -I -c 'import random; print(random.randint(20000, 29999))')"

out="$(PATH="$T/bin:$PATH" OSRC_HUB_PORT="$port" OSRC_HUB_NO_OPEN=1 bash "$SRC" mc 2>/dev/null)"
pid="$(jq -r '.pid // empty' "$OSRC_HOME/hub/serve.json" 2>/dev/null)"; echo "$pid" > "$T/pids"
case "$out" in *"$stale"*) bad "mc reported the dead hub's old URL: $out" ;;
  *"Mission Control: http://127.0.0.1:"*) ok "mc reports the new hub's URL, not the stale one" ;;
  *) bad "mc printed no URL: $out" ;; esac
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "serve.json names a live hub once mc returns" \
  || bad "serve.json missing or dead right after mc returned (pid='$pid')"

# The guard itself, deterministically (the race above only loses under load).
live() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  type _osrc_mc_url_live >/dev/null 2>&1 || { echo missing; exit 0; }
  _osrc_mc_url_live "$1" && echo live || echo stale ) }
kill "$pid" 2>/dev/null; sleep 0.3; rm -f "$OSRC_HOME/hub/serve.json"
v="$(live "$stale")"; [ "$v" = stale ] && ok "a log URL with no serve.json is not accepted" || bad "no-record URL judged '$v'"
sleep 300 & lp=$!; echo "$lp" >> "$T/pids"
printf '{"pid":%s,"port":9}\n' "$lp" > "$OSRC_HOME/hub/serve.json"
v="$(live "$stale")"; [ "$v" = live ] && ok "a URL whose port and live pid match serve.json is accepted" || bad "matching record judged '$v'"
v="$(live "http://127.0.0.1:10/?t=x")"; [ "$v" = stale ] && ok "a URL on another port than serve.json is not accepted" || bad "port mismatch judged '$v'"
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
v="$(live "$stale")"; [ "$v" = stale ] && ok "a record naming a dead pid is not accepted" || bad "dead pid judged '$v'"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

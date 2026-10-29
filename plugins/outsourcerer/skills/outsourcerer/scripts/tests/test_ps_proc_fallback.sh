#!/usr/bin/env bash
# test_ps_proc_fallback.sh -- process identity on a `ps` with no -o (Git Bash / MSYS2, busybox).
#
# Issue #52 note: on Windows every run said NOT-ARMED. Git Bash's ps has no -o, so the supervision
# beacon could not read its own start time and exited at once. _ps_o now reads /proc there. Pins:
# (1) on a host where real `ps -o` works, the /proc answers equal ps's (lstart, stat, command);
# (2) the parser survives a process name holding ") "; (3) behind a ps that rejects -o (a shim, like
# Git Bash's), `heartbeat start` arms and verifies the beacon. Needs /proc: skips on macOS, and CI's
# Linux leg runs it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
if [ ! -r /proc/self/stat ] || [ ! -r /proc/stat ]; then echo "SKIP: no /proc on this host"; echo "RESULT: 0 passed, 0 failed"; exit 0; fi

TMP="$(mktemp -d)"
cleanup() { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc"; mkdir -p "$HOME" "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
norm() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g'; }

# A Git-Bash-style ps: any -o is an unknown option. Everything else goes to the real ps.
REALPS="$(command -v ps || true)"
mkdir -p "$TMP/nops"
{
  echo '#!/usr/bin/env bash'
  echo 'for a in "$@"; do case "$a" in -o|-o*) echo "ps: unknown option -- o" >&2; exit 1 ;; esac; done'
  [ -n "$REALPS" ] && printf 'exec "%s" "$@"\n' "$REALPS"
  echo 'exit 1'
} > "$TMP/nops/ps"
chmod +x "$TMP/nops/ps"
NOPS_PATH="$TMP/nops:$PATH"

# A helper process whose name holds ") " so the /proc stat parser has to find the LAST one.
cp "$(command -v sleep)" "$TMP/odd) name"
"$TMP/odd) name" 300 & SPID=$!
sleep 0.3

# Every read runs in a fresh shell, so the load-time probe sees the env we pass.
via() { # <real|proc> <field> <pid>
  local mode="$1"; shift
  if [ "$mode" = proc ]; then
    env PATH="$NOPS_PATH" bash -c 'f="$1"; shift; set -- "$@"; a="$1"; b="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _ps_o "$a" "$b"' _ "$SRC" "$@"
  else
    env bash -c 'f="$1"; shift; a="$1"; b="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _ps_o "$a" "$b"' _ "$SRC" "$@"
  fi
}

echo "=== ps -o keeps priority ==="
mkdir -p "$TMP/okps"
{ echo '#!/usr/bin/env bash'; echo 'echo "Sun Aug 9 12:34:56 2026"'; } > "$TMP/okps/ps"; chmod +x "$TMP/okps/ps"
r="$(PATH="$TMP/okps:$PATH" bash -c 'f="$1"; p="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _ps_o lstart "$p"' _ "$SRC" "$SPID")"
[ "$r" = "Sun Aug 9 12:34:56 2026" ] && ok "a ps whose -o works is used as-is" || bad "working ps -o was bypassed: [$r]"

echo "=== (1) /proc answers match ps ==="
if LC_ALL=C ps -o lstart= -p "$SPID" >/dev/null 2>&1; then
  real="$(via real lstart "$SPID" | norm)"; proc="$(via proc lstart "$SPID" | norm)"
  [ -n "$proc" ] && [ "$proc" = "$real" ] && ok "lstart from /proc equals ps ($proc)" || bad "lstart differs: ps=[$real] proc=[$proc]"
  real="$(via real stat "$SPID" | norm)"; proc="$(via proc stat "$SPID" | norm)"
  [ -n "$proc" ] && [ "${real:0:1}" = "$proc" ] && ok "state from /proc matches ps ($proc vs $real)" || bad "state differs: ps=[$real] proc=[$proc]"
else
  echo "SKIP: this ps has no -o, cannot compare against it"
fi
cmd="$(via proc command "$SPID")"
case "$cmd" in *"odd) name 300"*) ok "command line from /proc carries argv" ;; *) bad "command from /proc: [$cmd]" ;; esac
id="$(env PATH="$NOPS_PATH" bash -c 'f="$1"; p="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _pid_start_identity "$p"' _ "$SRC" "$SPID")"
env bash -c 'f="$1"; m="$2"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _pid_start_valid "$m"' _ "$SRC" "$id" \
  && ok "identity marker from /proc passes _pid_start_valid ($id)" || bad "identity marker invalid: [$id]"
[ -z "$(via proc lstart 999999999)" ] && ok "a gone pid reads empty" || bad "gone pid returned data"

echo "=== (2) supervision arms when ps has no -o (the Windows NOT-ARMED symptom) ==="
out="$(env -u OSRC_HEARTBEAT_DISABLED PATH="$NOPS_PATH" OSRC_HOME="$TMP/hb" bash "$SRC" heartbeat start 2>&1)"; rc=$?
case "$out" in *"verified live"*) ok "heartbeat start: beacon verified live" ;; *) bad "arm failed (rc $rc): $(printf '%s' "$out" | tail -2)" ;; esac
case "$out" in *NOT-ARMED*) bad "printed NOT-ARMED" ;; *) ok "no NOT-ARMED line" ;; esac
st="$(env -u OSRC_HEARTBEAT_DISABLED PATH="$NOPS_PATH" OSRC_HOME="$TMP/hb" bash "$SRC" heartbeat status 2>&1)"
case "$st" in *"verified live"*) ok "heartbeat status re-verifies the leader through /proc" ;; *) bad "status: $(printf '%s' "$st" | tail -2)" ;; esac
for lp in $(cat "$TMP"/hb/*/leader/owner.json "$TMP"/hb/leader/owner.json 2>/dev/null | jq -r .pid 2>/dev/null); do kill "$lp" 2>/dev/null; done

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

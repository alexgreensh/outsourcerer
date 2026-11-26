#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_disk_r2.sh -- live-test findings on the disk policy (lane osrc-fx-disk-r2). Each block names
# the tester's finding it pins (F2 paused visibility, F9 settings bounds, F10 symlinked OSRC_HOME,
# F12 override codes, F13 corrupt manifest, F15 cancel while paused).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.diskr2-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
KILL=""
cleanup_all() {
  local f p
  for f in "$TMP"/*/disk-policy/monitor.lock/owner; do [ -f "$f" ] && kill "$(cut -d'|' -f1 "$f")" 2>/dev/null; done
  for p in $KILL; do kill -CONT "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  sleep 0.2; rm -rf "$TMP"
}
trap cleanup_all EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0 OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=1 FREEF="$TMP/free_kb"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"; : > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
setfree() { printf '%s' "$1" > "$FREEF"; }
osrc() {   # osrc <home> <code>: run code with the engine sourced and free space read from $FREEF
  OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1
    _osrc_free_kb() { cat "$FREEF" 2>/dev/null; }
    eval "$1"' "$SRC" "$2" 2>&1
}
home() { mkdir -p "$TMP/$1/jobs" "$TMP/$1/disk-policy"; printf '%s' "${2:-}" > "$TMP/$1/disk-policy/settings"; printf '%s' "$TMP/$1"; }
lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g'; }
stopped() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in *T*) return 0 ;; esac; return 1; }
# fakejob <home> <id> -> running job whose delegate and supervisor are real sleeps; prints "pid spid".
fakejob() {
  local jd="$1/jobs/$2" p s
  mkdir -p "$jd"; sleep 300 </dev/null >/dev/null 2>&1 & p=$!; sleep 300 </dev/null >/dev/null 2>&1 & s=$!
  KILL="$KILL $p $s"; echo running > "$jd/status"; echo "$p" > "$jd/pid"; echo "$s" > "$jd/supervisor_pid"
  lstart "$p" > "$jd/pid_start"; lstart "$s" > "$jd/supervisor_pid_start"; date +%s > "$jd/started_at"
  printf '{"provider":"devin","model":"swe-2-high","verb":"run"}\n' > "$jd/meta.json"
  printf '%s %s' "$p" "$s"
}
G='OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=500\n'

echo "=== F2: a disk-paused job reads as paused in status, the hub, and supervise ==="
H="$(home f2 "$(printf "$G")")"; J=20261126-000000-aaaaaaaaaaaa; read -r P S <<<"$(fakejob "$H" "$J")"; setfree 1048576
osrc "$H" "_osrc_disk_pause_job \"\$OSRC_JOBS/$J\"" >/dev/null
stopped "$P" && ok "the job's delegate is SIGSTOPped" || bad "setup: delegate not stopped"
o="$(osrc "$H" "_status_line $J")"
grep -q "^$J paused .*Paused: disk below 500.0G" <<<"$o" && ok "status shows paused and the pause floor" || bad "status: $o"
o="$(osrc "$H" "_osrc_hub_lane_job $J")"
[ "$(jq -r .status <<<"$o")" = Blocked ] && [ "$(jq -r .note <<<"$o" | cut -c1-19)" = "Paused: disk below " ] \
  && ok "hub lane is Blocked with the pause note" || bad "hub lane: $o"
o="$(osrc "$H" "_osrc_hub_lane_state $J")"
[ "${o%% *}" = limit ] && ok "lane-truth state is limit (attention: limit)" || bad "lane state: $o"
o="$(osrc "$H" "SCRIPT_PATH=x; _sv_observe_emit $J \$(date +%s) supervise owner1; _sv_observe_emit $J \$(date +%s) supervise owner1
  jq -r 'select(.target==\"$J\") | .kind + \"|\" + .next' \"\$OSRC_HOME/lanes/events.jsonl\"")"
[ "$(grep -c '^disk-paused|x disk status' <<<"$o")" = 1 ] && ok "supervise logs one disk-paused event naming the job" || bad "supervise events: $o"

echo "=== F15: cancel of a disk-paused job resumes its supervisor and retires the record ==="
osrc "$H" "cmd_cancel $J" >/dev/null; sleep 0.3
! stopped "$S" && kill -0 "$S" 2>/dev/null && ok "supervisor runs again after cancel" || bad "supervisor still stopped: $(ps -o stat= -p "$S")"
[ ! -f "$H/jobs/$J/disk-paused" ] && ok "pause record removed" || bad "pause record kept after cancel"
kill "$S" 2>/dev/null

echo "=== F9: out-of-range settings never wrap, never drop the critical floor ==="
H="$(home f9)"; d="$(osrc "$H" '_osrc_disk_floors_kb')"
H="$(home f9a "$(printf 'OSRC_DISK_MIN_GB=abc\nOSRC_DISK_PAUSE_GB=-5\nOSRC_DISK_CRITICAL_GB=99999999999999999999\n')")"
o="$(osrc "$H" '_osrc_disk_floors_kb')"
[ "$o" = "$d" ] && ok "invalid and 20-digit settings fall back to the defaults ($d)" || bad "floors $o, defaults $d"
o="$(osrc "$H" '_osrc_disk_report 2>/dev/null | head -2')"
grep -q 'settings rejected.*OSRC_DISK_MIN_GB=abc OSRC_DISK_PAUSE_GB=-5 OSRC_DISK_CRITICAL_GB=99999999999999999999' <<<"$o" \
  && ! grep -q 'critical 0K' <<<"$o" && ok "disk status names the rejected settings and keeps a critical floor" || bad "report: $o"
H="$(home f9b "$(printf 'OSRC_DISK_MIN_GB=9999999999999\n')")"; read -r l p c <<<"$(osrc "$H" '_osrc_disk_floors_kb')"
[ "$l" = "${d%% *}" ] && [ "$p" -le $(( l * 3 / 4 )) ] && [ "$c" -gt 0 ] && ok "a 13-digit launch floor is rejected, pause stays under launch" || bad "floors $l $p $c"
setfree $(( l - 1048576 ))
g="$(osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
grep -q "< $(( l / 1048576 ))GB launch floor" <<<"$g" && ok "the gate enforces the floor status shows" || bad "gate: $g"
H="$(home f9c "$(printf 'OSRC_DISK_MIN_GB=5000000\nOSRC_DISK_PAUSE_GB=08\nOSRC_DISK_CRITICAL_GB=1\n')")"
o="$(osrc "$H" '_osrc_disk_floors_kb')"
[ "$o" = "1048576000000 8388608 1048576" ] && ok "7 digits clamp to 1,000,000 GB; 08 reads as 8 GB, not octal" || bad "floors: $o"

echo "=== F10: cleanup under a symlinked OSRC_HOME still marks an old finished job SAFE ==="
mkdir -p "$TMP/real" && ln -s "$TMP/real" "$TMP/link"
H="$TMP/link/osrc"; J=20200101-000000-deadbeef0000; mkdir -p "$H/jobs/$J" "$H/disk-policy"
echo done > "$H/jobs/$J/status"; touch -t 202001010000 "$H/jobs/$J/status" "$H/jobs/$J"
printf '{"path":"%s","kind":"job","session":"%s","repo":"","ts":1}\n' "$H/jobs/$J" "$J" > "$H/created.jsonl"
o="$(OSRC_HOME="$H" bash "$SRC" cleanup 2>&1)"
grep -q "SAFE .*job .*$J" <<<"$o" && ! grep -q 'not the shape' <<<"$o" && ok "old done job is SAFE through the symlink" || bad "cleanup: $o"
OSRC_HOME="$H" bash "$SRC" cleanup --apply >/dev/null 2>&1
[ ! -d "$TMP/real/osrc/jobs/$J" ] && ok "cleanup --apply removes it" || bad "--apply left the job dir"
mkdir -p "$H/jobs/$J"; printf '{"path":"%s","kind":"job","session":"","repo":"","ts":1}\n' "$TMP/link/osrc" > "$H/created.jsonl"
o="$(OSRC_HOME="$H" bash "$SRC" cleanup 2>&1)"
grep -q '^  ASK ' <<<"$o" && ! grep -q '^  SAFE' <<<"$o" && ok "OSRC_HOME itself is never SAFE through the symlink" || bad "home item: $o"

echo "=== F12: a wrong code does not replace the code a refusal already printed ==="
H="$(home f12 "$(printf 'OSRC_DISK_MIN_GB=500\nOSRC_DISK_PAUSE_GB=0\nOSRC_DISK_CRITICAL_GB=1\n')")"; setfree 52428800
code_of() { sed -n 's/.*OSRC_DISK_OK=\([0-9a-f]\{8\}\).*/\1/p' <<<"$1" | head -1; }
a="$(code_of "$(osrc "$H" '_osrc_disk_gate fg')")"
g="$(OSRC_DISK_OK=deadbeef osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
[ -n "$a" ] && [ "$(code_of "$g")" = "$a" ] && ! grep -q 'gate-rc=0' <<<"$g" && ok "the refusal for a wrong code reprints code A" || bad "code changed: $a -> $g"
g="$(OSRC_DISK_OK="$a" osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "code A still admits one command" || bad "code A refused: $g"
g="$(OSRC_DISK_OK="$a" osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
! grep -q 'gate-rc=0' <<<"$g" && ok "and only once" || bad "code A admitted twice"

echo "=== F13: a corrupt manifest line is shown, never a silent empty scan ==="
H="$(home f13)"; mkdir -p "$H/jobs/$J"; echo done > "$H/jobs/$J/status"; touch -t 202001010000 "$H/jobs/$J/status" "$H/jobs/$J"
printf '{"path":"%s","kind":"job","session":"%s","repo":"","ts":1}\n' "$H/jobs/$J" "$J" > "$H/created.jsonl"
OSRC_HOME="$H" bash "$SRC" cleanup >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "a clean dry run with nothing to ask exits 0" || bad "clean dry run rc=$rc"
printf 'not json\n[1]\n' >> "$H/created.jsonl"
o="$(OSRC_HOME="$H" bash "$SRC" cleanup 2>&1)"
grep -q '1 SAFE, 1 ASK' <<<"$o" && grep -q 'ASK .*manifest .*created.jsonl (line 2,3) .*malformed manifest line' <<<"$o" \
  && ok "bad lines become one named ASK item; good lines still listed" || bad "dry run: $o"
o="$(osrc "$H" 'jq() { case "$*" in *fromjson*) return 5 ;; esac; command jq "$@"; }; _osrc_cleanup_items --no-size | jq -r .verdict | sort | tr "\n" " "')"
[ "$o" = "ASK SAFE " ] && ok "a jq that aborts on the bad line falls back to line-by-line parsing" || bad "fallback: $o"
OSRC_HOME="$H" bash "$SRC" cleanup --apply >/dev/null 2>&1
[ ! -d "$H/jobs/$J" ] && grep -q 'not json' "$H/created.jsonl" && ok "--apply deletes the SAFE job and leaves the manifest alone" || bad "apply with a bad line"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]

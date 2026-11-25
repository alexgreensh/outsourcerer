#!/usr/bin/env bash
# test_tmux_headless_fallback.sh — issue #35: a tmux-ABSENT host must not refuse to run. A slow-lane
# auto-detach falls back to the supervised headless bg path (and recommends installing tmux), instead
# of dying. OSRC_REQUIRE_TMUX=1 restores the strict "install tmux or fail" behavior.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT
export HOME="$TMP/fakehome"
mkdir -p "$HOME"
BIN="$TMP/bin"; FH="$TMP/fh/.local/bin"; mkdir -p "$BIN" "$FH"
# symlink every PATH binary EXCEPT tmux, so `have tmux` is genuinely false but jq/git/etc still work.
IFS=:; for d in $PATH; do [ -d "$d" ] || continue; for f in "$d"/*; do b="${f##*/}"; [ "$b" = tmux ] && continue; [ -e "$BIN/$b" ] || ln -s "$f" "$BIN/$b" 2>/dev/null; done; done; unset IFS
cat > "$FH/devin" <<'FD'
#!/bin/bash
[ "${1:-}" = auth ] && { echo "Logged in as test"; exit 0; }
echo "FAKE DEVIN: done"; echo "OSRC::DONE"; exit 0
FD
chmod +x "$FH/devin"
[ -z "$(PATH="$BIN" command -v tmux 2>/dev/null)" ] || bad "harness: tmux still visible on scrubbed PATH"

run() { # <extra-env> <home> -> sets RC/ERR
  ERR="$TMP/err.$RANDOM"
  env PATH="$BIN:$FH" HOME="$TMP/fh" OSRC_HOME="$1" OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
    OSRC_FORCE_AUTODETACH=1 OSRC_HEARTBEAT_DISABLED=1 OSRC_CATALOG_VALIDATE=0 OUTSOURCERER_DEPTH=0 \
    $2 bash "$SRC" run --spend-ok -m glm-5.2 "task" >/dev/null 2>"$ERR" </dev/null; RC=$?
}

# (a) default: tmux absent -> fall back to bg (rc0), a job is created, and it recommends tmux.
H1="$TMP/h1"; mkdir -p "$H1"
# Lift the launch and pause disk floors for this fake home only (the host's free disk must not decide this test).
mkdir -p "$H1/disk-policy" && printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$H1/disk-policy/settings"
run "$H1" ""
[ "$RC" -eq 0 ]                                            && ok "tmux-absent: run does not die (rc0)"           || bad "tmux-absent: rc=$RC (expected 0)"
[ "$(find "$H1/jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && ok "tmux-absent: a bg job was created (fell back)" || bad "tmux-absent: no bg job created"
grep -q "RECOMMENDED: install tmux" "$ERR"                 && ok "tmux-absent: recommends installing tmux"       || bad "tmux-absent: no tmux recommendation"

# (b) OSRC_REQUIRE_TMUX=1: tmux absent -> die, no job.
H2="$TMP/h2"; mkdir -p "$H2"
# Lift the launch and pause disk floors for this fake home only (the host's free disk must not decide this test).
mkdir -p "$H2/disk-policy" && printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$H2/disk-policy/settings"
run "$H2" "OSRC_REQUIRE_TMUX=1"
[ "$RC" -ne 0 ]                                            && ok "OSRC_REQUIRE_TMUX=1: dies when tmux absent"    || bad "OSRC_REQUIRE_TMUX=1: rc=$RC (expected nonzero)"
[ "$(find "$H2/jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] && ok "OSRC_REQUIRE_TMUX=1: no bg job created" || bad "OSRC_REQUIRE_TMUX=1: a job leaked"
grep -qi "OSRC_REQUIRE_TMUX" "$ERR"                        && ok "OSRC_REQUIRE_TMUX=1: die names the knob"       || bad "OSRC_REQUIRE_TMUX=1: die message unclear"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# test_copilot.sh — session-start copilot handshake: mode persistence, limit awareness, conserve
# routing, and the NON-INTERACTIVE-SAFE guarantee (GLM F10: brief/mode must never hang a pipe/CI).
# OFFLINE; sources the script and exercises the pure functions. Run: bash test_copilot.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

export OSRC_HOME="${TMPDIR:-/tmp}/osrc-copilot-test-$$"
mkdir -p "$OSRC_HOME"
trap 'rm -rf "$OSRC_HOME"' EXIT

. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- mode: default unset, set, read-back, validation, reset ---
_mode_read >/dev/null 2>&1 && bad "mode reads a value when unset" || ok "mode unset by default"
cmd_mode auto >/dev/null 2>&1
[ "$(_mode_read)" = "auto" ] && ok "mode auto persists + reads back" || bad "mode auto not persisted"
cmd_mode C >/dev/null 2>&1   # letter alias
[ "$(_mode_read)" = "hybrid" ] && ok "letter alias C -> hybrid" || bad "letter alias failed: $(_mode_read)"
printf 'garbage\n' > "$OSRC_MODE_FILE"
_mode_read >/dev/null 2>&1 && bad "invalid mode value accepted" || ok "invalid mode value rejected"
cmd_mode reset >/dev/null 2>&1
[ -f "$OSRC_MODE_FILE" ] && bad "reset left the mode file" || ok "reset clears the mode file"
# whitespace tolerance
printf '  hybrid \n' > "$OSRC_MODE_FILE"
[ "$(_mode_read)" = "hybrid" ] && ok "mode read trims whitespace" || bad "mode whitespace not trimmed"
rm -f "$OSRC_MODE_FILE"

# --- limit normalization + expiry ---
[ "$(_pct_normalize 95)" = "95" ] && ok "_pct_normalize accepts 95" || bad "_pct_normalize 95 failed"
[ -z "$(_pct_normalize 250)" ] && ok "_pct_normalize rejects out-of-range" || bad "_pct_normalize took 250"
[ -z "$(_pct_normalize abc)" ] && ok "_pct_normalize rejects non-numeric" || bad "_pct_normalize took abc"
future=$(( $(date +%s) + 3600 )); past=$(( $(date +%s) - 3600 ))
[ "$(_window_pct 80 "$future")" = "80" ] && ok "_window_pct keeps a live window" || bad "_window_pct dropped a live window"
[ -z "$(_window_pct 80 "$past")" ] && ok "_window_pct drops an expired window" || bad "_window_pct kept an expired window"

# --- session limits: OSRC_CC_PRESSURE override path ---
lim="$(OSRC_CC_PRESSURE=77 _session_limits)"
case "$lim" in *claude5h=77*) ok "OSRC_CC_PRESSURE override reflected in limits" ;; *) bad "pressure override missing: $lim" ;; esac

# --- conserve reco: threshold behavior (Alex's 50% line) ---
r="$(OSRC_CONSERVE_THRESHOLD=50 _conserve_reco 'claude5h=95' 'devin=glm/swe claude=native')"
case "$r" in CONSERVE:*Devin*) ok "conserve fires >=50% and picks the free Devin lane" ;; *) bad "conserve wrong at 95%: $r" ;; esac
r="$(OSRC_CONSERVE_THRESHOLD=50 _conserve_reco 'claude5h=20' 'devin=glm/swe')"
case "$r" in HEADROOM:*) ok "no forced conservation below the line" ;; *) bad "conserve wrongly fired at 20%: $r" ;; esac
# priority: local beats devin
r="$(OSRC_CONSERVE_THRESHOLD=50 _conserve_reco 'claude5h=90' 'local=qwen devin=glm/swe')"
case "$r" in *local*) ok "conserve prefers local (\$0/private) over Devin" ;; *) bad "conserve priority wrong: $r" ;; esac
# all-tight: no cheap lane ready
r="$(OSRC_CONSERVE_THRESHOLD=50 _conserve_reco 'claude5h=95' 'claude=native')"
case "$r" in *"no lower-cost lane"*) ok "all-tight case handled (no cheap lane ready)" ;; *) bad "all-tight case wrong: $r" ;; esac
# codex only usable when ChatGPT plan has headroom
r="$(OSRC_CONSERVE_THRESHOLD=50 _conserve_reco 'claude5h=95 codex5h=30' 'codex=sol/terra')"
case "$r" in *Codex*) ok "codex offered when ChatGPT plan has headroom" ;; *) bad "codex-headroom case wrong: $r" ;; esac
r="$(OSRC_CONSERVE_THRESHOLD=50 _conserve_reco 'claude5h=95 codex5h=90' 'codex=sol/terra')"
case "$r" in *Codex*) bad "codex offered despite ChatGPT plan also tight" ;; *) ok "codex NOT offered when its own plan is tight" ;; esac

# --- NON-INTERACTIVE SAFETY (GLM F10): brief must print + return, never read/hang ---
if grep -nE '(^|[^_])read .*</dev/tty|IFS=.*read' "$SRC" | grep -iE 'brief|_mode|_session_limits|_conserve|_ready_lanes' >/dev/null 2>&1; then
  bad "handshake code contains an interactive read (would hang bg/CI)"
else ok "handshake code has NO interactive read (safe in bg/CI)"; fi
out="$(cmd_brief </dev/null 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "cmd_brief returns 0 on closed stdin (no hang)" || bad "cmd_brief hung/failed on closed stdin (rc=$rc)"
case "$out" in *"session brief"*) ok "cmd_brief prints the brief" ;; *) bad "cmd_brief printed nothing useful" ;; esac

# --- bg verb inference (papercut fix): `bg "task"` implies run ---
grep -q 'no verb given; defaulting to `run`' "$SRC" && ok "bg infers run when no verb given" || bad "bg verb inference missing"

# --- limits tap (universal capture, no token-optimizer needed) ---
TAPD="$OSRC_HOME/tap"; mkdir -p "$TAPD"
export OSRC_CLAUDE_SETTINGS="$TAPD/settings.json"
printf '{"statusLine":{"type":"command","command":"echo original-line"}}\n' > "$OSRC_CLAUDE_SETTINGS"
printf '{"rate_limits":{"five_hour":{"used_percentage":77,"resets_at":9999999999},"seven_day":{"used_percentage":30,"resets_at":9999999999}}}\n' > "$TAPD/in.json"
cmd_tap install >/dev/null 2>&1
grep -q 'outsourcerer' "$OSRC_CLAUDE_SETTINGS" && ok "tap install wires statusLine through outsourcerer" || bad "tap install did not update settings"
out="$(cmd_tap run < "$TAPD/in.json" 2>/dev/null)"
case "$out" in *original-line*) ok "tap run passes the original statusline through" ;; *) bad "tap passthrough broken: $out" ;; esac
grep -q '"used_percentage":77' "$OSRC_HOME/rate-limits.json" 2>/dev/null && ok "tap captures rate limits to \$OSRC_HOME" || bad "tap did not capture limits"
lim="$(_session_limits)"
case "$lim" in *claude5h=77*) ok "_session_limits reads the tap capture" ;; *) bad "_session_limits ignored tap capture: $lim" ;; esac
cmd_tap uninstall >/dev/null 2>&1
grep -q '"command": *"echo original-line"' "$OSRC_CLAUDE_SETTINGS" && ok "tap uninstall restores the original statusline" || bad "tap uninstall did not restore settings"
unset OSRC_CLAUDE_SETTINGS

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

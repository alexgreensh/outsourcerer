#!/bin/bash
# test_codex_windows_sandbox.sh -- isolated codex runs must keep the Windows sandbox mode.
#
# `codex exec --ignore-user-config` drops the whole ~/.codex/config.toml, including
# `[windows] sandbox = "elevated"`. On Windows that leaves `--sandbox workspace-write` with no usable
# sandbox mode and codex rejects every command and patch. The engine re-supplies ONLY that setting
# (and `[features] prefer_mxc`) as -c overrides. These tests pin three things:
#   (1) the config reader takes exactly those two keys, validated, and nothing else;
#   (2) the override is added on Windows only, and only when isolation is on;
#   (3) every codex-exec site that builds the isolation flag carries it.
# The Windows platform is simulated via OSRC_PLATFORM, so this runs on any host; on a real Git Bash
# runner OSRC_PLATFORM is already "windows".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP/osrc"
export HOME="$TMP/home"; mkdir -p "$HOME"
unset CODEX_HOME USERPROFILE
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

set --
. "$SRC" >/dev/null 2>&1
trap cleanup EXIT
type _codex_win_sandbox_read >/dev/null 2>&1 || { echo "FAIL: _codex_win_sandbox_read not defined"; exit 1; }

CH="$TMP/codexhome"; mkdir -p "$CH"; export CODEX_HOME="$CH"
cfg() { printf '%s' "$1" > "$CH/config.toml"; }
read1() { _codex_win_sandbox_read | tr '\n' ' ' | sed 's/ $//'; }

echo "=== (1) config reader ==="
cfg $'model = "x"\n[windows]\nsandbox = "elevated"\n'
eq "table form: elevated" "$(read1)" "sandbox=elevated"
cfg $'[windows]\nsandbox = "unelevated" # legacy\n'
eq "trailing comment ignored" "$(read1)" "sandbox=unelevated"
cfg $'[windows]\r\nsandbox = "elevated"\r\n[features]\r\nprefer_mxc = true\r\n'
eq "CRLF file + prefer_mxc" "$(read1)" "sandbox=elevated prefer_mxc=true"
cfg $'windows.sandbox = \'mxc\'\nfeatures.prefer_mxc = false\n'
eq "dotted keys + single quotes" "$(read1)" "sandbox=mxc prefer_mxc=false"
cfg $'[windows]\nsandbox = "elevated; rm -rf /"\n'
eq "value outside the allowlist is dropped" "$(read1)" ""
cfg $'[windows]\nsandbox = "$(touch '"$TMP"'/pwned)"\n'
eq "command substitution value is dropped" "$(read1)" ""
[ ! -e "$TMP/pwned" ] && ok "no command substitution executed" || bad "command substitution executed"
cfg $'[other]\nsandbox = "elevated"\n[windows.extra]\nsandbox = "elevated"\n'
eq "sandbox key in other tables ignored" "$(read1)" ""
cfg $'[windows]\nsandbox_private_desktop = true\n'
eq "sandbox_private_desktop is not sandbox" "$(read1)" ""
cfg $'[mcp_servers.x]\ncommand = "evil"\n[model_providers.p]\nbase_url = "http://x"\n[windows]\nsandbox = "elevated"\n'
eq "nothing else re-imported" "$(read1)" "sandbox=elevated"
cfg $'[[projects]]\nsandbox = "elevated"\n'
eq "array-of-tables ignored" "$(read1)" ""
cfg $'["windows"]\nsandbox = "elevated"\n'
eq "quoted table header" "$(read1)" "sandbox=elevated"
cfg $'windows = { sandbox = "unelevated" }\n'
eq "inline table windows" "$(read1)" "sandbox=unelevated"
cfg $'windows = { foo = 1, sandbox = \'elevated\' }\nfeatures = { prefer_mxc = true }\n'
eq "inline tables, single quotes, other keys" "$(read1)" "sandbox=elevated prefer_mxc=true"
cfg $'windows = { sandbox = "bogus" }\n'
eq "inline table bad value dropped" "$(read1)" ""
cfg $'windows = { sandbox_private_desktop = true }\n'
eq "inline table other key not matched" "$(read1)" ""
printf '\357\273\277[windows]\nsandbox = "elevated"\n' > "$CH/config.toml"
eq "UTF-8 BOM before first header" "$(read1)" "sandbox=elevated"
rm -f "$CH/config.toml"
eq "missing config -> nothing" "$(read1)" ""

echo "=== config location ==="
cfg $'[windows]\nsandbox = "elevated"\n'
eq "CODEX_HOME honored" "$(_codex_user_config_file)" "$CH/config.toml"
unset CODEX_HOME; mkdir -p "$HOME/.codex"; printf '[windows]\nsandbox = "unelevated"\n' > "$HOME/.codex/config.toml"
eq "falls back to ~/.codex" "$(_codex_user_config_file)" "$HOME/.codex/config.toml"
rm -rf "$HOME/.codex"; mkdir -p "$TMP/up/.codex"; printf '[windows]\nsandbox = "elevated"\n' > "$TMP/up/.codex/config.toml"
eq "falls back to USERPROFILE/.codex" "$(USERPROFILE="$TMP/up" _codex_user_config_file)" "$TMP/up/.codex/config.toml"
export CODEX_HOME="$CH"

echo "=== (2) args: Windows only ==="
cfg $'[windows]\nsandbox = "elevated"\n[features]\nprefer_mxc = true\n'
OSRC_PLATFORM=linux; _codex_win_sandbox_args
eq "non-Windows adds nothing" "${#_CODEX_WIN_ARGS[@]}" "0"
OSRC_PLATFORM=mac; _codex_win_sandbox_args
eq "mac adds nothing" "${#_CODEX_WIN_ARGS[@]}" "0"
OSRC_PLATFORM=windows; _codex_win_sandbox_args
eq "Windows adds -c overrides" "${_CODEX_WIN_ARGS[*]}" "-c windows.sandbox=elevated -c features.prefer_mxc=true"
rm -f "$CH/config.toml"; _codex_win_sandbox_args
eq "Windows without the key adds nothing" "${#_CODEX_WIN_ARGS[@]}" "0"

echo "=== (3) delegate_cxnative ==="
{
  _tier_banner() { :; }; record_ledger() { :; }; _codex_quota_line() { :; }
  resolve_tier() { echo "mid"; }; _build_prompt() { printf '%s' "$2"; }
  _lane_cost_disclosure() { echo "$1"; }; _timeout() { shift; "$@"; }
  _codex_code_mode_host() { return 0; }
  REST=("test task"); RESOLVED_ID="sol"
  CODEX_ARGS=""; codex() { CODEX_ARGS="$*"; return 0; }
  cfg $'[windows]\nsandbox = "elevated"\n[mcp_servers.x]\ncommand = "evil"\n'

  OSRC_PLATFORM=windows; unset OSRC_CODEX_USER_CONFIG
  delegate_cxnative accept-edits >/dev/null 2>&1
  case "$CODEX_ARGS" in *--ignore-user-config*) ok "isolation flag still passed" ;; *) bad "isolation flag missing: $CODEX_ARGS" ;; esac
  case "$CODEX_ARGS" in *"-c windows.sandbox=elevated"*) ok "Windows: windows.sandbox=elevated carried" ;; *) bad "Windows: sandbox not carried: $CODEX_ARGS" ;; esac
  case "$CODEX_ARGS" in *mcp_servers*|*evil*) bad "user config leaked: $CODEX_ARGS" ;; *) ok "no other user config leaked" ;; esac
  case "$CODEX_ARGS" in *"--sandbox workspace-write"*) ok "workspace-write sandbox kept" ;; *) bad "workspace-write missing: $CODEX_ARGS" ;; esac

  OSRC_PLATFORM=linux
  delegate_cxnative accept-edits >/dev/null 2>&1
  case "$CODEX_ARGS" in *windows.sandbox*) bad "Linux run got windows.sandbox: $CODEX_ARGS" ;; *) ok "Linux: no windows.sandbox override" ;; esac

  OSRC_PLATFORM=windows; OSRC_CODEX_USER_CONFIG=1
  delegate_cxnative accept-edits >/dev/null 2>&1
  case "$CODEX_ARGS" in *--ignore-user-config*|*windows.sandbox*) bad "opt-out should pass neither: $CODEX_ARGS" ;; *) ok "OSRC_CODEX_USER_CONFIG=1: no isolation flag, no override" ;; esac
  unset OSRC_CODEX_USER_CONFIG
}

echo "=== structural: every isolated codex-exec site carries the override ==="
n_iso="$(grep -Ec '^\s*local (iso|_iso|_or_iso)=\(\); \[ "\$\{OSRC_CODEX_USER_CONFIG:-0\}" = "1" \] \|\| (iso|_iso|_or_iso)=\(--ignore-user-config\)' "$SRC")"
n_win="$(grep -Ec '^\s*_codex_win_sandbox_args; \[ "\$\{#(iso|_iso|_or_iso)\[@\]\}" -eq 0 \] \|\| (iso|_iso|_or_iso)\+=' "$SRC")"
[ "$n_iso" -ge 4 ] && eq "isolation sites ($n_iso) each have a carry-over line" "$n_win" "$n_iso" || bad "expected >=4 isolation sites, found $n_iso"
grep -q 'windows-sandbox: WARNING' "$SRC" && ok "doctor warns when [windows] sandbox is missing" || bad "doctor warning missing"
grep -Eq 'codex exec --ignore-user-config \$\{_CODEX_WIN_ARGS\[@\]\+.*--sandbox read-only .*reply PONG' "$SRC" \
  && ok "doctor liveness ping carries the Windows sandbox override" || bad "doctor ping missing the override"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

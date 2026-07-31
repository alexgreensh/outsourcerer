#!/usr/bin/env bash
# Focused kill-window regressions for the remaining re-verdict residuals.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-reverdict.XXXXXX")"; TEST_TMP="$TMP"; trap 'rm -rf "$TEST_TMP"' EXIT
export OSRC_HOME="$TMP/state"; OSRC_EXTERNAL_SEND=1; export OSRC_EXTERNAL_SEND; pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
set --; . "$SRC" >/dev/null 2>&1
_state_sync(){ return 0; }
_pid_start_identity(){ [ "$1" = "$$" ] && printf '%s\n' 'Thu Jul 31 01:02:03 2026' || printf '%s\n' 'Fri Aug 2 01:02:03 2026'; }

# SIGKILL after the provisional owner is durable, before canonical publication.
mkdir -p "$OSRC_HEARTBEAT"
OSRC_FORCE_MKDIR_ELECTION=1
( _state_sync(){ case "$1" in *.election.pending.*) kill -STOP "$(sh -c 'echo "$PPID"')";; esac; return 0; }; _heartbeat_claim "$$" 'Thu Jul 31 01:02:03 2026' kill-election '' ) & child=$!
for _ in $(seq 1 40); do find "$OSRC_HEARTBEAT" -name '.owner.*' -path '*.election.pending.*/*' | grep -q . && break; sleep .05; done
kill -9 "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
election_pending="$(find "$OSRC_HEARTBEAT" -maxdepth 1 -type d -name '.election.pending.*' | head -1)"
[ -z "$election_pending" ] || mv "$election_pending" "$OSRC_HEARTBEAT/.election.pending.999.Thu_Jul_31_01:02:03_2026"
mkdir -p "$OSRC_HEARTBEAT/leader"; printf '%s\n' '{"pid":999,"pid_start":"Thu Jul 31 01:02:03 2026","token":"stale"}' > "$OSRC_HEARTBEAT/leader/owner.json"
_heartbeat_claim "$$" 'Thu Jul 31 01:02:03 2026' recovered '' && ok "SIGKILL during election publish recovers on next daemon" || bad "election kill window wedged startup"
rm -f "$OSRC_HEARTBEAT/leader/owner.json"; rmdir "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
( _state_sync(){ kill -STOP "$(sh -c 'echo "$PPID"')"; }; _heartbeat_publish_dir "$OSRC_HEARTBEAT/leader" 999 'Thu Jul 31 01:02:03 2026' '{"pid":999,"pid_start":"Thu Jul 31 01:02:03 2026","token":"kill-leader"}' ) & child=$!
for _ in $(seq 1 40); do find "$OSRC_HEARTBEAT" -name '.owner.*' -path '*leader.pending.*/*' | grep -q . && break; sleep .05; done
kill -9 "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
rm -f "$OSRC_HEARTBEAT/leader/owner.json"; rmdir "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
_heartbeat_claim "$$" 'Thu Jul 31 01:02:03 2026' leader-recovered '' && ok "SIGKILL during leader publish recovers on next daemon" || bad "leader kill window wedged startup"

# H1: event trace proves no durable operation follows final composer proof.
TRACE="$TMP/trace"; _external_composer_state(){ printf 'composer\n' >> "$TRACE"; echo empty; }; tmux(){ case "$1" in display-message) echo 42;; send-keys) printf 'keys\n' >> "$TRACE";; esac; }
_external_receipt_verify(){ jq -cn --arg obligation "$2" --arg endpoint "tmux:$1" --arg generation "$SESSION_CLAIM_GENERATION" '{obligation_id:$obligation,endpoint:$endpoint,generation:$generation,target_transition:true}'; }
_external_session_claim proof pane:0.0 >/dev/null; SESSION_CLAIM_TOKEN="$(jq -r .token "$OSRC_SESSION_CLAIMS/proof/owner.json")"; SESSION_CLAIM_GENERATION="$(jq -r .generation "$OSRC_SESSION_CLAIMS/proof/owner.json")"
_external_reply proof body >/dev/null && awk '/composer/{seen=1;next} seen{exit ($0=="keys")?0:1} END{if(!seen)exit 1}' "$TRACE" && ok "composer proof is immediately before typed bytes" || bad "composer proof was not last"

# H2: a SIGKILL after typing_started is converted to unknown by the scan.
_obligation_append killed proof typing_started ""; _obligation_recover_stranded
[ "$(_obligation_latest_state killed)" = delivery_unknown ] && grep -q 'obligation.killed' "$OSRC_WAKE_QUEUE" && ok "stranded typing SIGKILL is escalated" || bad "stranded typing was not recovered"

# M1: a durable controller identity still needs the matching secret capability.
SESSION_CLAIM_TOKEN=stolen; before="$(wc -l < "$TRACE")"; _external_reply proof denied >/dev/null 2>&1 || true; after="$(wc -l < "$TRACE")"
[ "$before" = "$after" ] && ok "wrong claim token sends no bytes" || bad "wrong token authorized input"

grep -q ' _managed_session_send "\$SESSION_NAME" "\$\*"' "$SRC" && ok "managed session send uses mutation endpoint path" || bad "session send bypasses mutation path"
grep -q ' _managed_session_clear "\$SESSION_NAME"' "$SRC" && grep -q ' _managed_session_model "\$SESSION_NAME"' "$SRC" && ok "manual clear and model use managed mutation paths" || bad "manual clear or model bypasses managed mutation path"
grep -q 'send-keys -t "\$pane" -l -- "\$filter"' "$SRC" && ! grep -qE 'send-keys -t "\$[A-Za-z_]+" -l "\$filter"' "$SRC" && ok "arbitrary filter text has tmux delimiter" || bad "filter delimiter missing"
grep -q '_external_receipt_valid' "$SRC" && ok "receipt is target and generation validated" || bad "receipt validation missing"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]

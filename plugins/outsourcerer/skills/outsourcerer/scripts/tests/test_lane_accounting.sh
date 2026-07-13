#!/usr/bin/env bash
# Tests the truthful lane-accounting: _effective_lane mapping (G3) + cmd_tab three-way FREE/PLAN/CASH
# bucket (G1). Sources the main script with the `main "$@"` dispatcher stripped (side-effect-free).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$HERE/../outsourcerer.sh"
[ -f "$MAIN" ] || { echo "FAIL: main script not found at $MAIN" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

# BSD/macOS mktemp: template must END in X's (no trailing suffix).
TMP="$(mktemp "${TMPDIR:-/tmp}/osrc_acct.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$MAIN" > "$TMP"
# shellcheck disable=SC1090
set +e; source "$TMP"; set -e

fail=0
ck() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "PASS: $1 -> '$2'"; else echo "FAIL: $1 -> '$2' (expected '$3')"; fail=1; fi
}

# --- A. _effective_lane (G3): native lanes fixed; open-weight follows the transport provider ---
ck "_effective_lane gm devin"    "$(_effective_lane gm devin)"    gm
ck "_effective_lane cx codex"    "$(_effective_lane cx codex)"    cx
ck "_effective_lane cc devin"    "$(_effective_lane cc devin)"    cc
ck "_effective_lane local devin" "$(_effective_lane local devin)" local
ck "_effective_lane or devin"    "$(_effective_lane or devin)"    dv
ck "_effective_lane or cc"       "$(_effective_lane or cc)"       or
ck "_effective_lane or codex"    "$(_effective_lane or codex)"    or
ck "_effective_lane '' devin"    "$(_effective_lane '' devin)"    dv
# Sol's blocker cases: the helper must MIRROR actual dispatch routing, not a provider-only guess.
ck "dv-pinned under cc (glm-5.2)"   "$(_effective_lane dv cc glm-5.2)"       dv     # Devin-pinned stays dv (regression guard)
ck "dv-pinned under codex"          "$(_effective_lane dv codex glm-5.2)"    dv
ck "--provider local beats native"  "$(_effective_lane cx local sol)"        local  # local wins over table cx
ck "ollama: prefix -> local"        "$(_effective_lane '' devin ollama:qwen)" local
ck "local: prefix -> local"         "$(_effective_lane '' cc local:foo)"     local
ck "open-weight glm via cc -> or"   "$(_effective_lane or cc glm)"           or
ck "open-weight glm via devin -> dv" "$(_effective_lane or devin glm)"       dv
# Sol re-check #2: implicit model (no -m, arg4=0) follows the PROVIDER default, not glm-5.2's dv;
# and the lms: prefix is local.
ck "implicit default + cc -> or"    "$(_effective_lane dv cc glm-5.2 0)"     or     # bare --provider cc run
ck "implicit default + codex -> or" "$(_effective_lane dv codex glm-5.2 0)"  or
ck "implicit default + devin -> dv" "$(_effective_lane dv devin glm-5.2 0)"  dv
ck "explicit glm-5.2 + cc stays dv" "$(_effective_lane dv cc glm-5.2 1)"     dv     # explicit Devin-pinned unchanged
ck "lms: prefix -> local"           "$(_effective_lane '' cc lms:qwen)"      local

# --- B. cmd_tab three-way bucket (G1). Extract the live `def bucket:` from the script so the test
#        can never drift from the real code (addresses the earlier "hand-copied classifier" finding). ---
BUCKET_DEF="$(awk '/def bucket:/{f=1} f{print} /else "cash" end;/{if(f)exit}' "$MAIN")"
[ -n "$BUCKET_DEF" ] || { echo "FAIL: could not extract 'def bucket' from script" >&2; exit 1; }
bkt() { printf '%s' "$1" | jq -r "$BUCKET_DEF (bucket)"; }
ck "bucket {lane:local}"             "$(bkt '{"lane":"local"}')"            free
ck "bucket {lane:gm}"                "$(bkt '{"lane":"gm"}')"               plan
ck "bucket {lane:cx}"                "$(bkt '{"lane":"cx"}')"               plan
ck "bucket {provider:codex-native}"  "$(bkt '{"provider":"codex-native"}')" plan
ck "bucket {provider:local}"         "$(bkt '{"provider":"local"}')"        free
ck "bucket {lane:or,cost:0.01}"      "$(bkt '{"lane":"or","cost_usd":"0.01"}')" cash
ck "bucket {lane:dv}"                "$(bkt '{"lane":"dv"}')"               cash
ck "bucket {provider:openrouter}"    "$(bkt '{"provider":"openrouter"}')"   cash

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL" >&2; exit 1; fi
echo "RESULT: PASS (all lane-accounting checks passed)"

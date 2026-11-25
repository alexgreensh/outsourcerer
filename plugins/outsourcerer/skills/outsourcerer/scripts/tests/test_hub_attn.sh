#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_hub_attn.sh -- what waits on you (lib/hub-truth.sh attention, lib/hub-assets/hub-attn.js):
#   order   one attention per lane in the order references/hub.md writes down; the project shows its highest;
#   export  a real export tags lanes and the project;
#   page    bands, tab title, favicon dot, opt-in notification, keys and merged-card ids (hub_attn_dom.js).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; LIB="$HERE/../lib"
command -v jq >/dev/null || { echo "SKIP: jq required"; exit 0; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-hub-attn.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_HUB_NO_OPEN=1 OSRC_CATALOG_VALIDATE=0 GIT_CONFIG_NOSYSTEM=1
export OSRC_JOBS="$OSRC_HOME/jobs" OSRC_CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions" OSRC_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
mkdir -p "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR" "$OSRC_JOBS" "$OSRC_HOME/hub/projects"
lib() { ( unset CLAUDE_CODE_SESSION_ID OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _reconcile_status() { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
  "$@" ); }

echo "=== order ==="
doc="$(awk '/^## Attention/{f=1; next} /^## /{f=0} f && /^[0-9]+\. `/{ sub(/^[0-9]+\. `/, ""); sub(/`.*/, ""); printf "%s ", $0 }' "$HERE/../../references/hub.md")"
code="$(OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; jq -rn "$_OSRC_HUB_DERIVE_JQ"' attn_order | join(" ")')"
[ -n "$doc" ] && [ "${doc% }" = "$code" ] && ok "references/hub.md and the export share one order: $code" || no "order: doc '$doc' code '$code'"
in='{"lanes":[{"id":"w","state":"working","status":"Building"},{"id":"r","status":"Review"},{"id":"d","status":"Merged"},{"id":"l","state":"limit"},
 {"id":"s","status":"Building"},{"id":"v","status":"Building","reviewNeedsYou":{"item":"i1"}},{"id":"f","status":"Failed"},{"id":"q","state":"question"},
 {"id":"a","state":"approval"},{"id":"p","status":"Building","proof":{"stopped":true}}],
 "alerts":[{"kind":"stalled","lane":"s","text":"x"},{"kind":"unreviewed","lane":"w","text":"y"}]}'
out="$(lib _osrc_hub_truth "$in" "$(date +%s)")"
jq -e '[.lanes[] | "\(.id)=\(.attention)"] == ["w=working","r=ready","d=finished","l=limit","s=stalled","v=review","f=failed","q=question","a=approval","p=proof"] and (has("attention") | not)' >/dev/null <<<"$out" \
  && ok "each lane gets one attention; the project carries none" || no "lanes: $(jq -c '[.lanes[]|.id+"="+.attention], .attention' <<<"$out")"

echo "=== export ==="
mkdir -p "$OSRC_HOME/owners/s-at/" "$OSRC_JOBS/j1" "$OSRC_JOBS/j2"
for j in j1:running j2:done; do : > "$OSRC_HOME/owners/s-at/${j%%:*}"; echo "${j#*:}" > "$OSRC_JOBS/${j%%:*}/status"; echo '{"provider":"codex"}' > "$OSRC_JOBS/${j%%:*}/meta.json"; done
mkdir -p "$OSRC_HOME/hub/seen/s-at"; touch "$OSRC_HOME/hub/seen/s-at/.beat"
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-at")')"
jq -e '([.lanes[] | {(.id): .attention}] | add) == {"j1":"working","j2":"finished"}' >/dev/null <<<"$c" \
  && ok "the export tags every lane" || no "export: $(jq -c '{a:.attention, l:[.lanes[]?|{id,attention}]}' <<<"$c")"

echo "=== page ==="
if command -v node >/dev/null 2>&1; then
  r="$(node "$HERE/hub_attn_dom.js" "$LIB/hub-assets" 2>&1)"; rc=$?; printf '%s\n' "$r" | grep -E '^(PASS|FAIL)'
  pass=$((pass + $(printf '%s\n' "$r" | grep -c '^PASS'))); fail=$((fail + $(printf '%s\n' "$r" | grep -c '^FAIL')))
  [ "$rc" = 0 ] || [ "$(printf '%s\n' "$r" | grep -c '^FAIL')" -gt 0 ] || no "hub_attn_dom.js exited $rc: $r"
else echo "SKIP: node not installed (page checks)"; fi
grep -q '<script src="assets/hub-attn.js"></script>' "$LIB/hub.html" && ok "the page loads assets/hub-attn.js" || no "script tag"
[ "$(wc -l < "$LIB/hub.html")" -lt 1000 ] && ok "hub.html stays under 1,000 lines" || no "hub.html is $(wc -l < "$LIB/hub.html") lines"
grep -Eq 'fetch\(|XMLHttpRequest|import\(|\.src *=' "$LIB/hub-assets/hub-attn.js" && no "hub-attn.js reaches the network" || ok "hub-attn.js makes no network call"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]

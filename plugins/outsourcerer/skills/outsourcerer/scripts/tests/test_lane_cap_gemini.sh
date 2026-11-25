#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_lane_cap_gemini.sh -- Gemini (gm) lane limits from agy probe cache and gemini->gm cap aliasing.
#   1. _session_limits reports geminiwk=2.5 and gemini5h=0.8, and nothing from the Claude/GPT group.
#   2. Stale agy probe (checked = now - 8000) emits neither gemini token.
#   3. Failed agy probe (ok: false) emits neither gemini token.
#   4. _lane_field gm conserve_windows is "gemini5h geminiwk".
#   5. osrc_lane_cap gemini 'weekly<=6' writes exactly "gm weekly<=6" to the caps file.
#   6. osrc_lane_cap gm 'weekly<=6' again leaves one line, not two.
#   7. _osrc_lane_limit gm "$(_session_limits)" prints "geminiwk=2.5".
#   8. osrc_lane_cap gemini --clear removes the gm cap.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-lane-cap-gemini.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
TEST_TMP="$TMP"; trap 'rm -rf "$TEST_TMP"' EXIT
pass=0; fail=0; ok() { echo "PASS: $1"; pass=$((pass + 1)); }; bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
HOME="$TMP/home"; OSRC_HOME="$TMP/state"; export HOME OSRC_HOME; mkdir -p "$HOME" "$OSRC_HOME"
unset CLAUDE_CODE_SESSION_ID OSRC_CC_PRESSURE OSRC_LIMITS_MAX_AGE OSRC_CAPS
set --; . "$SRC" >/dev/null 2>&1

probe_dir="$(_osrc_probe_dir)"
mkdir -p "$probe_dir"
agy_json="$probe_dir/agy.json"

write_agy() {
  local ok_val="$1" checked_val="$2"
  jq -n --argjson ok "$ok_val" --argjson checked "$checked_val" '{
    ok: $ok,
    checked: $checked,
    groups: [
      {name: "Gemini Models", windows: [{kind: "week", left: 97.5}, {kind: "5h", left: 99.2}]},
      {name: "Claude and GPT Models", windows: [{kind: "week", left: 40}]}
    ]
  }' > "$agy_json"
}

now="$(date +%s)"

# 1. Fresh ok:true probe reports geminiwk=2.5 and gemini5h=0.8, nothing from Claude/GPT group.
write_agy true "$now"
lim="$(_session_limits)"
case " $lim " in
  *" geminiwk=2.5 "*)
    case " $lim " in
      *" gemini5h=0.8 "*)
        case "$lim" in
          *60*|*claude*|*gpt*|*Claude*|*GPT*) bad "1: Claude/GPT group leaked into _session_limits: '$lim'" ;;
          *) ok "1: _session_limits reports geminiwk=2.5 and gemini5h=0.8 without Claude/GPT group" ;;
        esac ;;
      *) bad "1: missing gemini5h=0.8 in _session_limits: '$lim'" ;;
    esac ;;
  *) bad "1: missing geminiwk=2.5 in _session_limits: '$lim'" ;;
esac

# 2. Stale probe (checked = now - 8000): neither gemini token appears.
write_agy true $((now - 8000))
lim="$(_session_limits)"
case "$lim" in
  *geminiwk=*|*gemini5h=*) bad "2: stale agy probe emitted gemini tokens: '$lim'" ;;
  *) ok "2: stale agy probe (now-8000) emits neither gemini token" ;;
esac

# 3. ok:false probe: neither gemini token appears.
write_agy false "$now"
lim="$(_session_limits)"
case "$lim" in
  *geminiwk=*|*gemini5h=*) bad "3: ok:false agy probe emitted gemini tokens: '$lim'" ;;
  *) ok "3: ok:false agy probe emits neither gemini token" ;;
esac

# 4. _lane_field gm conserve_windows is "gemini5h geminiwk".
cw="$(_lane_field gm conserve_windows 2>/dev/null)"
[ "$cw" = "gemini5h geminiwk" ] \
  && ok "4: _lane_field gm conserve_windows is 'gemini5h geminiwk'" \
  || bad "4: expected 'gemini5h geminiwk', got '$cw'"

# 5. osrc_lane_cap gemini 'weekly<=6' succeeds and writes exactly "gm weekly<=6".
cf="$(_lane_caps_file)"
if ( osrc_lane_cap gemini 'weekly<=6' ) >/dev/null 2>&1 \
  && [ -f "$cf" ] && [ "$(cat "$cf")" = "gm weekly<=6" ] && [ "$(wc -l < "$cf" | tr -d ' ')" = "1" ]; then
  ok "5: osrc_lane_cap gemini 'weekly<=6' writes exactly 'gm weekly<=6'"
else
  bad "5: osrc_lane_cap gemini 'weekly<=6' failed or caps file mismatch: '$(cat "$cf" 2>/dev/null)'"
fi

# 6. osrc_lane_cap gm 'weekly<=6' again leaves one line, not two.
if ( osrc_lane_cap gm 'weekly<=6' ) >/dev/null 2>&1 \
  && [ -f "$cf" ] && [ "$(cat "$cf")" = "gm weekly<=6" ] && [ "$(wc -l < "$cf" | tr -d ' ')" = "1" ]; then
  ok "6: osrc_lane_cap gm 'weekly<=6' replaces in place, leaving one line"
else
  bad "6: osrc_lane_cap gm 'weekly<=6' failed or left wrong caps file: '$(cat "$cf" 2>/dev/null)'"
fi

# 7. _osrc_lane_limit gm "$(_session_limits)" prints geminiwk=2.5.
write_agy true "$now"
ll="$(_osrc_lane_limit gm "$(_session_limits)" 2>/dev/null)"
[ "$ll" = "geminiwk=2.5" ] \
  && ok "7: _osrc_lane_limit gm prints geminiwk=2.5" \
  || bad "7: expected 'geminiwk=2.5', got '$ll'"

# 8. osrc_lane_cap gemini --clear removes the gm cap.
grep -q '^gm ' "$cf" 2>/dev/null || printf 'gm weekly<=6\n' > "$cf"
if ( osrc_lane_cap gemini --clear ) >/dev/null 2>&1 \
  && { [ ! -f "$cf" ] || ! grep -q '^gm ' "$cf"; }; then
  ok "8: osrc_lane_cap gemini --clear removes the gm cap"
else
  bad "8: osrc_lane_cap gemini --clear failed or gm cap remains: '$(cat "$cf" 2>/dev/null)'"
fi

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]

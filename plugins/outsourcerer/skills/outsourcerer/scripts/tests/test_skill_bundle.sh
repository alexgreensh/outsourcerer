#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_sandbox.sh" || { echo "FAIL: sandbox library" >&2; exit 1; }
osrc_test_sandbox || { echo "FAIL: sandbox" >&2; exit 1; }
# test_skill_bundle.sh — a granted skill must transfer WHOLE, per lane capability, or not at all.
#
# The gaps this locks out (all verified on 0.13.0):
#   - `--with skills=x` pasted only SKILL.md (capped 20KB) into the prompt; references/, scripts/,
#     assets/ never transferred.
#   - The Devin lane parsed --with skills= and silently discarded it.
#   - `--with mcp=x` was honored only on the Claude CLI lanes and silently ignored everywhere else.
#   - There was no `skills=all`.
#
# Transports under test: bundle (host-tool lanes), text (text-only lanes), devin (skills-home
# sync), inline (legacy default). Plus the mcp guard and the bundle/text size caps.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"   # sourcing outsourcerer.sh re-points SCRIPT_DIR at scripts/; keep ours
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; rm -rf "$OSRC_TEST_ROOT"' EXIT
SUITE_ERR="$TMP/suite-stderr.txt"
exec 9>&2 2>"$SUITE_ERR"   # watchdog: the suite's own stderr must stay EMPTY
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1
for fn in _resolve_skill_dir _list_all_skills _with_skill_names _with_mcp_requested \
          _skill_bundle_build _with_preamble_render _devin_with_prepare; do
  type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded"; exit 1; }
done

# --- fixture: a full skill tree + a plugin-cache skill, in an isolated HOME ---------------------
SK="$TMP/home/.claude/skills/confskill"
mkdir -p "$SK/references" "$SK/scripts" "$SK/assets" \
         "$TMP/home/.claude/plugins/cache/mkt/plug/1.0.0/skills/plugskill"
printf '# confskill\nRead references/r.md and run scripts/x.sh.\n' > "$SK/SKILL.md"
printf 'reference-doc-body\n'  > "$SK/references/r.md"
printf '#!/bin/sh\necho SCRIPT-MARKER-7f3a\n' > "$SK/scripts/x.sh"
printf 'asset-blob\n'           > "$SK/assets/a.txt"
printf '# plugskill\n'          > "$TMP/home/.claude/plugins/cache/mkt/plug/1.0.0/skills/plugskill/SKILL.md"

HOME_REAL="$HOME"; HOME="$TMP/home"
export OSRC_HOME="$TMP/osrc"; mkdir -p "$OSRC_HOME"; unset OSRC_JOB_DIR 2>/dev/null || true

# --- 1. directory resolution ---------------------------------------------------------------------
d="$(_resolve_skill_dir confskill 2>/dev/null)"
[ "$d" = "$SK" ] && ok "_resolve_skill_dir returns the skill's whole directory" \
                 || bad "_resolve_skill_dir returned '$d'"
d="$(_resolve_skill_dir plugskill 2>/dev/null)"
case "$d" in *plugins/cache*plugskill) ok "plugin-cache skill directory resolves" ;;
  *) bad "plugin-cache skill directory did not resolve: '$d'" ;; esac

# --- 2. skills=all expansion ---------------------------------------------------------------------
names="$(WITH_SPEC='skills=all' _with_skill_names 2>/dev/null)"
grep -qx 'confskill' <<<"$names" && grep -qx 'plugskill' <<<"$names" \
  && ok "skills=all expands across the user dir and the plugin caches" \
  || bad "skills=all expansion wrong: $names"
names="$(WITH_SPEC='skills=confskill,plugskill' _with_skill_names 2>/dev/null)"
[ "$(printf '%s\n' "$names" | grep -c .)" = "2" ] && ok "a comma list expands to exactly its names" \
  || bad "comma list expansion wrong: $names"

# --- 3. bundle build: the WHOLE tree transfers, with a manifest ----------------------------------
WITH_SPEC='skills=confskill' _skill_bundle_build "$OSRC_HOME/skill-bundle" confskill >/dev/null 2>&1
B="$OSRC_HOME/skill-bundle/confskill"
[ -f "$B/SKILL.md" ] && [ -f "$B/references/r.md" ] && [ -f "$B/scripts/x.sh" ] && [ -f "$B/assets/a.txt" ] \
  && ok "bundle holds SKILL.md + references/ + scripts/ + assets/ (the whole tree)" \
  || bad "bundle is incomplete: $(find "$OSRC_HOME/skill-bundle" -type f 2>/dev/null | tr '\n' ' ')"
M="$OSRC_HOME/skill-bundle/MANIFEST.txt"
grep -q '^skill=confskill .*scripts=1 assets=1 references=1\|^skill=confskill .*references=1 scripts=1 assets=1' "$M" \
  && ok "manifest flags references/scripts/assets presence" \
  || bad "manifest capability flags wrong: $(grep '^skill=' "$M")"
grep -q '^file=confskill/scripts/x.sh bytes=' "$M" \
  && ok "manifest lists per-file sizes" || bad "manifest missing per-file entries"

# --- 4. bundle byte cap dies LOUD ----------------------------------------------------------------
err="$( ( WITH_SPEC='skills=confskill' OSRC_BUNDLE_MAX_BYTES=10 _skill_bundle_build "$OSRC_HOME/sb2" confskill ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *OSRC_BUNDLE_MAX_BYTES*) ok "an oversized bundle dies naming the cap knob" ;;
  *) bad "bundle cap death does not name the knob: $err" ;; esac
[ "$rc" -ne 0 ] || bad "an oversized bundle was silently built"

# --- 5. bundle preamble: path + manifest; a missing skill FAILS the dispatch -----------------------
out="$(WITH_SPEC='skills=confskill' _with_preamble_render bundle 2>/dev/null; printf '%s' "${WITH_PRE_OUT:-}")"
grep -Eq "$OSRC_HOME/skill-bundle\.[0-9]+\.[0-9]+/confskill/" <<<"$out" && grep -q 'MANIFEST.txt' <<<"$out" \
  && ok "bundle preamble points at the on-disk bundle and its manifest" \
  || bad "bundle preamble missing root/manifest: $out"
err="$( ( WITH_SPEC='skills=confskill,ghostskill' _with_preamble_render bundle ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NOT FOUND"*"ghostskill"*) ok "a missing granted skill FAILS the dispatch, naming the skill" ;;
  *) bad "missing-skill death does not name the skill: $err" ;; esac
[ "$rc" -ne 0 ] || bad "a missing granted skill rendered rc=0 - the delegate would run without it"

# --- 6. text preamble: full text in, scripts/assets honestly out ---------------------------------
out="$(WITH_SPEC='skills=confskill' _with_preamble_render text 2>/dev/null; printf '%s' "${WITH_PRE_OUT:-}")"
err="$( ( WITH_SPEC='skills=confskill' _with_preamble_render text ) 2>&1 >/dev/null )"
case "$out" in *"=== INJECTED SKILL FILE: confskill/SKILL.md"*) ok "text preamble carries SKILL.md with an explicit boundary" ;;
  *) bad "SKILL.md boundary missing: $out" ;; esac
case "$out" in *"=== INJECTED SKILL FILE: confskill/references/r.md"*"reference-doc-body"*) ok "text preamble carries the references/ docs too" ;;
  *) bad "references doc missing from text preamble" ;; esac
case "$out" in *SCRIPT-MARKER-7f3a*) bad "a script's BODY leaked into the text-only prompt" ;;
  *) ok "script bodies are not pasted into a text-only prompt" ;; esac
case "$out" in *"NOT TRANSFERRED"*"scripts/x.sh"*) ok "scripts/assets are called out as NOT TRANSFERRED, not silently dropped" ;;
  *) bad "non-text files not called out: $out" ;; esac
case "$err" in *"text-only lane"*) ok "the caller is warned that scripts cannot run on a text-only lane" ;;
  *) bad "no stderr warning about non-text files: $err" ;; esac

# --- 7. text cap: hard REFUSE (no silent truncation), naming the file and the knob ----------------
out="$( ( WITH_SPEC='skills=confskill' OSRC_WITH_TEXT_MAX_BYTES=30 _with_preamble_render text ) 2>/dev/null; printf '%s' "${WITH_PRE_OUT:-}")"
err="$( ( WITH_SPEC='skills=confskill' OSRC_WITH_TEXT_MAX_BYTES=30 _with_preamble_render text ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && ok "an over-cap text grant dies instead of truncating" || bad "an over-cap text grant silently rendered"
case "$err" in *OSRC_WITH_TEXT_MAX_BYTES=30*) ok "the refusal names the cap knob and its value" ;;
  *) bad "refusal does not name the knob: $err" ;; esac
case "$err" in *"confskill/"*"pushes it over"*) ok "the refusal names the exact file that overflows" ;;
  *) bad "refusal does not name the overflowing file: $err" ;; esac
case "$err" in *"no silent truncation"*|*"COMPLETE skill text or REFUSE"*) ok "the refusal states the no-truncation rule" ;;
  *) bad "refusal lacks the no-truncation rule: $err" ;; esac
[ -z "$out" ] && ok "a refused text grant injects NOTHING (no partial capability)" \
  || bad "a refused text grant still produced a preamble: $out"

# --- 7b. the cap counts EVERY serialized byte (boundaries + filenames), not just payloads --------
# 800 zero-byte long-named docs: payload ~0 bytes, serialized form ~230KB. Payload-only accounting
# used to wave this through at 2x the cap; exact accounting must refuse it.
MANY="$TMP/home/.claude/skills/manyskill"
mkdir -p "$MANY/references"
printf '# manyskill\n' > "$MANY/SKILL.md"
i=1; while [ "$i" -le 800 ]; do
  : > "$MANY/references/a-rather-long-file-name-to-inflate-the-boundary-overhead-$(printf '%04d' "$i").md"
  i=$((i+1))
done
err="$( ( WITH_SPEC='skills=manyskill' _with_preamble_render text ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *OSRC_WITH_TEXT_MAX_BYTES*) ok "boundary/filename overhead is counted against the cap (800 empty files die)" ;;
  *) bad "overhead death does not name the knob: $err" ;; esac
[ "$rc" -ne 0 ] || bad "800 zero-byte files slipped past the cap on boundary overhead"

# --- 7c. symlink containment: an escaping link refuses the grant; an inside link stages -----------
ESC="$TMP/home/.claude/skills/escskill"; mkdir -p "$ESC/references"
printf '# escskill\n' > "$ESC/SKILL.md"
ln -s /etc/passwd "$ESC/references/outside-link"
err="$( ( WITH_SPEC='skills=escskill' _skill_bundle_build "$OSRC_HOME/sb-esc" escskill ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && ok "a symlink escaping the skill dir refuses the bundle" \
  || bad "an escaping symlink was silently staged"
case "$err" in *"outside-link"*"OUTSIDE the bundle"*|*"outside-link"*"escapes"*) ok "the escape refusal names the offending link" ;;
  *) bad "escape refusal lacks the link name: $err" ;; esac
[ ! -e "$OSRC_HOME/sb-esc/escskill/references/outside-link" ] && ok "a refused bundle stages nothing followable" \
  || bad "the escaping link was staged on disk"
LINKSK="$TMP/home/.claude/skills/linkskill"; mkdir -p "$LINKSK/references"
printf '# linkskill\n' > "$LINKSK/SKILL.md"
ln -s ../SKILL.md "$LINKSK/references/inner-link"
( WITH_SPEC='skills=linkskill' _skill_bundle_build "$OSRC_HOME/sb-link" linkskill ) >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -L "$OSRC_HOME/sb-link/linkskill/references/inner-link" ] \
  && ok "a symlink that stays inside the skill is staged, not refused" \
  || bad "an inside symlink was wrongly refused (rc=$rc)"
grep -q '^link=linkskill/references/inner-link target=\.\./SKILL.md' "$OSRC_HOME/sb-link/MANIFEST.txt" 2>/dev/null \
  && ok "the manifest accounts staged symlinks and their targets" \
  || bad "manifest lacks link accounting: $(grep -c '^link=' "$OSRC_HOME/sb-link/MANIFEST.txt" 2>/dev/null) link lines"

# --- 7d. skill names with spaces / unicode ---------------------------------------------------------
SPC="$TMP/home/.claude/skills/space ünicode"; mkdir -p "$SPC"
printf '# spaced skill\n' > "$SPC/SKILL.md"
( WITH_SPEC='' ; _validate_with_token 'skills=space ünicode' ) >/dev/null 2>&1 \
  && ok "a spaced unicode skill name passes --with validation" \
  || bad "a spaced unicode skill name was rejected by validation"
( _validate_with_token 'skills=../evil' ) >/dev/null 2>&1 \
  && bad "a traversal skill name passed validation" || ok "a traversal skill name still dies at validation"
( _validate_with_token 'skills=a,b /tmp/brief.txt' ) >/dev/null 2>&1 \
  && bad "a bare trailing file path passed validation" || ok "a bare trailing file path still dies at validation"
names="$(WITH_SPEC='skills=space ünicode,confskill' _with_skill_names 2>/dev/null)"
grep -qx 'space ünicode' <<<"$names" && grep -qx 'confskill' <<<"$names" \
  && ok "spaced names expand whole, not split on whitespace" \
  || bad "spaced name expansion wrong: $names"
out="$(WITH_SPEC='skills=space ünicode' _with_preamble_render bundle 2>/dev/null; printf '%s' "${WITH_PRE_OUT:-}")"
grep -Eq "space ünicode: $OSRC_HOME/skill-bundle\.[0-9]+\.[0-9]+/space ünicode/" <<<"$out" \
  && ok "a spaced unicode skill bundles end-to-end" \
  || bad "spaced skill did not bundle: $out"
{ _t3b_pipe="$(find "$OSRC_HOME" -path "*skill-bundle.*/space ünicode/SKILL.md")" && grep -q . <<<"$_t3b_pipe"; } \
  && ok "the spaced skill's tree is on disk under its real name" \
  || bad "spaced skill tree missing on disk"

# --- 8. mcp guard: dies on lanes that cannot honor it ---------------------------------------------
( WITH_SPEC='mcp=slack' _with_preamble_render bundle ) >/dev/null 2>&1 \
  && bad "mcp= was accepted on a bundle lane that cannot honor it" \
  || ok "mcp= on a non-Claude bundle lane dies instead of silently dispatching"
err="$( ( WITH_SPEC='mcp=slack' _with_preamble_render bundle ) 2>&1 >/dev/null )"
case "$err" in *"Claude CLI lanes"*"--provider cc"*) ok "the mcp refusal names the working lanes and route" ;;
  *) bad "mcp refusal lacks guidance: $err" ;; esac
( WITH_SPEC='mcp=slack' _with_preamble_render text ) >/dev/null 2>&1 \
  && bad "mcp= was accepted on a text-only lane" || ok "mcp= on a text-only lane dies"
( WITH_SPEC='mcp=slack' _with_preamble_render bundle+mcp ) >/dev/null 2>&1 \
  && ok "mcp= stays honored on the Claude CLI lanes" || bad "mcp= wrongly refused on bundle+mcp"
( WITH_SPEC='mcp=slack' _with_preamble_render ) >/dev/null 2>&1 \
  && ok "legacy inline path keeps its old mcp behavior" || bad "legacy inline path changed behavior"

# --- 9. devin prepare: per-dispatch sync into the skills home --------------------------------------
DEVIN_WITH_PRE=""
WITH_SPEC='skills=confskill'; _devin_with_prepare >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ -L "$TMP/home/.config/devin/skills/confskill" ] && [ -e "$TMP/home/.config/devin/skills/confskill/SKILL.md" ] \
  && ok "devin sync links the granted skill's whole directory into the Devin skills home" \
  || bad "devin sync did not produce a resolving link (rc=$rc)"
case "$DEVIN_WITH_PRE" in *"FULL directory contents"*confskill*) ok "the Devin prompt says exactly what arrived" ;;
  *) bad "Devin preamble missing/wrong: $DEVIN_WITH_PRE" ;; esac
( WITH_SPEC='mcp=slack' _devin_with_prepare ) >/dev/null 2>&1 \
  && bad "mcp= was accepted on the Devin lane" || ok "mcp= on the Devin lane dies"
_devin_skills_lock_release   # simulate the process boundary a real dispatch ends with
err="$( ( WITH_SPEC='skills=ghostskill' _devin_with_prepare ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"ghostskill"*"NOT FOUND"*) ok "a missing skill on the Devin lane FAILS the dispatch, not silently skipped" ;;
  *) bad "missing Devin-lane skill death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "a missing Devin-lane skill dispatched rc=0"

# --- 10. legacy default is untouched ----------------------------------------------------------------
out="$(WITH_SPEC='skills=confskill' build_with_preamble 2>/dev/null)"
case "$out" in *"=== INJECTED SKILL: confskill ==="*) ok "no transport arg keeps the legacy inline injection" ;;
  *) bad "legacy inline behavior changed: $out" ;; esac

# ============================================================================
# LAYER 2: BEHAVIORAL dispatch through a real delegate (fake-bin/cline on PATH).
# Unit checks above prove the renderers; this proves a lane's dispatched PROMPT actually carries
# the bundle, and that an unhonorable mcp= grant kills the dispatch BEFORE any CLI launches.
# ============================================================================
CAPTURE="$TMP/cline_capture.txt"
export OSRC_CLINE_FAKE_CAPTURE="$CAPTURE"
FAKE_PATH="$TESTS_DIR/fake-bin"
REST=("do the thing"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC='skills=confskill'
rm -f "$CAPTURE"
( PATH="$FAKE_PATH:$PATH" delegate_cline auto ) >/dev/null 2>&1 || true
grep -Eq 'skill-bundle\.[0-9]+\.[0-9]+/confskill' "$CAPTURE" 2>/dev/null \
  && ok "a tool-lane dispatch carries the on-disk bundle path in its prompt" \
  || bad "dispatched prompt lacks the bundle path: $(head -c 200 "$CAPTURE" 2>/dev/null)"
[ -n "$(find "$OSRC_HOME" -path '*skill-bundle.*/confskill/references/r.md' 2>/dev/null)" ] \
  && [ -n "$(find "$OSRC_HOME" -path '*skill-bundle.*/confskill/scripts/x.sh' 2>/dev/null)" ] \
  && ok "the dispatch staged the skill's whole tree (references + scripts) on disk" \
  || bad "dispatch-time bundle is incomplete"
grep -q 'MANIFEST.txt' "$CAPTURE" 2>/dev/null \
  && ok "the dispatched prompt points at the bundle manifest" || bad "dispatched prompt lacks the manifest pointer"

# mcp= on this lane must die BEFORE the CLI launches (no capture line may be written).
REST=("do the thing"); WITH_SPEC='mcp=slack'
rm -f "$CAPTURE"
( PATH="$FAKE_PATH:$PATH" delegate_cline auto ) >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$CAPTURE" ] \
  && ok "mcp= on a non-Claude lane kills the dispatch before any CLI launch" \
  || bad "mcp= dispatch reached the CLI or exited 0 (rc=$rc, capture: $(cat "$CAPTURE" 2>/dev/null))"

# --- 11. concurrent A/B dispatch: unique immutable roots, no mid-run yank -------------------------
WITH_SPEC='skills=confskill' _with_preamble_render bundle >/dev/null 2>&1; outA="$WITH_PRE_OUT"
WITH_SPEC='skills=plugskill' _with_preamble_render bundle >/dev/null 2>&1; outB="$WITH_PRE_OUT"
rootA="$(printf '%s' "$outA" | grep -oE "$OSRC_HOME/skill-bundle\.[0-9]+\.[0-9]+" | head -1)"
rootB="$(printf '%s' "$outB" | grep -oE "$OSRC_HOME/skill-bundle\.[0-9]+\.[0-9]+" | head -1)"
[ -n "$rootA" ] && [ -n "$rootB" ] && [ "$rootA" != "$rootB" ] \
  && ok "two dispatches get two distinct bundle roots" \
  || bad "bundle roots collide or missing: A='$rootA' B='$rootB'"
[ -f "$rootA/confskill/SKILL.md" ] && [ -f "$rootB/plugskill/SKILL.md" ] \
  && ok "dispatch B's build leaves dispatch A's bundle fully intact" \
  || bad "dispatch B clobbered dispatch A's bundle"
( WITH_SPEC='skills=confskill' _with_preamble_render bundle >/dev/null 2>&1 ) & p1=$!
( WITH_SPEC='skills=plugskill' _with_preamble_render bundle >/dev/null 2>&1 ) & p2=$!
wait $p1 $p2
n_intact="$(find "$OSRC_HOME" -path '*skill-bundle.*/confskill/SKILL.md' | wc -l | tr -d ' ')"
[ "${n_intact:-0}" -ge 1 ] && ok "parallel bundle builds complete without corrupting each other" \
  || bad "parallel bundle builds corrupted the trees"

# --- 12. exact final serialized byte length vs the cap --------------------------------------------
WITH_SPEC='skills=confskill' OSRC_WITH_TEXT_MAX_BYTES=1000000 _with_preamble_render text >/dev/null 2>&1
exact="$(printf '%s' "${WITH_PRE_OUT:-}" | wc -c | tr -d ' ')"
( WITH_SPEC='skills=confskill' OSRC_WITH_TEXT_MAX_BYTES="$exact" _with_preamble_render text ) >/dev/null 2>&1 \
  && ok "a payload at EXACTLY the cap transfers whole" \
  || bad "a payload at exactly the cap was refused"
err="$( ( WITH_SPEC='skills=confskill' OSRC_WITH_TEXT_MAX_BYTES=$((exact - 1)) _with_preamble_render text ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *OSRC_WITH_TEXT_MAX_BYTES*) ok "one byte over the cap dies, naming the knob" ;;
  *) bad "cap-1 death lacks the knob: $err" ;; esac
[ "$rc" -ne 0 ] || bad "cap-1 payload silently transferred"

# --- 13. MCP grants: absent server / missing config dies BEFORE launch ------------------------------
if have jq; then
  mkdir -p "$TMP/home2"
  printf '{"mcpServers":{"realsrv":{"command":"x"}},"projects":{}}' > "$TMP/home2/.claude.json"
  err="$( ( HOME="$TMP/home2" WITH_SPEC='mcp=ghostsrv' build_mcp_flags_cc ) 2>&1 >/dev/null )"
  rc=$?
  [ "$rc" -ne 0 ] && case "$err" in *ghostsrv*"not found"*) ok "an absent mcp= server fails pre-launch, naming it" ;;
    *) bad "absent-server death lacks the name: $err" ;; esac
  [ "$rc" -ne 0 ] || bad "an absent mcp= server produced rc=0 (silent empty config)"
  ( HOME="$TMP/home2" WITH_SPEC='mcp=realsrv' build_mcp_flags_cc ) >/dev/null 2>&1 \
    && ok "a present mcp= server resolves into the strict config" \
    || bad "a present mcp= server was refused"
  jq -e '.mcpServers | has("realsrv")' "$TMP/osrc/with-mcp-$$.json" >/dev/null 2>&1 \
    && ok "the generated strict config carries exactly the granted server" \
    || bad "generated strict config wrong: $(cat "$TMP/osrc"/with-mcp-*.json 2>/dev/null | head -c 120)"
  err="$( ( HOME="$TMP/nohome" WITH_SPEC='mcp=realsrv' build_mcp_flags_cc ) 2>&1 >/dev/null )"
  rc=$?
  [ "$rc" -ne 0 ] && case "$err" in *"no ~/.claude.json"*) ok "mcp= with no ~/.claude.json dies instead of an empty config" ;;
    *) bad "missing-config death wrong: $err" ;; esac
  [ "$rc" -ne 0 ] || bad "mcp= with no ~/.claude.json silently produced an empty config"
  # Repeated mcp= specs COMBINE: the old tail -1 silently dropped every server but the last.
  mkdir -p "$TMP/home3"
  printf '{"mcpServers":{"one":{"command":"x"},"two":{"command":"y"}},"projects":{}}' > "$TMP/home3/.claude.json"
  # Behavioral: the exact CLI path - _consume_flags appends each --with to WITH_SPEC.
  HOME_SAVE="$HOME"; HOME="$TMP/home3"
  _consume_flags --with 'mcp=one' --with 'mcp=two' run "task"
  case "$WITH_SPEC" in *"mcp=one"*"mcp=two"*) ok "repeated --with flags append both mcp= specs to WITH_SPEC" ;;
    *) bad "_consume_flags did not append repeated --with: '$WITH_SPEC'" ;; esac
  err="$(build_mcp_flags_cc 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && jq -e '.mcpServers | has("one") and has("two") and (length == 2)' "$TMP/osrc/with-mcp-$$.json" >/dev/null 2>&1 \
    && ok "repeated --with mcp= flags grant BOTH servers, exactly those two" \
    || bad "repeated mcp= flags did not carry both servers (rc=$rc, $err): $(cat "$TMP/osrc"/with-mcp-*.json 2>/dev/null | head -c 160)"
  HOME="$HOME_SAVE"; WITH_SPEC=""
  # Mixed skills=/mcp= orders keep every server.
  ( HOME="$TMP/home3" WITH_SPEC='skills=confskill mcp=one mcp=two' build_mcp_flags_cc ) >/dev/null 2>&1 \
    && jq -e '.mcpServers | has("one") and has("two") and (length == 2)' "$TMP/osrc/with-mcp-$$.json" >/dev/null 2>&1 \
    && ok "skills= before repeated mcp= keeps both servers" || bad "skills-first order lost a server"
  ( HOME="$TMP/home3" WITH_SPEC='mcp=one skills=confskill mcp=two' build_mcp_flags_cc ) >/dev/null 2>&1 \
    && jq -e '.mcpServers | has("one") and has("two") and (length == 2)' "$TMP/osrc/with-mcp-$$.json" >/dev/null 2>&1 \
    && ok "mcp= split around skills= keeps both servers" || bad "split mcp= order lost a server"
  # Duplicates dedupe; a ghost in ANY repeated spec still fails pre-launch, naming it.
  ( HOME="$TMP/home3" WITH_SPEC='mcp=one mcp=one,two' build_mcp_flags_cc ) >/dev/null 2>&1 \
    && jq -e '.mcpServers | length == 2' "$TMP/osrc/with-mcp-$$.json" >/dev/null 2>&1 \
    && ok "duplicate mcp names across repeated specs dedupe" || bad "duplicates produced a wrong config"
  err="$( ( HOME="$TMP/home3" WITH_SPEC='mcp=one mcp=ghostsrv' build_mcp_flags_cc ) 2>&1 >/dev/null )"; rc=$?
  [ "$rc" -ne 0 ] && case "$err" in *ghostsrv*"not found"*) ok "a ghost server in ANY repeated mcp= spec fails pre-launch, naming it" ;;
    *) bad "repeated-spec ghost death wrong: $err" ;; esac
  [ "$rc" -ne 0 ] || bad "a ghost server in a repeated mcp= spec launched rc=0"
else
  echo "SKIP: jq absent - mcp resolution tests skipped"
fi

# --- 14. Devin A-then-B: the skills home holds EXACTLY the current grant ----------------------------
rm -rf "$TMP/home/.config/devin/skills"
WITH_SPEC='skills=confskill' _devin_with_prepare >/dev/null 2>&1
[ -L "$TMP/home/.config/devin/skills/confskill" ] || bad "devin A-grant link missing for the leakage test"
WITH_SPEC='skills=plugskill' _devin_with_prepare >/dev/null 2>&1
[ ! -e "$TMP/home/.config/devin/skills/confskill" ] && [ -L "$TMP/home/.config/devin/skills/plugskill" ] \
  && ok "devin B-dispatch removes A's stale link and keeps only B" \
  || bad "devin A-then-B leaks A's link (or lost B's)"
case "$DEVIN_WITH_PRE" in *plugskill*) ;; *) bad "devin B prompt lacks plugskill" ;; esac
case "$DEVIN_WITH_PRE" in *confskill*) bad "devin B prompt still claims confskill" ;;
  *) ok "devin B prompt claims only B" ;; esac

# --- 15. a flood of missing skills dies on the FIRST name (nothing renders past a failed grant) ----
flood=""
i=1; while [ "$i" -le 1400 ]; do flood="${flood}ghost-a-rather-long-nonexistent-skill-name-$(printf '%04d' "$i"),"; i=$((i+1)); done
flood="${flood%,}"
err="$( ( WITH_SPEC="skills=$flood" OSRC_WITH_TEXT_MAX_BYTES=100000 _with_preamble_render text ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NOT FOUND"*FAILS*) ok "1,400 missing skills die at the first name instead of rendering on" ;;
  *) bad "flood death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "1,400 missing skills rendered rc=0"

# --- 16. byte-faithful text transfer (trailing newlines survive) -----------------------------------
TR="$TMP/home/.claude/skills/trailskill"; mkdir -p "$TR/references"
printf '# trailskill\n' > "$TR/SKILL.md"
printf 'alpha\n\n\n' > "$TR/references/t.md"
printf 'beta' > "$TR/references/u.md"
WITH_SPEC='skills=trailskill' _with_preamble_render text >/dev/null 2>&1
case "$WITH_PRE_OUT" in *"alpha"*"=== END SKILL FILE: trailskill/references/t.md ==="*) : ;; *) bad "t.md chunk missing" ;; esac
chk="$(printf '%s' "$WITH_PRE_OUT" | awk '/INJECTED SKILL FILE: trailskill\/references\/t.md/{f=1;next} /END SKILL FILE: trailskill\/references\/t.md/{f=0} f' | wc -c | tr -d ' ')"
[ "$chk" = "9" ] && ok "trailing newlines are byte-faithful (alpha\\n\\n\\n + 1 framing newline = 9 bytes)" \
  || bad "trailing newlines mangled: chunk body is $chk bytes, want 9"
case "$WITH_PRE_OUT" in *"beta
=== END SKILL FILE: trailskill/references/u.md ==="*) ok "a file with no trailing newline gets exactly one framing newline before END" ;;
  *) bad "no-trailing-newline framing wrong" ;; esac

# --- 17. spaced Devin grant renders as ONE grant ---------------------------------------------------
rm -rf "$TMP/home/.config/devin/skills"
WITH_SPEC='skills=space ünicode' _devin_with_prepare >/dev/null 2>&1
case "$DEVIN_WITH_PRE" in *"  space ünicode ($TMP/home/.config/devin/skills/space ünicode)"*) ok "a spaced Devin grant renders whole, on one line" ;;
  *) bad "spaced Devin grant mis-rendered: $DEVIN_WITH_PRE" ;; esac
case "$DEVIN_WITH_PRE" in *"  ünicode "*) bad "spaced Devin grant split into a phantom second grant" ;;
  *) ok "no phantom split grant in the Devin prompt" ;; esac

# --- 18. planted marker symlink is never followed ---------------------------------------------------
VICTIM="$TMP/victim.txt"; printf 'precious\n' > "$VICTIM"
rm -rf "$TMP/home/.config/devin/skills"; mkdir -p "$TMP/home/.config/devin/skills"
ln -s "$VICTIM" "$TMP/home/.config/devin/skills/.outsourcerer-grants"
WITH_SPEC='skills=confskill' _devin_with_prepare >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$VICTIM")" = "precious" ] && ok "a planted marker symlink is removed, never followed (victim intact)" \
  || bad "marker symlink clobbered the victim or died (rc=$rc, victim: $(cat "$VICTIM" 2>/dev/null))"
[ -f "$TMP/home/.config/devin/skills/.outsourcerer-grants" ] && [ ! -L "$TMP/home/.config/devin/skills/.outsourcerer-grants" ] \
  && ok "the marker is rewritten as a regular file" || bad "marker still a symlink or missing"
_devin_skills_lock_release

# --- 19. NUL bytes in a text-classified file refuse the grant --------------------------------------
NUL="$TMP/home/.claude/skills/nulskill"; mkdir -p "$NUL/references"
printf '# nulskill\n' > "$NUL/SKILL.md"
printf 'before\0after\n' > "$NUL/references/n.md"
err="$( ( WITH_SPEC='skills=nulskill' _with_preamble_render text ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && ok "a NUL-bearing .md dies instead of silently dropping bytes" \
  || bad "NUL bytes were silently dropped (rc=0, corrupted grant)"
case "$err" in *"nulskill/references/n.md"*NUL*) ok "the NUL refusal names the exact file" ;;
  *) bad "NUL refusal lacks the filename: $err" ;; esac

# --- 20. pre-planted temp symlinks are never followed (marker write) --------------------------------
V2="$TMP/victim2.txt"; printf 'precious2\n' > "$V2"
rm -rf "$TMP/home/.config/devin/skills"; mkdir -p "$TMP/home/.config/devin/skills"
for n in 1 2 3 4 5; do ln -s "$V2" "$TMP/home/.config/devin/skills/.outsourcerer-grants.tmp.preplant$n"; done
WITH_SPEC='skills=confskill' _devin_with_prepare >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$V2")" = "precious2" ] \
  && ok "pre-planted temp symlinks are never followed (victim intact)" \
  || bad "a temp symlink was followed (rc=$rc, victim: $(cat "$V2" 2>/dev/null))"
[ -f "$TMP/home/.config/devin/skills/.outsourcerer-grants" ] && [ ! -L "$TMP/home/.config/devin/skills/.outsourcerer-grants" ] \
  && ok "marker still lands as a regular file beside the planted links" || bad "marker missing after pre-plant test"
_devin_skills_lock_release

# --- 21. CR/LF in filenames: refused at every staging point, never rc=0-with-errors -----------------
NLSK="$TMP/home/.claude/skills/nlskill"; mkdir -p "$NLSK/references"
printf '# nlskill\n' > "$NLSK/SKILL.md"
printf 'x\n' > "$NLSK/references/line
break.md"
err="$( ( WITH_SPEC='skills=nlskill' _skill_bundle_build "$OSRC_HOME/sb-nl" nlskill ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *CR*LF*|*"newlines in names"*) ok "a newline in a filename refuses the bundle, naming the rule" ;;
  *) bad "newline-name bundle death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "a newline-named file staged rc=0 with a corrupt manifest"
err="$( ( WITH_SPEC='skills=nlskill' _with_preamble_render text ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && ok "a newline in a filename refuses the text render" \
  || bad "newline-named file rendered rc=0 (fake empty file + NOT TRANSFERRED split)"
err="$( ( WITH_SPEC='skills=nlskill' _devin_with_prepare ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && ok "a newline in a filename refuses the Devin grant" \
  || bad "newline-named file passed Devin prepare rc=0"
_devin_skills_lock_release 2>/dev/null

# --- 22. concurrent Devin dispatches serialize: state and marker always agree -----------------------
i=1; agree=1
while [ "$i" -le 10 ]; do
  rm -rf "$TMP/home/.config/devin/skills"
  ( WITH_SPEC='skills=confskill' _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release ) &
  ( WITH_SPEC='skills=plugskill' _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release ) &
  wait
  links="$(cd "$TMP/home/.config/devin/skills" 2>/dev/null && find . -type l -not -name '.*' | sed 's|^\./||' | sort | tr '\n' ' ')"
  marker="$(sort "$TMP/home/.config/devin/skills/.outsourcerer-grants" 2>/dev/null | tr '\n' ' ')"
  [ "$links" = "$marker " ] || [ "${links% }" = "${marker% }" ] || { agree=0; break; }
  i=$((i+1))
done
[ "$agree" = "1" ] && ok "10x concurrent A/B Devin dispatches: links and marker always agree" \
  || bad "concurrent Devin dispatches left links='$links' but marker='$marker'"

# --- 23. the Devin grant lock blocks overlap and dies on a stubborn holder --------------------------
rm -rf "$TMP/home/.config/devin/skills"
mkdir -p "$TMP/home/.config/devin/skills/.outsourcerer-grants.lock.d"
printf '%s\n' "$$" > "$TMP/home/.config/devin/skills/.outsourcerer-grants.lock.d/pid"
start=$(date +%s)
( WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=2 _devin_with_prepare ) >/dev/null 2>&1
rc=$?
end=$(date +%s)
[ "$rc" -ne 0 ] && [ $((end - start)) -ge 1 ] && ok "a held lock makes a second grant wait, then die naming the lock" \
  || bad "lock neither waited nor refused (rc=$rc, waited $((end-start))s)"
rm -rf "$TMP/home/.config/devin/skills/.outsourcerer-grants.lock.d"

# --- 24. no---with Devin dispatch scopes the home clean ---------------------------------------------
rm -rf "$TMP/home/.config/devin/skills"
WITH_SPEC='skills=confskill' _devin_with_prepare >/dev/null 2>&1
[ -L "$TMP/home/.config/devin/skills/confskill" ] || bad "setup: A grant link missing"
_devin_skills_lock_release
( WITH_SPEC='' _devin_with_prepare ) >/dev/null 2>&1; echo $? > /dev/null
rc=$?
[ ! -e "$TMP/home/.config/devin/skills/confskill" ] \
  && ok "an ungranted Devin dispatch removes the previous grant's links" \
  || bad "ungranted Devin dispatch inherited the prior grant"
[ -f "$TMP/home/.config/devin/skills/.outsourcerer-grants" ] && ! grep -q . "$TMP/home/.config/devin/skills/.outsourcerer-grants" \
  && ok "an ungranted dispatch publishes an empty marker" || bad "marker not emptied on ungranted dispatch"

# --- 25. CR/LF in the skill NAME itself is rejected at validation ------------------------------------
( _validate_with_token "skills=bad
name" ) >/dev/null 2>&1 && bad "an LF in a skill name passed validation" \
  || ok "an LF in a skill name dies at validation"
( _validate_with_token "skills=bad$(printf '\r')name" ) >/dev/null 2>&1 && bad "a CR in a skill name passed validation" \
  || ok "a CR in a skill name dies at validation"
CRSK="$TMP/home/.claude/skills/bad
name"; mkdir -p "$CRSK"; printf '# bad\n' > "$CRSK/SKILL.md"
names="$(WITH_SPEC="skills=bad
name" _with_skill_names 2>/dev/null)"
d="$(_resolve_skill_dir "$names" 2>/dev/null)"
[ -z "$d" ] && ok "an LF-named skill dir never resolves into a grant" || bad "LF-named skill resolved: $d"

# --- 26. BEHAVIORAL: the grant lock spans A's whole delegate run -------------------------------------
# A holds the lock from prepare through its (simulated synchronous) delegate run; B's grant
# attempt must REFUSE and must not mutate the home until A's run ends.
rm -rf "$TMP/home/.config/devin/skills"; rm -f "$TMP/releaseA"
( WITH_SPEC='skills=confskill' _devin_with_prepare >/dev/null 2>&1
  while [ ! -f "$TMP/releaseA" ]; do sleep 0.2 2>/dev/null || sleep 1; done   # A's delegate run
  _devin_skills_lock_release ) &
APID=$!
sleep 1
( WITH_SPEC='skills=plugskill' OSRC_DEVIN_LOCK_WAIT_MAX=2 _devin_with_prepare ) >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "B's grant refuses while A's delegate is still running" \
  || bad "B mutated the skills home during A's run"
[ -L "$TMP/home/.config/devin/skills/confskill" ] && [ ! -e "$TMP/home/.config/devin/skills/plugskill" ] \
  && [ "$(cat "$TMP/home/.config/devin/skills/.outsourcerer-grants")" = "confskill" ] \
  && ok "during A's run the home and marker stay exactly A's grant" \
  || bad "home/marker changed under A's run"
touch "$TMP/releaseA"; wait "$APID"
( WITH_SPEC='skills=plugskill' _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release )
rc=$?
[ "$rc" -eq 0 ] && [ -L "$TMP/home/.config/devin/skills/plugskill" ] && [ ! -e "$TMP/home/.config/devin/skills/confskill" ] \
  && ok "once A's run ends, B scopes the home to exactly B's grant" \
  || bad "B failed to scope the home after A exited (rc=$rc)"


# --- 27. SECURITY: untrusted marker lines never drive deletions; TAB/control chars die --------------
# The Devin grant marker is attacker-writable (anyone who can write the skills home can write it).
# A line like ../../victim-link must NEVER point the stale-link prune outside the skills home.
rm -rf "$TMP/home/.config/devin/skills" "$TMP/home/.config/victim-target" "$TMP/home/.config/victim-link"
mkdir -p "$TMP/home/.config/devin/skills"
printf 'secret\n' > "$TMP/home/.config/victim-target"
ln -s "$TMP/home/.config/victim-target" "$TMP/home/.config/victim-link"
mkdir -p "$TMP/home/.claude/skills/staleskill"; printf '# stale\n' > "$TMP/home/.claude/skills/staleskill/SKILL.md"
ln -s "$TMP/home/.claude/skills/staleskill" "$TMP/home/.config/devin/skills/staleskill"
printf '%s\n' '../../victim-link' 'staleskill' > "$TMP/home/.config/devin/skills/.outsourcerer-grants"
err="$( ( WITH_SPEC='' _devin_with_prepare ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -eq 0 ] || bad "ungranted prepare died on an unsafe marker line (it must ignore it): $err"
[ -L "$TMP/home/.config/victim-link" ] && [ -f "$TMP/home/.config/victim-target" ] \
  && ok "a ../../ line in the grant marker cannot delete a symlink outside the skills home" \
  || bad "MARKER TRAVERSAL: victim symlink or its target was removed"
case "$err" in *"unsafe line"*) ok "the unsafe marker line is called out on stderr" ;;
  *) bad "unsafe marker line not reported: $err" ;; esac
[ ! -e "$TMP/home/.config/devin/skills/staleskill" ] \
  && ok "legitimate stale links are still pruned alongside the ignored traversal line" \
  || bad "a legitimate stale link survived pruning"
# TAB and every other control character are rejected like CR/LF: the tokenizer splits on TAB, so a
# TAB name would silently misparse into fragments that resolve to nothing.
TABSK="$TMP/home/.claude/skills/$(printf 'tab\tname')"; mkdir -p "$TABSK"; printf '# tab\n' > "$TABSK/SKILL.md"
( _validate_with_token "$(printf 'skills=tab\tname')" ) >/dev/null 2>&1 \
  && bad "a TAB in a skill name passed validation" || ok "a TAB in a skill name dies at validation"
err="$( ( _validate_with_token "$(printf 'skills=tab\tname')" ) 2>&1 >/dev/null )"
case "$err" in *CR/LF*) ok "the TAB death names the control-character rule" ;;
  *) bad "TAB death message wrong: $err" ;; esac
_with_skill_name_ok "$(printf 'tab\tname')" && bad "_with_skill_name_ok accepted a TAB name" \
  || ok "_with_skill_name_ok rejects TAB"
_with_skill_name_ok "$(printf 'bell\aname')" && bad "_with_skill_name_ok accepted a control char (BEL)" \
  || ok "_with_skill_name_ok rejects the remaining control chars"
err="$( ( WITH_SPEC="$(printf 'skills=tab\tname')" _with_preamble_render bundle ) 2>&1 >/dev/null )"
rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NOT FOUND"*|*CR/LF*) ok "a TAB-named skill can never dispatch rc=0-unresolved (validation or NOT FOUND kills it)" ;;
  *) bad "TAB-named bundle death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "a TAB-named skill dispatched rc=0 with nothing resolved"


# --- 28. skills=all with NO resolvable skills FAILS on every transport; refused bundles clean up ----
EH="$TMP/emptyhome"; rm -rf "$EH"; mkdir -p "$EH"
err="$( ( HOME="$EH" WITH_SPEC='skills=all' _with_preamble_render bundle ) 2>&1 >/dev/null )"; rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NO skills were found"*) ok "skills=all with no skills FAILS the bundle render, naming why" ;;
  *) bad "empty-all bundle death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "skills=all with no skills rendered a bundle rc=0 (silent no-grant)"
err="$( ( HOME="$EH" WITH_SPEC='skills=all' _with_preamble_render text ) 2>&1 >/dev/null )"; rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NO skills were found"*) ok "skills=all with no skills FAILS the text render" ;;
  *) bad "empty-all text death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "skills=all with no skills rendered text rc=0"
err="$( ( HOME="$EH" WITH_SPEC='skills=all' build_with_preamble ) 2>&1 >/dev/null )"; rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NO skills were found"*) ok "skills=all with no skills FAILS the legacy inline render" ;;
  *) bad "empty-all inline death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "skills=all with no skills rendered inline rc=0"
err="$( ( HOME="$EH" WITH_SPEC='skills=all' _devin_with_prepare ) 2>&1 >/dev/null )"; rc=$?
[ "$rc" -ne 0 ] && case "$err" in *"NO skills were found"*) ok "skills=all with no skills FAILS the Devin prepare" ;;
  *) bad "empty-all Devin death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "skills=all with no skills passed Devin prepare rc=0"
# an mcp=-only spec on an empty host still renders fine (no skills were ever requested)
( HOME="$EH" WITH_SPEC='mcp=realsrv' _with_preamble_render bundle+mcp ) >/dev/null 2>&1 \
  && ok "an mcp=-only spec without skills is NOT mistaken for an empty skills grant" \
  || bad "mcp=-only render broke on an empty host"
# a refused bundle grant removes its just-built partial root
_before="$(find "$OSRC_HOME" -maxdepth 1 -name 'skill-bundle.*' 2>/dev/null | sort)"
( WITH_SPEC='skills=confskill,ghostskill' _with_preamble_render bundle ) >/dev/null 2>&1; rc=$?
_after="$(find "$OSRC_HOME" -maxdepth 1 -name 'skill-bundle.*' 2>/dev/null | sort)"
[ "$rc" -ne 0 ] && [ "$_before" = "$_after" ] \
  && ok "a bundle refused for a missing member removes its partial root" \
  || bad "refused bundle left a partial root behind (rc=$rc)"


# --- 29. absolute symlinks refuse staging; every STAGED link resolves under the STAGED root ---------
# An absolute link that resolves in-tree in the SOURCE passes a source-tree check, but tar
# preserves it verbatim, so the staged link would read LIVE source state outside the bundle.
ASK="$TMP/home/.claude/skills/absskill"; rm -rf "$ASK"; mkdir -p "$ASK/references"
printf '# abs\n' > "$ASK/SKILL.md"
printf 'original\n' > "$ASK/references/target.txt"
ln -s "$ASK/references/target.txt" "$ASK/references/abs-link"
err="$( ( WITH_SPEC='skills=absskill' _skill_bundle_build "$OSRC_HOME/sb-abs" absskill ) 2>&1 >/dev/null )"; rc=$?
[ "$rc" -ne 0 ] && case "$err" in *absolute*) ok "an absolute symlink (in-tree in the source) refuses the bundle, named as absolute" ;;
  *) bad "absolute-link death wrong: $err" ;; esac
[ "$rc" -ne 0 ] || bad "an absolute in-source symlink staged rc=0 (staged link would read live source)"
ln -s "$ASK/SKILL.md" "$ASK/root-abs"
( WITH_SPEC='skills=absskill' _skill_bundle_build "$OSRC_HOME/sb-abs2" absskill ) >/dev/null 2>&1 \
  && bad "an absolute link to the source SKILL.md staged rc=0" \
  || ok "an absolute link to the source SKILL.md refuses too"
# Relative in-tree links stage - and every STAGED link resolves beneath the STAGED skill root.
RSK="$TMP/home/.claude/skills/relskill"; rm -rf "$RSK"; mkdir -p "$RSK/references/sub"
printf '# rel\n' > "$RSK/SKILL.md"
printf 'deep-original\n' > "$RSK/references/sub/deep.txt"
ln -s 'sub/deep.txt' "$RSK/references/alias.txt"
ln -s '../SKILL.md' "$RSK/references/up-link"
ln -s 'SKILL.md' "$RSK/root-link"
( WITH_SPEC='skills=relskill' _skill_bundle_build "$OSRC_HOME/sb-rel" relskill ) >/dev/null 2>&1 \
  && ok "relative in-tree links (incl. nested and .. forms) stage fine" \
  || bad "relative in-tree links were refused"
staged_ok=1
# Canonicalize the baseline the SAME way _canon_path canonicalizes the link (pwd -P resolves every
# symlink, incl. macOS /var -> /private/var), or an in-tree link reads as an escape purely because
# one side kept the /var spelling and the other the /private/var spelling.
staged_root_canon="$(_canon_path "$OSRC_HOME/sb-rel/relskill")"
while IFS= read -r sl; do
  [ -n "$sl" ] || continue
  canon="$(_canon_path "$(dirname "$sl")/$(readlink "$sl")")"
  case "$canon" in "$staged_root_canon"|"$staged_root_canon"/*) ;;
    *) staged_ok=0; bad "STAGED link escapes the staged root: $sl -> $(readlink "$sl")" ;; esac
done <<_OSRC_STAGED_LINKS
$(find "$OSRC_HOME/sb-rel/relskill" -type l 2>/dev/null)
_OSRC_STAGED_LINKS
[ "$staged_ok" = "1" ] && ok "every STAGED symlink resolves under the staged skill root"
# Mutation proof: source changes after staging are invisible through the staged link.
printf 'MUTATED\n' >> "$RSK/references/sub/deep.txt"
case "$(cat "$OSRC_HOME/sb-rel/relskill/references/alias.txt" 2>/dev/null)" in
  *MUTATED*) bad "the staged link reads LIVE source state (immutable-bundle broken)" ;;
  *deep-original*) ok "the staged link serves the staged bytes, not live source state" ;;
  *) bad "staged link content wrong" ;; esac

HOME="$HOME_REAL"

exec 2>&9 9>&-   # restore stderr, then enforce the watchdog
[ -s "$SUITE_ERR" ] && { echo "FAIL: suite emitted unexpected stderr (an internal error must never print green):"; sed 's/^/  /' "$SUITE_ERR"; fail=$((fail+1)); }

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

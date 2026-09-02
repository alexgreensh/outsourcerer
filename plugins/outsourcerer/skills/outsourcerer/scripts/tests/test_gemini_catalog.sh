#!/usr/bin/env bash
# test_gemini_catalog.sh — the Gemini lane picks its model from the LIVE catalog, never a dated literal.
#
# Issue #21: `gemini-flash` resolved through the static table to `gemini-3.5-flash`, agy retired that
# id, every Google delegation failed, `doctor` reported the lane UNCLEAR, and the documented override
# (OSRC_AGY_FLASH_DEFAULT) was bypassed because the table had already produced a "valid-looking" id.
# The live catalog at the time of this fix was already at 3.8-flash, one release past the id the
# issue suggested pinning, which is the whole argument for reading the catalog instead of a table.
#
# Asserted here, against a STUB `agy` (hermetic: no network, no real CLI, no quota):
#   - `agy models` output is parsed into the catalog cache (status line dropped, ids kept);
#   - a family alias resolves to the NEWEST served member, numerically (3.10 beats 3.8);
#   - a RETIRED explicit id is replaced by the newest family member, LOUDLY, naming the retired id;
#   - a SERVED explicit id passes through untouched (the 0.10.0 silent-substitution regression);
#   - an env pin beats the catalog; a models.local row beats the built-in table;
#   - with the catalog unreachable, an explicit id passes through and a bare alias still resolves;
#   - models.local cannot smuggle shell (charset gate);
#   - no dispatch/probe site names a dated Gemini id (source-level guard so it cannot creep back).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (catalog cache needs it)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# The script prepends $HOME/.local/bin to PATH, so a stub only wins when HOME is ours too.
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/osrc"
cat > "$TMP/bin/agy" <<'STUB'
#!/bin/sh
# Mirrors the real `agy models` wire format: a status line, then "<id><TAB><label>" rows.
printf 'Fetching available models...\n'
printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n'
printf 'gemini-3.10-flash-medium\tGemini 3.10 Flash (Medium)\n'
printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\n'
printf 'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n'
printf 'gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\n'
printf 'claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n'
STUB
chmod +x "$TMP/bin/agy"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" OSRC_HOME="$TMP/osrc"
unset OSRC_AGY_FLASH_DEFAULT OSRC_AGY_PRO_DEFAULT OSRC_GEMINI_FLASH_API_ID

. "$SRC" >/dev/null 2>&1
for f in _agy_model_token _agy_family_default _gemini_newest _agy_catalog_knows _gemini_api_id _catalog_load; do
  type -t "$f" >/dev/null || { echo "FAIL: $f not loaded"; exit 1; }
done

# --- the catalog is READ from agy, and parsed correctly ------------------------------------------
cat_json="$(_catalog_load gm 2>/dev/null | tr '\n' ' ')"
case "$cat_json" in *gemini-3.8-flash-high*) ok "agy models rows land in the gm catalog" ;; *) bad "gm catalog missing rows: $cat_json" ;; esac
case "$cat_json" in *Fetching*) bad "the 'Fetching available models...' status line was cached as a model id" ;; *) ok "the status line is not mistaken for a model" ;; esac
[ -f "$OSRC_HOME/catalogs/gm.json" ] && ok "gm catalog is cached at \$OSRC_HOME/catalogs/gm.json" || bad "no gm catalog cache written"

# --- newest family member, NUMERIC version order --------------------------------------------------
[ "$(_gemini_newest gm flash)" = "gemini-3.10-flash" ] \
  && ok "newest flash is picked numerically (3.10 beats 3.8; a string sort would get this wrong)" \
  || bad "newest flash wrong: $(_gemini_newest gm flash)"
[ "$(_gemini_newest gm pro)" = "gemini-3.1-pro" ] && ok "newest pro is found with its effort suffix stripped" || bad "newest pro wrong: $(_gemini_newest gm pro)"
[ -z "$(_gemini_newest gm flash-lite)" ] && ok "a family agy does not serve yields empty, not a guess" || bad "flash-lite invented: $(_gemini_newest gm flash-lite)"

# --- the alias the table now emits resolves live ---------------------------------------------------
[ "$(_agy_model_token gemini-flash 2>/dev/null)" = "gemini-3.10-flash" ] \
  && ok "gemini-flash (symbolic table id) resolves to the newest served flash" \
  || bad "gemini-flash resolved to $(_agy_model_token gemini-flash 2>/dev/null)"
[ "$(_agy_model_token gemini-pro 2>/dev/null)" = "gemini-3.1-pro" ] && ok "gemini-pro resolves live" || bad "gemini-pro: $(_agy_model_token gemini-pro 2>/dev/null)"
[ "$(_agy_model_token gemini-flash-lite 2>/dev/null)" = "gemini-3.10-flash" ] && ok "gemini-flash-lite collapses to the newest flash (agy has no lite tier)" || bad "flash-lite: $(_agy_model_token gemini-flash-lite 2>/dev/null)"
row="$(resolve_model_row gemini-flash)"
case "$row" in gemini-flash\|gm\|*) ok "the built-in table no longer pins gemini-flash to a dated id" ;; *) bad "table row for gemini-flash is dated again: $row" ;; esac

# --- issue #21 exactly: a RETIRED id is healed, out loud ------------------------------------------
out="$(_agy_model_token gemini-3.5-flash 2>"$TMP/err")"
[ "$out" = "gemini-3.10-flash" ] && ok "a retired explicit id (3.5-flash) is replaced by the newest served flash" || bad "retired id resolved to: $out"
grep -q 'gemini-3.5-flash' "$TMP/err" && ok "the notice NAMES the retired id" || bad "notice does not name the retired id: $(cat "$TMP/err")"
grep -q 'OSRC_AGY_FLASH_DEFAULT' "$TMP/err" && grep -q 'models.local' "$TMP/err" \
  && ok "the notice lists every pin mechanism (env + models.local)" || bad "notice omits the pin mechanisms: $(cat "$TMP/err")"
grep -q 'agy models' "$TMP/err" && ok "the notice points at the live catalog command" || bad "notice does not mention agy models"

# --- but a SERVED explicit id is never rewritten (0.10.0 regression guard) -----------------------
[ "$(_agy_model_token gemini-3.7-flash 2>/dev/null)" = "gemini-3.7-flash" ] && ok "a served, older explicit id passes through untouched" || bad "served 3.7 rewritten: $(_agy_model_token gemini-3.7-flash 2>/dev/null)"
[ "$(_agy_model_token gemini-3.8-flash-high 2>/dev/null)" = "gemini-3.8-flash-high" ] && ok "an effort-suffixed served id passes through" || bad "3.8-high rewritten"
[ -z "$(_agy_model_token gemini-3.7-flash 2>&1 >/dev/null)" ] && ok "no notice is printed when nothing was substituted" || bad "a served id produced a substitution notice"

# --- precedence: env pin > live catalog --------------------------------------------------------------
[ "$(OSRC_AGY_FLASH_DEFAULT=gemini-9.9-flash _agy_model_token gemini-flash 2>/dev/null)" = "gemini-9.9-flash" ] \
  && ok "OSRC_AGY_FLASH_DEFAULT beats the live catalog for the bare alias (the override issue #21 said was bypassed)" \
  || bad "env pin lost to the catalog"
[ "$(OSRC_AGY_FLASH_DEFAULT=gemini-9.9-flash _agy_model_token gemini-3.5-flash 2>/dev/null)" = "gemini-9.9-flash" ] \
  && ok "OSRC_AGY_FLASH_DEFAULT also decides where a retired id lands" || bad "env pin ignored for a retired id"

# --- models.local: user rows win over the built-in table, and cannot carry shell ------------------
printf '# my pins\nglm | z-ai/glm-5.2 | cc | capable\ngemini-flash|gemini-3.7-flash|gm|mid\nevil|$(touch %s/pwned)|gm|mid\n' "$TMP" > "$OSRC_HOME/models.local"
( . "$SRC" >/dev/null 2>&1
  [ "$(resolve_model_row gemini-flash)" = "gemini-3.7-flash|gm|mid" ] && echo "PASS: a models.local row overrides the built-in gemini-flash row" || echo "FAIL: models.local row lost: $(resolve_model_row gemini-flash)"
  [ "$(resolve_model_row glm)" = "z-ai/glm-5.2|cc|capable" ] && echo "PASS: models.local rows tolerate spaces and comments" || echo "FAIL: spaced row not parsed: $(resolve_model_row glm)"
  [ -z "$(resolve_model_row evil)" ] && echo "PASS: a row carrying shell metacharacters is dropped" || echo "FAIL: shell row accepted"
  [ ! -e "$TMP/pwned" ] && echo "PASS: nothing in models.local was executed" || echo "FAIL: models.local row executed a command"
) > "$TMP/sub.out"; while IFS= read -r line; do case "$line" in PASS:*) ok "${line#PASS: }" ;; *) bad "${line#FAIL: }" ;; esac; done < "$TMP/sub.out"
rm -f "$OSRC_HOME/models.local"

# --- catalog UNREACHABLE: fail open ----------------------------------------------------------------
( export OSRC_HOME="$TMP/osrc-offline" PATH="/usr/bin:/bin"; . "$SRC" >/dev/null 2>&1
  [ "$(_agy_model_token gemini-3.5-flash 2>/dev/null)" = "gemini-3.5-flash" ] && echo "PASS: with no catalog an explicit id passes through (agy stays the authority)" || echo "FAIL: offline rewrote an explicit id to $(_agy_model_token gemini-3.5-flash 2>/dev/null)"
  t="$(_agy_model_token gemini-flash 2>/dev/null)"; case "$t" in gemini-[0-9]*-flash) echo "PASS: with no catalog the bare alias still yields a flash id ($t)" ;; *) echo "FAIL: offline alias gave '$t'" ;; esac
  [ "$t" = "$_AGY_FLASH_LASTKNOWN" ] && echo "PASS: the last-known id is reached ONLY when the catalog is unreachable" || echo "FAIL: offline alias is not the last-known constant"
) > "$TMP/sub.out"; while IFS= read -r line; do case "$line" in PASS:*) ok "${line#PASS: }" ;; *) bad "${line#FAIL: }" ;; esac; done < "$TMP/sub.out"

# --- gemini-cli (API key) vehicle resolves the same symbolic alias ---------------------------------
mkdir -p "$OSRC_HOME/catalogs"
printf '["gemini-3.5-flash","gemini-3.9-flash","gemini-3.1-pro-preview","gemini-3.1-flash-lite","gemini-2.5-flash-image","gemini-3.1-flash-image"]' > "$OSRC_HOME/catalogs/gi.json"
[ "$(_gemini_api_id gemini-flash)" = "gemini-3.9-flash" ] && ok "gemini-cli vehicle: gemini-flash -> newest flash in the API model list" || bad "gi flash: $(_gemini_api_id gemini-flash)"
[ "$(_gemini_api_id gemini-pro)" = "gemini-3.1-pro-preview" ] && ok "gemini-cli vehicle: a -preview id is accepted when no GA pro exists" || bad "gi pro: $(_gemini_api_id gemini-pro)"
[ "$(_gemini_api_id gemini-flash-lite)" = "gemini-3.1-flash-lite" ] && ok "gemini-cli vehicle: flash-lite is its own family, not collapsed" || bad "gi lite: $(_gemini_api_id gemini-flash-lite)"
[ "$(_gemini_api_id gemini-3.5-flash)" = "gemini-3.5-flash" ] && ok "gemini-cli vehicle: an explicit id passes through" || bad "gi explicit rewritten"
[ "$(_gemini_api_id nano-banana)" = "gemini-3.1-flash-image" ] && ok "image lane: nano-banana -> newest flash-image in the API model list" || bad "gi image: $(_gemini_api_id nano-banana)"
grep -q 'id="$(_gemini_api_id nano-banana)"' "$SRC" && ok "the image backend picks its Gemini id through the resolver" || bad "image backend still names a literal id"
[ "$(OSRC_GEMINI_FLASH_API_ID=gemini-7-flash _gemini_api_id gemini-flash)" = "gemini-7-flash" ] && ok "gemini-cli vehicle: env pin wins" || bad "gi env pin lost"
grep -q 'id="$(_gemini_api_id "$id")"' "$SRC" && ok "the gemini-cli dispatch actually calls the resolver before --model" || bad "gemini-cli dispatch does not resolve the alias"

# --- a refused model clears the cache and explains the pins (the dispatch-side half) --------------
grep -q "invalid model selection|not recognized as a known model" "$SRC" && ok "the agy dispatch recognises a refused-model error" || bad "no refused-model translation in the agy dispatch"
grep -q 'rm -f "$(_catalog_path gm)"' "$SRC" && ok "a refused model drops the cached catalog so the next run re-reads agy models" || bad "refused model does not invalidate the gm cache"

# --- source-level guard: no dated Gemini id may reach a dispatch or probe again -------------------
dated="$(grep -nE 'gemini-[0-9]+\.[0-9]+-(flash|pro)' "$SRC" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '_(AGY|GI)_[A-Z_]+_LASTKNOWN=' || true)"
# (the image family is covered by the same regex: gemini-2.5-flash-image would match too)
[ -z "$dated" ] && ok "no dated Gemini id is used outside the last-known offline constants" || bad "dated Gemini ids still hardcoded:
$dated"
grep -q '\-\-model "$(_agy_model_token gemini-flash)"' "$SRC" && ok "both agy liveness probes go through the resolver" || bad "an agy probe still names a literal model"
grep -q '\-\-model "$(_gemini_api_id gemini-flash-lite)"' "$SRC" && ok "the gemini-cli probe goes through the resolver" || bad "gemini-cli probe still names a literal model"
grep -q "gemini|gm) printf 'gemini-flash-lite'" "$SRC" && ok "the route default for the gemini lane is symbolic" || bad "route default still dated"

echo; echo "test_gemini_catalog: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

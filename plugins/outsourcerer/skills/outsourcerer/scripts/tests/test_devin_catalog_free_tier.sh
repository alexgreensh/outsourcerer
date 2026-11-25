#!/usr/bin/env bash
# test_devin_catalog_free_tier.sh — the free tier is CATALOG-DRIVEN, not a hardcoded list. Any model
# Devin's live catalog marks cost_tier="Free" is recognized as free with no code change, so the set
# can never drift behind Devin again (the class of bug where swe-2 was silently unrecognized). And it
# is COST-SAFE: a family with any paid variant is never treated as free. The static list remains the
# offline fallback (no catalog / OSRC_FREE_CATALOG_CHECK=0).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 -> got:'$2' want:'$3'"; fi; }

# Synthetic catalog: a brand-new Free family the static list has NEVER heard of, a Low-cost family,
# and a MIXED family (one Free variant + one paid variant).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT
mkdir -p "$TMP/catalogs"
cat > "$TMP/catalogs/dv.raw.json" <<'JSON'
{"families":[
 {"family_uid":"nova-9","slug":"nova-9","variants":[{"model_uid":"nova-9-high","cost_tier":"Free"},{"model_uid":"nova-9-max","cost_tier":"Free"}]},
 {"family_uid":"pricey-2","slug":"pricey-2","variants":[{"model_uid":"pricey-2-high","cost_tier":"Low cost"}]},
 {"family_uid":"mixed-3","slug":"mixed-3","variants":[{"model_uid":"mixed-3-free","cost_tier":"Free"},{"model_uid":"mixed-3-paid","cost_tier":"Low cost"}]},
 {"family_uid":"swe-2-1","slug":"swe-2-1","variants":[{"model_uid":"swe-2-1-high","cost_tier":"Free"},{"model_uid":"swe-2-1-max","cost_tier":"Free"},{"model_uid":"swe-2-1-high-lightning","cost_tier":"High cost"}]},
 {"family_uid":"swe-2","slug":"swe-2","variants":[{"model_uid":"swe-2-high","cost_tier":"Free"},{"model_uid":"swe-2-high-lightning","cost_tier":"High cost"}]},
 {"family_uid":"fusion","slug":"fusion","variants":[{"model_uid":"fusion-x","cost_tier":"High cost","cost_summary":"$8/MTok · Sidekick: Free"}]},
 {"family_uid":"zeta-4","slug":"zeta-4","variants":[{"model_uid":"zeta-4-high","cost_tier":"Free"},{"model_uid":"zeta-4-max","cost_tier":"High cost"},{"model_uid":"zeta-4-xhigh","cost_tier":"Free"}]}
]}
JSON
echo '[]' > "$TMP/catalogs/dv.json"

export OSRC_HOME="$TMP" OSRC_CATALOG_TTL=999999 OSRC_HEARTBEAT_DISABLED=1
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _devin_catalog_free_set >/dev/null || { echo "FAIL: _devin_catalog_free_set missing"; exit 1; }
type -t _devin_first_catalog_free_model >/dev/null || { echo "FAIL: _devin_first_catalog_free_model missing"; exit 1; }

# --- self-healing: a new Free model not in the static list is recognized -------------------------
eq "new Free family recognized"        "$(_devin_is_free_model nova-9      && echo yes || echo no)" yes
eq "new Free variant recognized"       "$(_devin_is_free_model nova-9-high && echo yes || echo no)" yes
eq "dotted/normalized form recognized" "$(_devin_is_free_model nova-9-max  && echo yes || echo no)" yes

# --- cost-safety: paid stays paid; a mixed family is not blanket-free ----------------------------
eq "Low-cost family is paid"           "$(_devin_is_free_model pricey-2      && echo yes || echo no)" no
eq "mixed family (has paid variant) is paid" "$(_devin_is_free_model mixed-3 && echo yes || echo no)" no
eq "the Free variant of a mixed family is free" "$(_devin_is_free_model mixed-3-free && echo yes || echo no)" yes
eq "dashed SWE 2.1 Free variant recognized" "$(_devin_is_free_model swe-2-1-high && echo yes || echo no)" yes
eq "paid SWE lightning sibling stays paid" "$(_devin_is_free_model swe-2-1-high-lightning && echo yes || echo no)" no
eq "Sidekick-only Fusion row is not main-model Free" "$(_devin_is_free_model fusion-x && echo yes || echo no)" no
eq "dynamic swe alias picks newest mainline Free high" "$(_devin_resolve_dynamic swe 2>/dev/null)" swe-2-1-high

# --- paid-sibling hole (Neon/GLM finding 1): real tier suffixes on a mixed family ---------------
eq "mixed zeta family bare id is paid"      "$(_devin_is_free_model zeta-4       && echo yes || echo no)" no
eq "paid -max sibling of a free -high is paid" "$(_devin_is_free_model zeta-4-max && echo yes || echo no)" no
eq "free -high variant itself is free"      "$(_devin_is_free_model zeta-4-high  && echo yes || echo no)" yes
eq "free -xhigh variant recognized (xhigh canon)" "$(_devin_is_free_model zeta-4-xhigh && echo yes || echo no)" yes

# --- costrank canary: a newer PAID Sidekick-Free fusion id must never outrank a truly-Free id ----
eq "resolve mixed family picks free -high, not paid sibling" "$(_devin_resolve_dynamic zeta 2>/dev/null)" zeta-4-high

# --- the escape-probe alt is discovered from the catalog -----------------------------------------
eq "probe alt = newest mainline Free high variant" "$(_devin_first_catalog_free_model)" nova-9-high
eq "capped default -> probes the Free model" "$(_devin_plan_probe_model glm-5-2)" nova-9-high

# --- ranker branch (Neon 13): a catalog of ONLY mixed families must still pick the --------------
# --- newest mainline Free -high, keep mainline above budget, and never touch Fusion rows. --------
TMP2="$(mktemp -d)"; mkdir -p "$TMP2/catalogs"
cat > "$TMP2/catalogs/dv.raw.json" <<'JSON'
{"families":[
 {"family_uid":"swe-2-1","slug":"swe-2-1","variants":[
   {"model_uid":"swe-2-1-high","cost_tier":"Free"},
   {"model_uid":"swe-2-1-max","cost_tier":"High cost"},
   {"model_uid":"swe-2-1-xhigh","cost_tier":"Free"}]},
 {"family_uid":"swe-2-flash","slug":"swe-2-flash","variants":[
   {"model_uid":"swe-2-flash-high","cost_tier":"Free"}]},
 {"family_uid":"swe-2","slug":"swe-2","variants":[
   {"model_uid":"swe-2-high","cost_tier":"Free"},
   {"model_uid":"swe-2-max","cost_tier":"High cost"}]},
 {"family_uid":"fusion-claude","slug":"fusion-claude","variants":[
   {"model_uid":"fusion-claude-high-sidekick-swe-2-high","cost_tier":"High cost","cost_summary":"$8/MTok · Sidekick: Free"}]}
]}
JSON
echo '[]' > "$TMP2/catalogs/dv.json"
_first="$(OSRC_HOME="$TMP2" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; _devin_first_catalog_free_model' 2>/dev/null)"
eq "mixed-only catalog: probe alt is newest mainline -high" "$_first" swe-2-1-high
_dft="$(OSRC_HOME="$TMP2" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; _devin_default_free_model' 2>/dev/null)"
eq "mixed-only catalog: default is newest mainline -high" "$_dft" swe-2-1-high
_bill="$(OSRC_HOME="$TMP2" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1
  _devin_is_free_model fusion-claude-high-sidekick-swe-2-high && echo free || echo metered' 2>/dev/null)"
eq "mixed-only catalog: fusion sidekick row never free" "$_bill" metered
rm -rf "$TMP2"

# --- offline fallback: with the catalog check off, the static list still recognizes swe-2 --------
eq "offline: swe-2 free via static list" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model swe-2 && echo yes || echo no)" yes
eq "offline: swe-2-flash free via static list" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model swe-2-flash && echo yes || echo no)" yes
eq "offline: swe-2-flash-high free via static list" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model swe-2-flash-high && echo yes || echo no)" yes
eq "offline: nova-9 NOT known (no static, no catalog)" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model nova-9 && echo yes || echo no)" no

# --- codex post-promo scenario: the alias must land on the FREE variant, and gate/dispatch -------
# --- resolution of the same token must agree on classification. swe-1-7 fully Free; the newer -----
# --- swe-2-1 family has a PAID -high (the default effort) but a FREE -max. Before the fix, the ----
# --- effort filter ran before cost and `-m swe` resolved to the paid swe-2-1-high while the -------
# --- spend gate classified the static-table id swe-1.7 as free — silent spend, no consent. --------
TMP3="$(mktemp -d)"; mkdir -p "$TMP3/catalogs"
cat > "$TMP3/catalogs/dv.raw.json" <<'JSON'
{"families":[
 {"family_uid":"swe-1-7","slug":"swe-1-7","variants":[
   {"model_uid":"swe-1-7-high","cost_tier":"Free"},
   {"model_uid":"swe-1-7-max","cost_tier":"Free"}]},
 {"family_uid":"swe-2-1","slug":"swe-2-1","variants":[
   {"model_uid":"swe-2-1-high","cost_tier":"High cost"},
   {"model_uid":"swe-2-1-max","cost_tier":"Free"}]},
 {"family_uid":"swe-2","slug":"swe-2","variants":[
   {"model_uid":"swe-2-high","cost_tier":"High cost"}]}
]}
JSON
echo '[]' > "$TMP3/catalogs/dv.json"
_pp="$(OSRC_HOME="$TMP3" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; unset EFFORT; _devin_resolve_model swe' 2>/dev/null)"
eq "post-promo: swe alias resolves to the FREE -max, not paid -high" "$_pp" swe-2-1-max
_ppfree="$(OSRC_HOME="$TMP3" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; unset EFFORT
  r="$(_devin_resolve_model swe)"; _devin_is_free_model "$r" && echo yes || echo no' 2>/dev/null)"
eq "post-promo: the resolved launch id classifies free consistently" "$_ppfree" yes
_dot="$(OSRC_HOME="$TMP3" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; unset EFFORT; _devin_resolve_model swe-1.7' 2>/dev/null)"
eq "post-promo: dotted family id resolves dynamically to a real variant" "$_dot" swe-1-7-high

# --- case/dot exact-variant normalization: a mixed-case PAID variant must classify as paid -------
# --- after resolution (the end-to-end consent path depends on it) ---------------------------------
_mc="$(OSRC_HOME="$TMP" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1
  r="$(_devin_resolve_model "ZETA-4-Max")"; printf "%s|" "$r"
  _devin_is_free_model "$r" && echo free || echo metered' 2>/dev/null)"
eq "mixed-case paid variant resolves to exact id and classifies metered" "$_mc" "zeta-4-max|metered"
_mc2="$(OSRC_HOME="$TMP" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1
  r="$(_devin_resolve_model "SWE-2.1-High")"; printf "%s|" "$r"
  _devin_is_free_model "$r" && echo free || echo metered' 2>/dev/null)"
eq "mixed-case/dot free variant resolves to exact id and classifies free" "$_mc2" "swe-2-1-high|free"

# --- cross-family ranking: version digits are family-scoped, catalog order decides across ---------
# --- families, and date-like digit runs are not versions (Instinct MED, verified) -----------------
TMP4="$(mktemp -d)"; mkdir -p "$TMP4/catalogs"
cat > "$TMP4/catalogs/dv.raw.json" <<'JSON'
{"families":[
 {"family_uid":"claude-4","slug":"claude-4","variants":[{"model_uid":"claude-4-high","cost_tier":"Free"}]},
 {"family_uid":"gpt-5","slug":"gpt-5","variants":[{"model_uid":"gpt-5-high","cost_tier":"Free"}]},
 {"family_uid":"x-20250514","slug":"x-20250514","variants":[{"model_uid":"x-20250514-high","cost_tier":"Free"}]}
]}
JSON
echo '[]' > "$TMP4/catalogs/dv.json"
_xf="$(OSRC_HOME="$TMP4" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; _devin_default_free_model' 2>/dev/null)"
eq "cross-family: catalog order decides, not digit magnitude" "$_xf" claude-4-high
_dr="$(printf '%s\n' x-20250514-high x-3-high | _osrc_pick_best_free 2>/dev/null)"
eq "date-like digit run never outranks a real version within a family" "$_dr" x-3-high

# --- deliberate fail-closed pin: a cost_tier that merely STARTS with free is paid -----------------
# --- ("Free (promo)", "Free until Dec 1"). Exact-match-only is the intended safety property; -------
# --- a future free model going undiscovered is the accepted cost of never billing silently. --------
TMP5="$(mktemp -d)"; mkdir -p "$TMP5/catalogs"
cat > "$TMP5/catalogs/dv.raw.json" <<'JSON'
{"families":[
 {"family_uid":"promo-1","slug":"promo-1","variants":[{"model_uid":"promo-1-high","cost_tier":"Free (promo)"}]}
]}
JSON
echo '[]' > "$TMP5/catalogs/dv.json"
_nfr="$(OSRC_HOME="$TMP5" OSRC_CATALOG_TTL=999999 bash -c '
  OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1
  _devin_is_free_model promo-1-high && echo free || echo metered' 2>/dev/null)"
eq "near-free cost_tier fails closed (deliberate)" "$_nfr" metered

# --- structural: the spend gate resolves the SAME token dispatch uses (MODEL, not RESOLVED_ID) ----
grep -q '_gm="$(_devin_resolve_model "$MODEL"' "$SRC" \
  && ok "source: spend gate resolves the same MODEL token dispatch uses" \
  || bad "source: spend gate input diverged from dispatch (codex regression)"

# --- source cross-check: the classification actually consults the catalog ------------------------
grep -q '_devin_catalog_free_set' "$SRC" && ok "source: _devin_is_free_model consults the catalog set" \
  || bad "source: catalog-driven free check removed"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]

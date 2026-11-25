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

# --- source cross-check: the classification actually consults the catalog ------------------------
grep -q 'set="$(_devin_catalog_free_set)"' "$(dirname "$SRC")/lib/devin-free.sh" && ok "source: _devin_is_free_model consults the catalog set" \
  || bad "source: catalog-driven free check removed"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]

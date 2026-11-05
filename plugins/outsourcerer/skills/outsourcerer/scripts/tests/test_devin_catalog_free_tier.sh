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
 {"family_uid":"mixed-3","slug":"mixed-3","variants":[{"model_uid":"mixed-3-free","cost_tier":"Free"},{"model_uid":"mixed-3-paid","cost_tier":"Low cost"}]}
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

# --- the escape-probe alt is discovered from the catalog -----------------------------------------
eq "probe alt = a catalog Free family" "$(_devin_first_catalog_free_model)" nova-9
eq "capped default -> probes the Free model" "$(_devin_plan_probe_model glm-5-2)" nova-9

# --- offline fallback: with the catalog check off, the static list still recognizes swe-2 --------
eq "offline: swe-2 free via static list" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model swe-2 && echo yes || echo no)" yes
for m in swe-2-flash-medium swe-2-flash-high swe-2-flash-max swe-2-flash; do
  eq "offline: $m free via static list" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model "$m" && echo yes || echo no)" yes
done
eq "no catalog: default free probe is swe-2-flash-high" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_plan_probe_model glm-5-2)" swe-2-flash-high
eq "glm excluded: next probe pick is swe-2-flash-high" "$(OSRC_EXCLUDE_MODELS=glm _devin_probe_pick glm-5-2)" swe-2-flash-high
eq "offline: nova-9 NOT known (no static, no catalog)" "$(OSRC_FREE_CATALOG_CHECK=0 _devin_is_free_model nova-9 && echo yes || echo no)" no

# --- source cross-check: the classification actually consults the catalog ------------------------
grep -q '_devin_catalog_free_set' "$SRC" && ok "source: _devin_is_free_model consults the catalog set" \
  || bad "source: catalog-driven free check removed"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]

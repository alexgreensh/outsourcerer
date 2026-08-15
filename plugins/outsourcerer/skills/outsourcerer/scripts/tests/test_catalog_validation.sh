#!/usr/bin/env bash
# test_catalog_validation.sh — dynamic catalog validation. Deterministic (seeded cache, no live
# CLI). Guards the lane-brickers: object-shape parse, family/variant union, oz box-table strip,
# empty-cache poisoning (must fail OPEN, not brick every model), and the pipefail/SIGPIPE
# false-negative in _catalog_contains.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent (catalog validation no-ops)"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

T="$(mktemp -d)"; export OSRC_HOME="$T"; trap 'rm -rf "$T"' EXIT
. "$SRC" >/dev/null 2>&1

# --- _catalog_normalize: Devin OBJECT shape -> union of family_uid + aliases + variant model_uids ---
DVJSON='{"families":[{"family_uid":"glm-5.2","aliases":["glm"],"variants":[{"model_uid":"glm-5-2"},{"model_uid":"glm-5-2-max"}]},{"family_uid":"deepseek-v4-pro","aliases":[],"variants":[{"model_uid":"deepseek-v4-pro-high"}]}]}'
norm="$(_catalog_normalize dv "$DVJSON")"
echo "$norm" | jq -e 'index("glm-5.2") and index("glm") and index("glm-5-2") and index("deepseek-v4-pro-high")' >/dev/null 2>&1 \
  && ok "dv object: union has family_uid + alias + variant ids" || bad "dv object union missing ids: $norm"

# --- warp box-table (incl. multi-column) -> ids extracted, chrome dropped ---
OZ='╭────────────╮
│ MODEL ID   │ NOTE        │
╞════════════╡
│ claude-x   │ big model   │
│ gpt-y      │ small       │
╰────────────╯'
norm="$(_catalog_normalize warp "$OZ")"
echo "$norm" | jq -e 'index("claude-x") and index("gpt-y") and (index("MODEL")|not) and (length==2)' >/dev/null 2>&1 \
  && ok "warp table: ids extracted, header/chrome dropped, no false rows" || bad "warp table parse wrong: $norm"

# --- empty Devin catalog normalizes to [] (fetch guard then refuses to cache it -> fail-open) ---
norm="$(_catalog_normalize dv '{"families":[]}')"
[ "$norm" = "[]" ] && ok "empty families -> []" || bad "empty families not []: $norm"
printf '%s' "$norm" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 \
  && bad "empty [] wrongly passes the non-empty cache guard" \
  || ok "empty [] fails the non-empty cache guard (fetch returns 1 -> fail-open)"

mkdir -p "$T/catalogs"
seed() { printf '%s' "$1" > "$T/catalogs/dv.json"; }
export OSRC_CATALOG_TTL=100000   # keep the seeded cache "fresh" so no live fetch fires

# --- _catalog_contains: present id matches (no pipefail/SIGPIPE false-negative), absent does not ---
seed '["glm-5.2","glm-5-2","deepseek-v4-pro-high","swe-1-7"]'
_catalog_contains dv "glm-5-2"      && ok "_catalog_contains: present id matches"        || bad "present id missed (SIGPIPE regression?)"
_catalog_contains dv "not-a-model"  && bad "_catalog_contains: absent id wrongly matched" || ok "_catalog_contains: absent id rejected"

# --- _catalog_validate: real id passes, bogus id dies (in a subshell so `die` can't kill the test) ---
( _catalog_validate dv "glm-5.2" ) >/dev/null 2>&1 && ok "_catalog_validate: real id passes" || bad "_catalog_validate wrongly rejected a real id"
( _catalog_validate dv "totally-bogus-xyz" ) >/dev/null 2>&1 && bad "_catalog_validate: bogus id wrongly passed" || ok "_catalog_validate: bogus id dies"

# --- escape hatch + empty-but-fresh cache must NOT brick a real id (fail-open on empty) ---
( OSRC_CATALOG_VALIDATE=0 _catalog_validate dv "totally-bogus-xyz" ) >/dev/null 2>&1 && ok "OSRC_CATALOG_VALIDATE=0 skips the gate" || bad "escape hatch did not skip"
seed '[]'
( _catalog_validate dv "glm-5.2" ) >/dev/null 2>&1 && ok "empty-but-fresh cache does NOT brick a real id (soft/fail-open)" || bad "empty cache bricked a valid id (poisoning regression)"

# --- Dynamic alias->variant resolution from a SEEDED structured catalog (no live CLI) ---
# Proves: cost-safe variant pick (Free over paid), version-aware family pick, effort folding, and
# that a NEW model resolves with zero code change. Seed both artifacts fresh so no fetch fires.
cat > "$T/catalogs/dv.raw.json" <<'RAW'
{"families":[
 {"family_uid":"glm-5.2","aliases":[],"variants":[{"model_uid":"glm-5-2","cost_summary":"Free"},{"model_uid":"glm-5-2-max","cost_summary":"$0.7 / MTok In"},{"model_uid":"glm-5-2-1m","cost_summary":"$0.7 / MTok In"}]},
 {"family_uid":"deepseek-v4-flash","aliases":[],"variants":[{"model_uid":"deepseek-v4-flash-high","cost_summary":"$0.14 / MTok In"}]},
 {"family_uid":"deepseek-v4-pro","aliases":[],"variants":[{"model_uid":"deepseek-v4-pro-low","cost_summary":"$1.74 / MTok In"},{"model_uid":"deepseek-v4-pro-high","cost_summary":"$1.74 / MTok In"},{"model_uid":"deepseek-v4-pro-max","cost_summary":"$1.74 / MTok In"}]},
 {"family_uid":"kimi-k3","aliases":[],"variants":[{"model_uid":"kimi-k3-high","cost_summary":"$3 / MTok In"},{"model_uid":"kimi-k3-max","cost_summary":"$3 / MTok In"}]},
 {"family_uid":"kimi-k2.7","aliases":[],"variants":[{"model_uid":"kimi-k2-7","cost_summary":"$0.95 / MTok In"}]},
 {"family_uid":"swe-1.7","aliases":[],"variants":[{"model_uid":"swe-1-7","cost_summary":"Free"}]},
 {"family_uid":"swe-1.7-lightning","aliases":["swe"],"variants":[{"model_uid":"swe-1-7-lightning","cost_summary":"$2.5 / MTok In"}]},
 {"family_uid":"brandnew-v1","aliases":[],"variants":[{"model_uid":"brandnew-v1-low","cost_summary":"Free"},{"model_uid":"brandnew-v1-high","cost_summary":"Free"}]}
]}
RAW
jq -r '[.families[].variants[].model_uid]' "$T/catalogs/dv.raw.json" > "$T/catalogs/dv.json"
export OSRC_CATALOG_VALIDATE=1 OSRC_DEVIN_DYNAMIC_RESOLVE=1

dr() { EFFORT="${2:-}"; _devin_resolve_model "$1"; }
rchk() { local got; got="$(dr "$1" "${3:-}")"; [ "$got" = "$2" ] && ok "resolve -m $1 (eff=${3:-none}) -> $got" || bad "resolve -m $1 -> got '$got' want '$2'"; }

rchk deepseek deepseek-v4-pro-high            # short alias, drops flash, high default
rchk deepseek deepseek-v4-pro-max max         # effort folds to the -max variant
rchk glm glm-5-2                              # Free base, NOT the paid -max / special -1m
rchk glm glm-5-2-max max                      # max effort -> max variant
rchk kimi kimi-k3-high                        # newest family (k3, not k2.7)
rchk swe swe-1-7                              # Free swe-1.7, NOT the paid -lightning
rchk deepseek-v4-pro deepseek-v4-pro-high    # family id -> variant
rchk glm-5-2-max glm-5-2-max                 # exact variant passes through
rchk brandnew-v1 brandnew-v1-high            # A NEW MODEL resolves with ZERO code change

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# test_devin_probe_strict.sh — the Devin health probe asks no consent, so it may only ping a model
# with STRICT proof of Free (the spend gate's own _osrc_devin_free_for_spend, or the exact literal
# glm-5-2). The free LABEL never fires on a glob or bare alias, and both Free-set builders share one
# freshness rule and one catalog parse per catalog mtime (torture-room security F1, pattern F1/F5,
# performance F2/F3). Hermetic: own OSRC_HOME, no devin on PATH unless a stub is installed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 -> got:'$2' want:'$3'"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/catalogs" "$T/off" "$T/userhome"
export HOME="$T/userhome"
REALJQ="$(command -v jq)"
# jq shim: counts every parse of the raw Devin catalog, then runs the real jq.
cat > "$T/bin/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *dv.raw.json) echo x >> "$T/rawparses" ;; esac; done
exec "$REALJQ" "\$@"
EOF
cat > "$T/bin/devin" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do [ "\$1" = --model ] && echo "\$2" >> "$T/devin.models"; shift; done
echo PONG
EOF
chmod +x "$T/bin/jq" "$T/bin/devin"
cat > "$T/home/catalogs/dv.raw.json" <<'JSON'
{"families":[
 {"family_uid":"swe-2-flash","variants":[{"model_uid":"swe-2-flash-high","cost_tier":"Free"},
   {"model_uid":"swe-2-flash-high-lightning","cost_tier":"Med cost"},{"model_uid":"swe-2-flash-max-lightning","cost_tier":"Med cost"}]},
 {"family_uid":"glm-5.3","variants":[{"model_uid":"glm-5-3-flash-high","cost_tier":"Low cost"},{"model_uid":"glm-5-3-max","cost_tier":"Low cost"}]},
 {"family_uid":"kimi-k3","variants":[{"model_uid":"kimi-k3-high","cost_tier":"High cost"}]},
 {"family_uid":"x","variants":[{"model_uid":"x-high","cost_tier":"Free"}]}
]}
JSON
echo '["swe-2-flash-high","x-high"]' > "$T/home/catalogs/dv.json"

# run <home> <ttl> <snippet> : source the engine hermetically and run a snippet.
run() {
  OSRC_HOME="$1" OSRC_CATALOG_TTL="$2" PATH="$T/bin:$PATH" OSRC_EXCLUDE_MODELS="${EXCL:-}" \
    bash -c 'OSRC_SOURCED=1 . "'"$SRC"'" >/dev/null 2>&1; '"$3" 2>/dev/null
}
PAID="swe-2-flash-high-lightning swe-2-flash-max-lightning glm-5-3-flash-high glm-5-3-max kimi-k3 swe-1.7-lightning swe"

# 1. offline (no catalog, devin absent from the catalog's point of view): every paid/alias id is skipped
for m in $PAID; do
  eq "offline probe skips $m" "$(run "$T/off" 300 "_devin_probe_pick $m")" glm-5-2
  eq "offline: $m not labelled free" "$(run "$T/off" 300 "_devin_is_free_model $m && echo free || echo paid")" paid
done
eq "offline probe keeps proven swe-2-high" "$(run "$T/off" 300 '_devin_probe_pick swe-2-high')" swe-2-high
eq "glm excluded -> offline-proven swe-2-high" "$(EXCL=glm run "$T/off" 300 '_devin_probe_pick swe-2-flash-max-lightning')" swe-2-high

# 2. fresh catalog: only exact cost_tier=Free ids are probeable
for m in $PAID; do
  eq "fresh catalog probe skips $m" "$(run "$T/home" 999999 "_devin_probe_pick $m")" glm-5-2
done
eq "fresh catalog: Free x-high probeable" "$(run "$T/home" 999999 '_devin_probe_pick x-high')" x-high

# 3. env override end to end: _devin_free_probe with a stub devin never sends a paid --model
: > "$T/devin.models"
OSRC_DEVIN_PROBE_MODEL=swe-2-flash-high-lightning run "$T/home" 999999 '_devin_free_probe >/dev/null'
eq "doctor probe with paid OSRC_DEVIN_PROBE_MODEL pings glm-5-2" "$(cat "$T/devin.models")" glm-5-2

# 4. stale catalog: neither builder proves Free from it (one freshness rule)
cp -R "$T/home" "$T/stale"; touch -t 202001010000 "$T/stale/catalogs/dv.json" "$T/stale/catalogs/dv.raw.json"
eq "stale catalog: x-high not labelled free" "$(run "$T/stale" 60 '_devin_is_free_model x-high && echo free || echo paid')" paid
eq "stale catalog: x-high not free for spend" "$(run "$T/stale" 60 '_osrc_devin_free_for_spend x-high && echo free || echo paid')" paid

# 5. one raw-catalog parse per mtime, memo kept in the parent shell
rm -f "$T/rawparses" "$T/home/.devin-free-ids"
out="$(run "$T/home" 999999 'for i in 1 2 3 4 5 6 7 8 9 10; do _devin_is_free_model claude-x; done
  a="$(_osrc_devin_free_for_spend x-high && echo y)"; b="$(_devin_default_free_model)"
  printf "%s|%s|%s" "$a" "$b" "${_OSRC_CAT_FREE_SRC:+memo}"')"
eq "10 label + spend + default lookups" "$out" "y|x-high|memo"
eq "raw catalog parsed once" "$(wc -l < "$T/rawparses" 2>/dev/null | tr -d ' ')" 1
rm -f "$T/rawparses"
run "$T/home" 999999 '_devin_is_free_model claude-x; _osrc_devin_free_for_spend x-high' >/dev/null
eq "next process, same mtime: zero raw parses" "$( [ -f "$T/rawparses" ] && wc -l < "$T/rawparses" | tr -d ' ' || echo 0)" 0

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# test_trusted_lanes.sh — per-lane / per-repo trust for the credential-FILE hard-block.
#
# The posture being pinned: the gate is fail-closed for everyone by default, and a grant is scoped to
# ONE lane in ONE repo. The dangerous shape is a grant that travels — to another repo, to another lane,
# or into a child process — because the operator reasons about the repo in front of them, not about
# every process their shell will later spawn. Every test below is about a grant NOT travelling.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/cfg" OSRC_HOME="$TMP/osrc"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

TRUSTED="$TMP/trusted-repo";   mkdir -p "$TRUSTED"
OTHER="$TMP/other-repo";       mkdir -p "$OTHER"
NEIGHBOR="$TMP/trusted-repo-two"; mkdir -p "$NEIGHBOR"   # prefix-collision probe
mkdir -p "$XDG_CONFIG_HOME/outsourcerer"
CF="$XDG_CONFIG_HOME/outsourcerer/trusted-lanes.json"

have_jq=1; command -v jq >/dev/null 2>&1 || have_jq=0

# --- Default posture: no config at all. ---
cd "$TRUSTED" || exit 1
_lane_trusted_for_pwd devin && bad "no config still granted trust (must fail closed)" \
  || ok "no config -> no trust (default stays fail-closed)"

printf '{"devin": ["%s"]}\n' "$TRUSTED" > "$CF"

if [ "$have_jq" = "0" ]; then
  echo "SKIP: jq absent — trust resolution requires it (and correctly denies without it)"
  cd "$TRUSTED" && { _lane_trusted_for_pwd devin && bad "granted trust without jq" || ok "no jq -> denies (fails closed)"; }
else
  # --- The grant works where it was written. ---
  cd "$TRUSTED" || exit 1
  _lane_trusted_for_pwd devin && ok "trusted lane in its own repo -> trusted" || bad "trusted repo not honored"

  # --- and does not travel. ---
  _lane_trusted_for_pwd cc && bad "trust leaked to a DIFFERENT lane in the same repo" \
    || ok "grant is per-lane: another lane in the same repo is still blocked"

  mkdir -p "$TRUSTED/src/deep"; cd "$TRUSTED/src/deep" || exit 1
  _lane_trusted_for_pwd devin && ok "trust covers subdirectories of the trusted repo" || bad "subdir of trusted repo denied"

  cd "$OTHER" || exit 1
  _lane_trusted_for_pwd devin && bad "trust leaked to an UNLISTED repo" \
    || ok "grant is per-repo: the same lane elsewhere is still blocked"

  # A trusted "/x/trusted-repo" must not confer trust on the sibling "/x/trusted-repo-two".
  cd "$NEIGHBOR" || exit 1
  _lane_trusted_for_pwd devin && bad "string-prefix match granted trust to a sibling repo" \
    || ok "path match is boundary-aware (a sibling sharing a name prefix is not trusted)"

  # A symlink pointing INTO a trusted repo resolves to it; one pointing elsewhere must not inherit it.
  ln -s "$OTHER" "$TMP/sneaky" 2>/dev/null
  if cd "$TMP/sneaky" 2>/dev/null; then
    _lane_trusted_for_pwd devin && bad "a symlink to an untrusted repo was granted trust" \
      || ok "paths are resolved through symlinks before matching"
  fi

  # --- Malformed / hostile config must deny, never fail open. ---
  cd "$TRUSTED" || exit 1
  printf 'not json at all {{{' > "$CF"
  _lane_trusted_for_pwd devin && bad "malformed config granted trust (failed OPEN)" \
    || ok "malformed config denies (fails closed)"
  printf '{"devin": "%s"}\n' "$TRUSTED" > "$CF"   # string where a list belongs
  _lane_trusted_for_pwd devin && bad "wrong-typed config granted trust" \
    || ok "wrong-typed config denies (fails closed)"
  printf '{"devin": [null, 42]}\n' > "$CF"
  _lane_trusted_for_pwd devin && bad "non-string entries granted trust" \
    || ok "non-string config entries are ignored, not coerced"
  printf '{"devin": ["%s"]}\n' "$TRUSTED" > "$CF"  # restore
fi

# --- The per-invocation grant, and the thing it must never do: be inherited. ---
cd "$OTHER" || exit 1
OSRC_TRUST_LANE_ONCE=" devin " _lane_trusted_for_pwd devin \
  && ok "--trust-lane grants for this invocation" || bad "--trust-lane did not grant"
OSRC_TRUST_LANE_ONCE=" devin " _lane_trusted_for_pwd cc \
  && bad "--trust-lane leaked to another lane" || ok "--trust-lane is scoped to the named lane only"
grep -qE 'export[[:space:]]+OSRC_TRUST_LANE_ONCE' "$SRC" \
  && bad "OSRC_TRUST_LANE_ONCE is exported — a child job would inherit the grant" \
  || ok "the per-invocation grant is never exported (children re-evaluate their own repo)"

# --- Source-level posture checks. ---
grep -q 'trusted-lanes.json' "$SRC" && ok "trust config path documented in source" || bad "config path missing"
grep -q 'credential-file scan SKIPPED' "$SRC" \
  && ok "a skipped credential scan is announced in the disclosure banner (never silent)" \
  || bad "no disclosure line when the scan is skipped"
# Trust covers the repo's own credential FILES. It must not also wave through a live secret VALUE
# pasted into a prompt — a different decision the operator never made.
awk '/^_secret_scan\(\)/,/^}/' "$SRC" | grep -q 'OSRC_SECRET_ALLOW_VALUE' \
  && ok "pasted-VALUE hard-block still present in _secret_scan (not covered by trust)" \
  || bad "value hard-block missing from _secret_scan"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

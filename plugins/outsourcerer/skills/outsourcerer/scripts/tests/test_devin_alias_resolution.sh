#!/usr/bin/env bash
# Regression: every documented cross-lane alias accepted by the Devin provider must
# reach `devin --model` as a real Devin model id, never as the raw alias.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# The fake implements the two preflight calls the lane makes: `auth status` and
# the actual invocation. It records only the argument following --model, so the
# assertions below inspect precisely what the external CLI received.
cat > "$TMP/bin/devin" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  echo "Logged in"
  exit 0
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--model" ]; then
    printf '%s\n' "${2:-}" > "$DEVIN_CAPTURE"
    printf '%s\n' "${2:-}"
    exit 0
  fi
  shift
done
exit 1
EOF
chmod +x "$TMP/bin/devin"

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Source the lane implementation without calling the script dispatcher. This deliberately
# exercises the Devin entrypoint with PROVIDER=devin: the top-level router can legitimately
# choose another native lane for some aliases, but it must never make the Devin CLI receive one.
TMP_SRC="$TMP/outsourcerer-source.sh"
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$TMP_SRC"
# shellcheck disable=SC1090
export PATH="$TMP/bin:$PATH" HOME="$TMP" OSRC_HOME="$TMP/osrc" OUTSOURCERER_DEPTH=0
source "$TMP_SRC"
PROVIDER=devin

check() {
  local alias="$1" expected="$2" got out rc capture
  capture="$TMP/$alias.model"
  out="$(DEVIN_CAPTURE="$capture" delegate auto "" -m "$alias" "reply PONG" 2>&1)"
  rc=$?
  got="$(cat "$capture" 2>/dev/null)"
  if [ "$rc" -eq 0 ] && [ "$got" = "$expected" ]; then
    ok "Devin provider -m $alias launches valid Devin id $expected"
  else
    bad "Devin provider -m $alias launched '${got:-<nothing>}' (expected $expected; rc=$rc): $out"
  fi
  case "$got" in "$alias") bad "raw alias '$alias' reached devin" ;; esac
}

check glm glm-5.2
check sol gpt-5.6-sol
check terra gpt-5.6-terra
check swe swe-1.7

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

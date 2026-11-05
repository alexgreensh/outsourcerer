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
check glm-5-2 glm-5.2
check sol gpt-5.6-sol
check terra gpt-5.6-terra
# Owner decision 2026-11-05: every short SWE alias runs Devin's free swe-2-flash-high.
check swe swe-2-flash-high
check swe-2 swe-2-flash-high
check swe-1.7 swe-2-flash-high
check swe-1-7 swe-2-flash-high
check SWE swe-2-flash-high

# An exact (fully-qualified) id is never rewritten.
exact() {
  local id="$1" got capture="$TMP/exact-$1.model"
  DEVIN_CAPTURE="$capture" delegate auto "" -m "$id" "reply PONG" >/dev/null 2>&1
  got="$(cat "$capture" 2>/dev/null)"
  [ "$got" = "$id" ] && ok "exact id -m $id launches itself" || bad "exact id -m $id launched '${got:-<nothing>}'"
}
for id in swe-2-flash-medium swe-2-flash-high swe-2-flash-max swe-2-high swe-2-medium swe-2-max swe-1.7-lightning; do
  exact "$id"
done

# Alias table rows (what route_delegate sets RESOLVED_ID/lane/tier from).
row() { [ "$(resolve_model_row "$1")" = "$2" ] && ok "table: $1 -> $2" || bad "table: $1 -> '$(resolve_model_row "$1")' (want $2)"; }
for a in swe swe-2 swe-1.7 swe-1-7; do row "$a" "swe-2-flash-high|dv|capable"; done
for id in swe-2-flash-medium swe-2-flash-high swe-2-flash-max; do row "$id" "$id|dv|capable"; done
row swe-1.7-lightning "swe-1.7-lightning|dv|mid"
[ "$(_devin_model_for swe)" = "swe-2-flash-high" ] && ok "sibling map: swe -> swe-2-flash-high" || bad "sibling map: swe -> '$(_devin_model_for swe)'"
[ -z "$(_devin_model_for swe-2-high)" ] && ok "sibling map leaves exact swe-2-high alone" || bad "sibling map rewrote swe-2-high"

# The swe-1.7 write-verb warning must not fire for the new default, through the real `edit` command.
R="$TMP/repo"; mkdir -p "$R"
( cd "$R" && git init -q && printf 'x\n' > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
warn_out="$(cd "$R" && DEVIN_CAPTURE="$TMP/e2e.model" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 bash "$SRC" --provider devin edit -m swe "fix it" </dev/null 2>&1)"
[ "$(cat "$TMP/e2e.model" 2>/dev/null)" = "swe-2-flash-high" ] && ok "edit -m swe launches swe-2-flash-high" || bad "edit -m swe launched '$(cat "$TMP/e2e.model" 2>/dev/null)': $warn_out"
printf '%s' "$warn_out" | grep -q 'not reliable for edit' && bad "swe-1.7 write warning fired for the swe default" || ok "no swe-1.7 write warning for the swe default"
# Control: the warning still fires for an id that resolves to literally swe-1.7 (models.local override).
mkdir -p "$OSRC_HOME"; printf 'swe-1.7|swe-1.7|dv|capable\n' > "$OSRC_HOME/models.local"
warn_out="$(cd "$R" && DEVIN_CAPTURE="$TMP/e2e2.model" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 bash "$SRC" --provider devin edit -m swe-1.7 "fix it" </dev/null 2>&1)"
printf '%s' "$warn_out" | grep -q 'not reliable for edit' && ok "control: warning still fires for a literal swe-1.7 route" || bad "control: warning missing for literal swe-1.7: $warn_out"
rm -f "$OSRC_HOME/models.local"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

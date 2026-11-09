#!/usr/bin/env bash
# test_opencode_lane.sh — the OpenCode Go engine lane (--provider opencode) must be registered,
# reach `opencode run` with flags the CLI accepts, keep every Go request billing the Go plan (never
# silently Zen), close stdin (a non-TTY `opencode run` with open stdin hangs), enforce read-only
# posture via a per-run OPENCODE_CONFIG_CONTENT deny list, and classify its three failure families
# (per-model region refusal, expired-key auth failure, plan-limit phrasing) the way the repo's
# lane-down/refusal conventions require. A fake `opencode` on PATH records argv + the env var +
# whether stdin was closed, so nothing real runs and no plan is spent.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
bash -n "$SCRIPT_DIR/../lane-opencode.sh" || { echo "FAIL: lane-opencode.sh bash -n failed"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-oc.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home" OSRC_HEARTBEAT_DISABLED=1; mkdir -p "$OSRC_HOME" "$TMP/bin" "$TMP/work" "$TMP/nohome"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# Fake opencode. Behavior knobs (env): OSRC_FAKE_OC_MODE = ok|region|expired|limit|limitacct|t429,
# OSRC_FAKE_OC_NOAUTH=1 makes `auth list` show only the Zen credential,
# OSRC_FAKE_OC_VER overrides --version output (default 2.2.6; set '' for unparseable).
cat > "$TMP/bin/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/rawargv"
[ "\$1" = "--standalone" ] && shift   # v2.x private-server flag before the subcommand
case "\$1" in
  --version|-v) echo "\${OSRC_FAKE_OC_VER-2.2.6}"; exit 0 ;;
  auth) [ "\${2:-}" = "list" ] && { if [ "\${OSRC_FAKE_OC_NOAUTH:-0}" = "1" ]; then echo "OpenCode api"; else echo "OpenCode Go api"; fi; exit 0; } ;;
  models) echo "opencode-go/glm-5.3"; echo "opencode-go/glm-5.3-flash"; echo "opencode/some-free"; exit 0 ;;
  run)
    printf '%s\n' "\$@" > "$TMP/argv"
    printf '%s' "\${OPENCODE_CONFIG_CONTENT:-UNSET}" > "$TMP/occfg"
    read -t 1 -r _x <&0 2>/dev/null; printf '%s' "\$?" > "$TMP/stdinrc"
    case "\${OSRC_FAKE_OC_MODE:-ok}" in
      region)    echo "This Go model is hosted outside Europe and the United States. Select Global at https://opencode.ai/console/.../settings/privacy#regions to use it." >&2; exit 1 ;;
      expired)   echo "This API key has expired. Create a new API key in OpenCode Console." >&2; exit 1 ;;
      limit)     echo "error: usage limit exceeded for this model; try another" >&2; exit 1 ;;
      limitacct) echo "error: account-wide 5-hour usage limit exceeded across all models; resets in 3h" >&2; exit 1 ;;
      t429)      echo "Error: HTTP 429 too many requests" >&2; exit 1 ;;
      *)         echo "OPENCODE_OK"; exit 0 ;;
    esac ;;
esac
echo "opencode stub: unhandled args: \$*" >&2; exit 2
EOF
chmod +x "$TMP/bin/opencode"

run() { ( cd "$TMP/work" && env -u OSRC_FAKE_OC_MODE -u OSRC_FAKE_OC_NOAUTH PATH="$TMP/bin:$PATH" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode "$@" 2>"$TMP/err" ); }
argv() { tr '\n' ' ' < "$TMP/argv" 2>/dev/null; }
src_fn() { ( export OSRC_SOURCED=1 PATH="$TMP/bin:$PATH"; source "$SRC" >/dev/null 2>&1; "$@" ); }

echo "=== registration ==="
( export OSRC_SOURCED=1; source "$SRC" >/dev/null 2>&1
  case " $OSRC_LANE_REGISTRY " in *" opencode "*) exit 0 ;; *) exit 1 ;; esac ) && ok "opencode is in the lane registry" || no "opencode missing from the registry"
src_fn _lane_field opencode dispatch | grep -q '^delegate_opencode$' && ok "descriptor dispatches to delegate_opencode" || no "descriptor dispatch wrong"
[ "$(src_fn _lane_by_provider opencode)" = "opencode" ] && ok "provider resolves to the opencode lane" || no "provider resolution wrong"
[ "$(src_fn _lane_field opencode disp)" = "opencode" ] && ok "descriptor disp field is opencode" || no "disp field wrong"
grep -q 'grokbot|opencode' "$SRC" && ok "opencode is listed in the provider help" || no "provider help lacks opencode"
src_fn _lane_field opencode is_cloud | grep -q '^yes$' && ok "lane is marked cloud (prompt leaves the machine)" || no "is_cloud missing"

echo "=== model normalization (the Go billing guarantee) ==="
[ "$(src_fn _opencode_model glm-5.3-flash)" = "opencode-go/glm-5.3-flash" ] && ok "a bare Go id gets the opencode-go/ prefix" || no "bare-id prefixing wrong"
[ "$(src_fn _opencode_model opencode-go/kimi-k3.1-pro)" = "opencode-go/kimi-k3.1-pro" ] && ok "a full opencode-go/ id passes verbatim" || no "full id rewritten"
src_fn _opencode_model 'opencode/some-free' >/dev/null 2>&1 && no "a Zen -free id passed without the opt-in" || ok "a Zen -free id is refused without OSRC_OPENCODE_ALLOW_NONGO (catalog membership is not a \$0 price)"
src_fn _opencode_model 'opencode-go/' >/dev/null 2>&1 && no "an empty opencode-go/ id normalized" || ok "opencode-go/ with an empty id is refused"
src_fn _opencode_model 'a//b' >/dev/null 2>&1 && no "a // path normalized" || ok "a token with // is refused"
src_fn _opencode_model 'opencode/nothere-free' >/dev/null 2>&1 && no "an unlisted -free id passed on suffix trust" || ok "every opencode/* id is refused without the opt-in (suffix is not a billing guarantee)"
rm -f "$TMP/argv"
out="$(run run -m opencode/glm-5.3 'x' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'not an OpenCode Go model' "$TMP/err" && [ ! -f "$TMP/argv" ] \
  && ok "opencode/<id> (Zen pay-as-you-go) is refused before dispatch" || no "Zen id not refused rc=$rc err=$(tail -2 "$TMP/err")"
[ ! -f "$TMP/argv" ] && ok "the refused Zen run never reached the CLI" || no "Zen id reached the CLI"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 OSRC_OPENCODE_ALLOW_NONGO=1 "$SRC" --provider opencode run -m opencode/glm-5.3 'x' 2>"$TMP/err" )"
case "$(argv)" in *"-m opencode/glm-5.3"*) ok "OSRC_OPENCODE_ALLOW_NONGO=1 is the explicit opt-in (verbatim id)" ;; *) no "opt-in did not pass the id: [$(argv)]" ;; esac
[ "$(src_fn lane_from_name opencode-go/deepseek-v4.1-flash)" = "opencode" ] && ok "an explicit opencode-go/ model routes to the lane without --provider" || no "family_globs routing missing"
[ "$(src_fn lane_from_name opencode-go/claude-sonnet-4.6)" = "opencode" ] && ok "an opencode-go/ id whose tail matches another lane's family still routes to opencode" || no "opencode-go/ id shadowed by a substring glob"
[ "$(src_fn lane_from_name opencode/mega-free)" = "opencode" ] && ok "an explicit opencode/ Zen id also routes here (to be refused or allowed correctly)" || no "opencode/ prefix does not route to the lane"

echo "=== no -m is a user error, not a silent default ==="
out="$(run run 'x' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'needs -m <go-model-id>' "$TMP/err" && ok "--provider opencode without -m dies naming the fix" || no "missing -m not caught rc=$rc"

echo "=== run (read-only): stdin closed, plan agent, per-run denies ==="
rm -f "$TMP/argv" "$TMP/occfg" "$TMP/stdinrc"
out="$(run run -m glm-5.3-flash 'reply ok')"; rc=$?
[ "$rc" -eq 0 ] && case "$out" in *OPENCODE_OK*) true ;; *) false ;; esac && ok "a run returns opencode's answer" || no "run rc=$rc out=[$(printf '%s' "$out" | tail -3)] err=$(tail -3 "$TMP/err")"
a="$(argv)"
head -1 "$TMP/rawargv" 2>/dev/null | grep -qx -- '--standalone' && ok "v2 dispatch uses --standalone (the shared server would ignore the per-run config)" || no "missing --standalone: [$(tr '\n' ' ' < "$TMP/rawargv" 2>/dev/null | head -c 80)]"
case "$a" in *"--agent plan"*"opencode-go/glm-5.3-flash"*|*"opencode-go/glm-5.3-flash"*"--agent plan"*)
  ok "run dispatches 'opencode run --agent plan -m opencode-go/<id>'" ;; *) no "run argv wrong: [$a]" ;; esac
grep -qx -- '--' "$TMP/argv" && ok "the prompt is protected by a -- separator" || no "no -- before the prompt"
cfg="$(cat "$TMP/occfg" 2>/dev/null)"
case "$cfg" in *'"action":"*","resource":"*","effect":"deny"'*'"action":"read","resource":"*","effect":"allow"'*) ok "read-only config denies EVERYTHING then re-allows the read family" ;; *) no "read-only config lacks the deny-all+read-allow ruleset: [$cfg]" ;; esac
# the policies layer (applied AFTER agent rules + saved approvals) carries the same deny/allow set
printf '%s' "$cfg" | jq -e '[.policies[]]|.[0]=={"action":"tool.use","resource":"*","effect":"deny"}' >/dev/null 2>&1 \
  && ok "policies opens with a tool.use deny-all (agent rules cannot reopen writes)" || no "policies deny-all missing: [$cfg]"
printf '%s' "$cfg" | jq -e '[.policies[].resource]|index("read:*") < index("read:*.env") and index("read:*.env") < index("read:*.env.example")' >/dev/null 2>&1 \
  && ok "policies: read:* allow is followed by *.env denies then the .env.example exception" || no "policies env ordering wrong: [$cfg]"
printf '%s' "$cfg" | jq -e '[.permissions[]|select(.action=="read")|.resource]|index("*") < index("*.env") and index("*.env") < index("*.env.example")' >/dev/null 2>&1 \
  && ok "permissions: *.env re-denied after the broad read allow (the built-in ask is restored as a deny)" || no "permissions env ordering wrong: [$cfg]"
[ "$(cat "$TMP/stdinrc" 2>/dev/null)" = "1" ] && ok "stdin is closed (</dev/null) — the non-TTY hang is impossible" || no "stdin not closed (read rc=$(cat "$TMP/stdinrc" 2>/dev/null))"

echo "=== edit / yolo: build agent + --auto; research refuses (no sandbox) ==="
rm -f "$TMP/argv" "$TMP/occfg"
run edit -m glm-5.3-flash "fix it" >/dev/null; a="$(argv)"
case "$a" in *"--agent build"*"--auto"*) ok "edit uses the build agent with --auto" ;; *) no "edit argv wrong: [$a]" ;; esac
cfg="$(cat "$TMP/occfg" 2>/dev/null)"
case "$cfg" in *'"action":"*","resource":"*","effect":"allow"'*'"action":"external_directory","resource":"*","effect":"deny"'*) ok "edit is scoped: everything allowed INSIDE the job dir, outside denied" ;; *) no "edit config wrong: [$cfg]" ;; esac
printf '%s' "$cfg" | jq -e '[.policies[]|select(.action=="tool.use" and .effect=="deny")|.resource]|index("external_directory:*") != null' >/dev/null 2>&1 \
  && ok "edit hard-denies external_directory at the policy layer (agent rules cannot reopen it)" || no "edit policies external_directory deny missing: [$cfg]"
printf '%s' "$cfg" | jq -e '[.policies[].resource]|index("read:*.env") != null and index("read:*.env.example") != null' >/dev/null 2>&1 \
  && ok "edit keeps *.env denied but .env.example readable" || no "edit policies env rules missing: [$cfg]"
grep -q "MUTATING" "$TMP/err" && grep -q "shell runs with full user rights" "$TMP/err" && ok "the banner says edit mutates and shell is NOT contained" || no "banner honesty missing: $(grep MUTATING "$TMP/err" | head -1)"
out="$(run research -m glm-5.3-flash 'x' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NO OS sandbox' "$TMP/err" && ok "research refuses honestly (opencode has no sandbox)" || no "research not refused rc=$rc"
rm -f "$TMP/argv"
run yolo -m glm-5.3-flash "go" >/dev/null 2>&1; a="$(argv)"
case "$a" in *"--agent build"*"--auto"*) ok "yolo also dispatches build + --auto" ;; *) no "yolo argv wrong: [$a]" ;; esac
case "$(cat "$TMP/occfg" 2>/dev/null)" in *'"effect":"deny"'*) no "yolo must not carry any deny" ;; *'"action":"*","resource":"*","effect":"allow"'*) ok "yolo pre-allows all permissions in the per-run config" ;; *) no "yolo config: [$(cat "$TMP/occfg" 2>/dev/null)]" ;; esac

echo "=== effort -> model#variant (v2) ==="
rm -f "$TMP/argv"
run run -m glm-5.3-flash --effort high "x" >/dev/null
case "$(argv)" in *"-m opencode-go/glm-5.3-flash#high"*) ok "--effort high maps to -m <id>#high on v2" ;; *) no "variant missing: [$(argv)]" ;; esac
[ "$(src_fn _opencode_effort max)" = "max" ] && [ "$(src_fn _opencode_effort junk)" = "" ] && ok "the effort map itself is sane" || no "effort map wrong"

echo "=== failure classification ==="
# OSRC_FAILOVER_MAX=0 pins the run to the opencode lane: otherwise a confirmed refusal hops lanes
# and this test box's real CLIs could answer (and spend a plan) — the signal-write contract itself
# is checked statically below.
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=region OSRC_FAILOVER_MAX=0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m deepseek-v4.1-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'Global' && printf '%s' "$out" | grep -qi 'region' \
  && ok "a region refusal surfaces the Select-Global console instruction" || no "region refusal handling rc=$rc out=$(printf '%s' "$out" | tail -3)"
[ ! -f "$OSRC_HOME/lane-posture/opencode.down" ] && ok "region refusal does NOT mark the lane down (it is per-model)" || no "region refusal wrongly marked the lane down"
grep -q '_failover_signal_write opencode "$m" confirmed' "$SCRIPT_DIR/../lane-opencode.sh" \
  && ok "region/auth refusal writes a confirmed failover signal (another model may be tried)" || no "no failover signal write in the lane"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=expired OSRC_FAILOVER_MAX=0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'expired' && ok "an expired key surfaces the renewal instruction" || no "expired key handling rc=$rc"
[ -f "$OSRC_HOME/lane-posture/opencode.down" ] && ok "expired key marks THIS lane down (auth failure, other lanes unaffected)" || no "expired key did not mark the lane down"
rm -f "$OSRC_HOME/lane-posture/opencode.down" 2>/dev/null

echo "=== plan-limit: per-model semantics ==="
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=limit OSRC_FAILOVER_MAX=0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'plan limit' && ok "a per-model limit refusal reaches the plan-limit path" || no "limit refusal unclassified rc=$rc out=$(printf '%s' "$out" | tail -3)"
[ ! -f "$OSRC_HOME/lane-posture/opencode.down" ] && ok "refused model + refused probe stays a MODEL refusal — lane NOT marked down" || no "per-model limit wrongly marked the lane down"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=limitacct OSRC_FAILOVER_MAX=0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && [ -f "$OSRC_HOME/lane-posture/opencode.down" ] && ok "an account-wide window confirmed by the probe marks the lane DOWN" || no "account-wide limit did not mark the lane rc=$rc"
rm -f "$OSRC_HOME/lane-posture/opencode.down" 2>/dev/null

echo "=== generic 429 is transport, not a plan limit ==="
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=t429 OSRC_FAILOVER_MAX=0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -qi 'plan limit' && [ ! -f "$OSRC_HOME/lane-posture/opencode.down" ] \
  && ok "a bare 429/throttle is left to transport handling (no probe, no mark)" || no "429 misclassified rc=$rc out=$(printf '%s' "$out" | tail -2)"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=ok OSRC_FAILOVER_MAX=0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'assert that the rate limit should be rendered' 2>&1 )"
! printf '%s' "$out" | grep -qi 'plan limit' && ok "task prose about rate limits never triggers the detector" || no "task prose false-positive"

echo "=== probe verdicts (model-scoped refusals) ==="
[ "$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=region OSRC_HOME="$OSRC_HOME" bash -c "OSRC_SOURCED=1; source '$SRC' >/dev/null 2>&1; _opencode_free_probe glm-5.3" )" = "model-refused" ] \
  && ok "a region-refused probe returns model-refused (never lane-down)" || no "probe region verdict wrong"
[ "$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=limit OSRC_HOME="$OSRC_HOME" bash -c "OSRC_SOURCED=1; source '$SRC' >/dev/null 2>&1; _opencode_free_probe glm-5.3" )" = "model-refused" ] \
  && ok "a per-model-limited probe returns model-refused" || no "probe per-model verdict wrong"
[ "$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=limitacct OSRC_HOME="$OSRC_HOME" bash -c "OSRC_SOURCED=1; source '$SRC' >/dev/null 2>&1; _opencode_free_probe glm-5.3" )" = "limit-refused" ] \
  && ok "an account-wide-worded probe returns limit-refused" || no "probe account-wide verdict wrong"
[ "$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_MODE=ok OSRC_HOME="$OSRC_HOME" bash -c "OSRC_SOURCED=1; source '$SRC' >/dev/null 2>&1; _opencode_free_probe glm-5.3" )" = "answered" ] \
  && ok "a healthy probe returns answered" || no "probe answered verdict wrong"

echo "=== version handling ==="
rm -f "$TMP/argv"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_VER= OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'unparseable\|cannot parse' && [ ! -f "$TMP/argv" ] \
  && ok "an unparseable version refuses the read-only tier (fail closed)" || no "unparseable version fell open rc=$rc"
rm -f "$TMP/argv"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_VER=3.0.0 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/argv" ] && ok "an unknown v3 also refuses read-only (unknown major is not guessed)" || no "v3 fell open rc=$rc"
rm -f "$TMP/argv" "$TMP/occfg" "$TMP/rawargv"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_VER=1.19.5 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash --effort high 'x' 2>&1 )"
! head -1 "$TMP/rawargv" 2>/dev/null | grep -qx -- '--standalone' && ok "v1 dispatch has no --standalone" || no "v1 wrongly used --standalone"
case "$(argv)" in *"--variant high"*) ok "v1 maps effort to --variant" ;; *) no "v1 effort missing: [$(argv)]" ;; esac
case "$(cat "$TMP/occfg" 2>/dev/null)" in *'"permission":'*'deny'*) ok "v1 emits the permission-map schema" ;; *) no "v1 config wrong: [$(cat "$TMP/occfg" 2>/dev/null | head -c 120)]" ;; esac
case "$(cat "$TMP/occfg" 2>/dev/null)" in *'policies'*) no "v1 must not emit policies" ;; *) ok "v1 config carries no policies key (that layer does not exist)" ;; esac

echo "=== jq guards fail closed ==="
grep -q '! have jq' "$SCRIPT_DIR/../lane-opencode.sh" && ok "the bundle-carving jq requirement is in the source" || no "missing the jq requirement for staged bundles"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/jq" && chmod +x "$TMP/bin/jq"
rm -f "$TMP/argv"
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'unenforced\|not valid JSON' && [ ! -f "$TMP/argv" ] && ok "a failing jq on the config validator refuses before dispatch" || no "broken-jq fell open rc=$rc out=$(printf '%s' "$out" | tail -3)"
rm -f "$TMP/bin/jq"

echo "=== non-Go opt-in does not need Go credentials ==="
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_NOAUTH=1 OSRC_OPENCODE_ALLOW_NONGO=1 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m opencode/some-free 'x' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "ALLOW_NONGO=1 + no Go credential still dispatches (the opt-in provider's own auth applies)" || no "non-Go opt-in wrongly demanded Go auth rc=$rc out=$(printf '%s' "$out" | tail -2)"

echo "=== ledger ==="
rm -f "$OSRC_HOME/ledger.jsonl"
run run -m glm-5.3-flash "ledger check" >/dev/null
grep -q '"lane":"opencode"\|opencode' "$OSRC_HOME/ledger.jsonl" 2>/dev/null && grep -q 'opencode-go/glm-5.3-flash' "$OSRC_HOME/ledger.jsonl" \
  && ok "the ledger records lane=opencode with the resolved Go model id" || no "ledger row missing: $(cat "$OSRC_HOME/ledger.jsonl" 2>/dev/null | tail -1)"

echo "=== doctor / brief ==="
dout="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_DOCTOR_OFFLINE=1 "$SRC" doctor 2>&1 )"
printf '%s' "$dout" | grep -q 'OpenCode Go lane' && ok "doctor has an OpenCode Go lane section" || no "doctor lacks the section"
printf '%s' "$dout" | grep -q 'credential present' && ok "doctor sees the Go credential" || no "doctor missed the credential"
dout="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_NOAUTH=1 OSRC_DOCTOR_OFFLINE=1 "$SRC" doctor 2>&1 )"
printf '%s' "$dout" | grep -q 'NO OpenCode Go credential' && ok "doctor distinguishes a missing Go credential from a Zen one" || no "doctor missed the noauth state"
dout="$( cd "$TMP/work" && env -i PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/nohome" OSRC_HOME="$OSRC_HOME" OSRC_HEARTBEAT_DISABLED=1 TERM=dumb "$SRC" doctor 2>&1 )"
printf '%s' "$dout" | grep -q 'liveness: READY' && ok "doctor probes glm-5.3-flash and reports READY" || no "doctor probe did not report READY"
bout="$( cd "$TMP/work" && env -i PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/nohome" OSRC_HOME="$OSRC_HOME" OSRC_HEARTBEAT_DISABLED=1 TERM=dumb "$SRC" brief 2>&1 )"
printf '%s' "$bout" | grep -q 'opencode=go' && ok "brief advertises opencode=go when authed" || no "brief lacks the ready entry: $(printf '%s' "$bout" | tail -5)"

echo "=== auth gate ==="
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_FAKE_OC_NOAUTH=1 OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'OpenCode Go credential' && ok "a missing Go credential fails with the auth-login pointer" || no "auth gate missing rc=$rc"

echo "=== missing CLI (router seam) ==="
out="$( cd "$TMP/work" && PATH="/usr/bin:/bin" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode run -m glm-5.3-flash 'x' 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'opencode CLI not on PATH' && ok "a missing opencode fails loudly with the install hint" || no "missing-CLI path rc=$rc out=$(printf '%s' "$out" | tail -2)"
printf '%s' "$out" | grep -qE 'curl[^|]*\|[[:space:]]*(ba)?sh' && no "the install hint pipes a download to a shell" || ok "the install hint never pipes a download to a shell"

echo "=== fanout preflight ==="
out="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider opencode fanout -- "t1" "t2" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "lane 'opencode' needs a model for every job" && ok "fanout dies up front when a job has no model" || no "fanout model gate missing rc=$rc out=$(printf '%s' "$out" | tail -2)"

echo "=== bg + wait + status round trip ==="
( cd "$TMP/work" && git init -q 2>/dev/null && git -c user.email=t@t -c user.name=t commit -qm init --allow-empty 2>/dev/null; true )
jout="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_CLOUD_ACK=1 "$SRC" --provider opencode bg run -m glm-5.3-flash 'reply ok' 2>&1 )"
jid="$(printf '%s' "$jout" | grep -oE '[0-9]{8}-[0-9]{6}-[0-9a-f]+' | head -1)"
[ -n "$jid" ] && ok "bg launches a supervised job ($jid)" || no "bg did not launch: $(printf '%s' "$jout" | tail -3)"
if [ -n "$jid" ]; then
  wout="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" "$SRC" wait "$jid" 2>&1 )"; wrc=$?
  { [ "$wrc" -eq 0 ] || [ -f "$OSRC_HOME/jobs/$jid/out.log" ]; } \
    && ok "wait returns for the bg job (rc=$wrc)" || no "wait failed rc=$wrc"
  sout="$( cd "$TMP/work" && PATH="$TMP/bin:$PATH" "$SRC" status 2>&1 )"
  printf '%s' "$sout" | grep -q "$jid" && ok "status lists the job" || no "status missing $jid"
  grep -q 'opencode' "$OSRC_HOME/ledger.jsonl" 2>/dev/null && ok "the bg run lands in the ledger on the opencode lane" || no "bg ledger row missing"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
set -eu
lib="$(cd "$(dirname "$0")/../lib" && pwd)"
home_dir="$(mktemp -d)"
trap 'rm -rf "$home_dir"' EXIT
export HOME="$home_dir" OSRC_HOME="$home_dir/osrc" OSRC_HUB_FAST=1 OSRC_HUB_CHECK_PLANS=1
mkdir -p "$OSRC_HOME/hub"
. "$lib/hub-perf.sh"
printf '[]' > "$OSRC_HOME/hub/limits-cache.json"
_osrc_hub_limits() { printf '[{"id":"agy"}]'; }
_osrc_hub_limits_cached | jq -e '.[0].id == "agy"' >/dev/null
jq -e '.[0].id == "agy"' "$OSRC_HOME/hub/limits-cache.json" >/dev/null
screen="$(python3 -I "$lib/plan_probe.py" agy-parse < "$(dirname "$0")/fixtures/agy-usage-screen.txt")"
printf '[{"id":"agy","state":"unknown"}]' |
  jq --argjson p "$(jq -n --argjson a "$screen" '{agy:$a}')" --argjson now 1 --argjson lt 90 --argjson ct 50 -f "$lib/plan-overlay.jq" |
  jq -e '.[0] | .left == "91% left" and .state == "ok" and .windows.agy1week.left == 0' >/dev/null
echo 'RESULT: 2 passed, 0 failed'

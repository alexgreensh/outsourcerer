#!/usr/bin/env bash
set -eu
_T_DIR="$(cd "$(dirname "$0")" && pwd)"
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
cd "$lib"
python3 -IB - <<'UNIT'
import inspect, os, re, sys
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0, os.getcwd())
from hub_server import Hub

hub = Hub(os.environ["OSRC_HOME"], "", "hub.html", "test")
budget = inspect.signature(hub.run_export).parameters["timeout"].default
page = Path("hub.html").read_text()
assert int(re.search(r"'/api/refresh\?plans' \? (\d+)", page)[1]) > budget * 1000
hub.fresh_export = Mock()
hub.export_lock = Mock()
hub._export = Mock()
with patch("hub_server.time.monotonic", side_effect=[10, 14, 17, 19]):
    hub.run_export(timeout=20, force=True, check_plans=True)
hub.fresh_export.wait.assert_called_once_with(20)
hub.export_lock.acquire.assert_called_once_with(timeout=16)
hub._export.assert_called_once_with(13, True, True)
UNIT
# The page-side checks run here so CI covers them.
node --test "$_T_DIR/test_hub_plan_checks.js" >/dev/null
echo 'RESULT: 2 passed, 0 failed'

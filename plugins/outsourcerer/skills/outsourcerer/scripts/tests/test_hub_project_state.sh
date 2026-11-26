#!/usr/bin/env bash
# Unit checks for a stale export, a durable override and a manual refresh.
set -eu
_T_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/../lib"
python3 -IB - <<'PY'
import json, os, pathlib, sys, tempfile
sys.path.insert(0, os.getcwd())
from hub_server import Hub

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    engine = root / "engine"
    engine.write_text('#!/bin/sh\n[ "$OSRC_HUB_REFRESH" = 1 ] || exit 1\nprintf \'%s\\n\' \'{"projects":[{"id":"demo","status":"review"}]}\'\n')
    engine.chmod(0o700)
    def restart():
        hub = Hub(tmp, str(engine), "hub.html", "unit")
        assert hub.load_saved()
        hub.first_export.set()
        return hub
    def status(hub):
        return hub.projects_payload()[0]["projects"][0]["status"]
    hub = Hub(tmp, str(engine), "hub.html", "unit")
    fresh = hub.run_export(force=True)
    assert fresh["projects"][0]["status"] == "review"
    hub = restart()
    code, result = hub.write_status("demo", {"status": "shipped"})
    assert code == 200 and result["project"]["status"] == "shipped"
    assert json.loads((root / "hub/status/demo.json").read_text())["shippedBy"] == "user"
    assert status(hub) == status(restart()) == "shipped"
    assert hub.run_export(force=True)["projects"][0]["status"] == "shipped"
    hub = restart()
    assert hub.write_status("demo", {"status": "restore"})[0] == 200
    assert status(hub) == status(restart()) == "review"
    import signal
    status_file = root / "hub/status/demo.json"
    status_file.unlink()
    os.mkfifo(status_file)
    signal.alarm(5)
    assert hub.run_export(force=True)["projects"][0]["status"] == "review"
    signal.alarm(0)
print("hub project state: 3 passed, 0 failed")
PY
(
  source ./hub.sh
  unit=$(mktemp -d)
  trap 'rm -rf "$unit"' EXIT
  export OSRC_JOBS="$unit/jobs"
  mkdir -p "$OSRC_JOBS/lane"
  _reconcile_status() { echo running; }
  echo 0 > "$OSRC_JOBS/lane/exit"
  [ "$(_osrc_hub_job_state lane)" = "done?" ]   # exit 0 before reconcile saw the marker: unverified (F37)
  echo 1 > "$OSRC_JOBS/lane/exit"
  [ "$(_osrc_hub_job_state lane)" = failed ]
)
# The page-side checks run here so CI covers them.
node "$_T_DIR/hub_refresh_dom.js" >/dev/null
echo "hub project state and job liveness: 4 passed, 0 failed"

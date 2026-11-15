#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR%/}/p56-factory.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export HOME="$T/user" OSRC_HOME="$T/state" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME" "$OSRC_HOME" "$T/bin" "$T/repo"
git -C "$T/repo" init -q
printf 'fixture\n' > "$T/repo/a"
git -C "$T/repo" add a
git -C "$T/repo" commit -qm fixture
base="$(git -C "$T/repo" rev-parse HEAD)"
cat > "$T/bin/droid" <<'STUB'
#!/bin/sh
env > "$ENVDUMP"
echo 'OSRC::DONE fixture'
STUB
chmod +x "$T/bin/droid"
export PATH="$T/bin:$PATH" ENVDUMP="$T/envdump" OSRC_SOURCED=1
. "$D/outsourcerer.sh" >/dev/null 2>&1
export OSRC_SOURCED=0
mkdir -p "$OSRC_JOBS/envjob"
OSRC_JOB_TOKEN=env-test OSRC_SPEND_OK=1 _osrc_spend_marker_write "$OSRC_JOBS/envjob" droid run -m fixture-model
(
  cd "$T/repo" || exit 1
  export OSRC_JOB_TOKEN=env-test OSRC_WORKTREE=1 OSRC_WORKTREE_REQUIRED=1 OSRC_WORKTREE_BASE="$base"
  export OSRC_TASK_REF=fx/t1 OSRC_TASK_ATTEMPT=env-token OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1
  SCRIPT_PATH="$D/outsourcerer.sh"
  run_job envjob droid run --spend-ok -m fixture-model 'say hi'
) > "$T/log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] || [ ! -s "$ENVDUMP" ]; then cat "$T/log"; cat "$OSRC_JOBS/envjob/out.log" 2>/dev/null; echo 'FAIL: delegate did not run'; exit 1; fi
if grep -E '^OSRC_WORKTREE|^OSRC_TASK_(REF|ATTEMPT)=' "$ENVDUMP"; then echo 'FAIL: private job settings leaked'; exit 1; fi
if [ "$(jq -r '.worktree // ""' "$OSRC_JOBS/envjob/meta.json")" != "$T/repo/.outsourcerer/worktrees/envjob" ]; then echo 'FAIL: job worktree missing'; exit 1; fi
echo 'PASS: matching consent launches isolated delegate without worktree or task linkage variables'

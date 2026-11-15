#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/osrc-mc2.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" OSRC_HOME="$T/osrc" OSRC_JOBS="$T/osrc/jobs"
mkdir -p "$HOME/.claude/projects/p" "$OSRC_HOME/owners" "$OSRC_JOBS" "$T/bin"
. "$ROOT/lib/hub-names.sh"
mkdir -p "$T/repository" "$OSRC_HOME/owners/abcdefgh-1" "$OSRC_JOBS/one"
git -C "$T/repository" init -q
git -C "$T/repository" remote add origin https://github.com/example/demo.git
printf '{"cwd":"%s"}\n' "$T/repository" > "$OSRC_JOBS/one/meta.json"
touch "$OSRC_HOME/owners/abcdefgh-1/one"
[ "$(_osrc_hub_derived_name abcdefgh-1)" = 'example/demo (abcdefgh)' ]
mkdir -p "$OSRC_HOME/owners/12345678-2"
touch "$OSRC_HOME/owners/12345678-2/one"
[ "$(_osrc_hub_derived_name 12345678-2)" = 'example/demo (12345678)' ]
mkdir -p "$T/folder" "$OSRC_HOME/owners/folder-id" "$OSRC_JOBS/two"
printf '{"cwd":"%s"}\n' "$T/folder" > "$OSRC_JOBS/two/meta.json"
touch "$OSRC_HOME/owners/folder-id/two"
[ "$(_osrc_hub_derived_name folder-id)" = 'folder (folder-i)' ]
printf '%s\n' '{"type":"user","message":{"content":"Build the mission control dashboard"}}' > "$HOME/.claude/projects/p/prompt-id.jsonl"
[ "$(_osrc_hub_derived_name prompt-id)" = 'Build the mission control dashboard' ]
printf '%s\n' '{"type":"custom-title","customTitle":"A named session"}' >> "$HOME/.claude/projects/p/prompt-id.jsonl"
[ "$(_osrc_hub_derived_name prompt-id)" = 'A named session' ]
[ "$(_osrc_hub_derived_name missing-id)" = 'Session missing-' ]
_osrc_hub_daily_hint 2> "$T/first"
_osrc_hub_daily_hint 2> "$T/second"
[ "$(cat "$T/first")" = 'Mission Control: outsourcerer mc' ]
[ ! -s "$T/second" ]
mkdir -p "$OSRC_HOME/owners/old-session" "$OSRC_JOBS/old-job" "$OSRC_HOME/hub/decisions"
printf 'done\n' > "$OSRC_JOBS/old-job/status"
printf '{}\n' > "$OSRC_JOBS/old-job/meta.json"
touch "$OSRC_HOME/owners/old-session/old-job"
export OSRC_CATALOG_VALIDATE=0 OUTSOURCERER_DEPTH=0
out="$(bash "$ROOT/outsourcerer.sh" hub export 2>/dev/null)"
printf '%s' "$out" | jq -e '.projects[] | select(.id == "old-session") | .liveLanes == 0 and .status == "idle" and .staleHours == 24' >/dev/null
ln -s "$ROOT/outsourcerer.sh" "$T/osrc-link"
linked="$(bash "$T/osrc-link" hub export 2>/dev/null)"
printf '%s' "$linked" | jq -e '.projects[] | select(.id == "old-session") | .status == "idle"' >/dev/null
printf 'PASS: MC2 naming, hint, idle export and symlink loader\n' 

#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

s="$SRC"; set --; . "$s" >/dev/null 2>&1

line() { _heartbeat_line "$1"; }
past() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$2" +%Y-%m-%dT%H:%M:%SZ; }

# Idle fleet reads as quiet, not as a row of zeroes.
out="$(line '{"items":[]}')"
case "$out" in *"all quiet"*) ok "idle fleet reads as quiet prose" ;; *) bad "idle line not human: $out" ;; esac

# Read-only external observations are a compact count, never enumerated in the pulse.
out="$(line '{"items":[{"owner":"external","state":"unknown","session_id":"a"},{"owner":"external","state":"unknown","session_id":"b"}]}')"
case "$out" in *"2 other sessions seen"*) ok "external sessions summarized as a count" ;; *) bad "external count missing: $out" ;; esac
case "$out" in *"external session"*|*"session_id"*) bad "external sessions were enumerated in the pulse" ;; *) ok "external sessions are not enumerated" ;; esac

# Active work names who, on what, and for how long.
p="$(past 14M '14 minutes ago')"
snap="$(jq -cn --arg p "$p" '{items:[{owner:"managed",state:"working",observed_model:"sol",task_summary:"refactor auth",started_at:$p}]}')"
out="$(line "$snap")"
case "$out" in *"sol on 'refactor auth'"*) ok "active work names agent and task" ;; *) bad "active work detail missing: $out" ;; esac
case "$out" in *"(14m)"*) ok "elapsed time renders from started_at" ;; *) bad "elapsed missing: $out" ;; esac
case "$out" in *"nothing needs you"*) ok "quiet-but-working states nothing needs the user" ;; *) bad "reassurance missing: $out" ;; esac

# A blocked job is surfaced as needing the user.
snap='{"items":[{"owner":"managed","state":"blocked","observed_model":"glm","task_summary":"migrate db"}]}'
out="$(line "$snap")"
case "$out" in *"⚠ needs you"*"glm 'migrate db' blocked"*) ok "blocked work is flagged as needing you" ;; *) bad "blocked not surfaced: $out" ;; esac

# A missing started_at degrades to no elapsed, never to a crash or a bogus duration.
snap='{"items":[{"owner":"managed","state":"working","observed_model":"sol","task_summary":"x"}]}'
out="$(line "$snap")"
case "$out" in *"sol on 'x'"*) ok "missing start time degrades cleanly" ;; *) bad "missing start time broke the line: $out" ;; esac

# A hostile job label (newline, escape sequence, overlong) cannot split the pulse, corrupt the
# terminal, or blow out the line. Control characters are stripped and the field is capped.
esc="$(printf '\033')"
hostile="line1${esc}[31mRED
line2 $(printf 'A%.0s' $(seq 1 200))"
snap="$(jq -cn --arg t "$hostile" '{items:[{owner:"managed",state:"working",observed_model:"sol",task_summary:$t}]}')"
out="$(line "$snap")"
nlines="$(printf '%s' "$out" | wc -l | tr -d ' ')"
[ "$nlines" -le 1 ] && ok "hostile label cannot split the one-line pulse" || bad "hostile label split the pulse ($nlines lines)"
if printf '%s' "$out" | LC_ALL=C grep -q '[[:cntrl:]]'; then bad "control characters survived into the pulse"; else ok "control characters are stripped"; fi
nchars="$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')"
[ "$nchars" -le 200 ] && ok "pulse length stays bounded under an overlong label" || bad "overlong label blew out the line ($nchars bytes)"

# Elapsed must render from EPOCH seconds (the job-lifecycle shape), not only ISO strings.
epoch14="$(( $(date -u +%s) - 840 ))"
snap="$(jq -cn --argjson e "$epoch14" '{items:[{owner:"managed",state:"working",observed_model:"sol",task_summary:"x",started_at:$e}]}')"
out="$(line "$snap")"
case "$out" in *"(14m)"*) ok "elapsed renders from epoch seconds" ;; *) bad "epoch elapsed missing: $out" ;; esac

# A large fleet is capped, not enumerated in full — the pulse stays one bounded line.
snap="$(jq -cn '{items:[range(12)|{owner:"managed",state:"working",observed_model:"glm",task_summary:"job\(.)"}]}')"
out="$(line "$snap")"
case "$out" in *"more"*) ok "large fleet is capped with a +N more summary" ;; *) bad "large fleet not capped: $out" ;; esac
[ "$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')" -le 220 ] && ok "capped pulse stays bounded for a big fleet" || bad "big fleet blew out the line"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]

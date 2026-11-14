#!/usr/bin/env bash
# Release racers only after every child has reached the starting line.
osrc_race_ready() {
  local dir="$1" id="$2" deadline=$((SECONDS + 30))
  : > "$dir/ready.$id" || return 1
  while [ ! -f "$dir/go" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.01
  done
  [ ! -f "$dir/cancel" ]
}

osrc_race_release() {
  local dir="$1" count="$2" deadline=$((SECONDS + 20)) i ready
  while :; do
    ready=1
    for ((i=1; i<=count; i++)); do [ -f "$dir/ready.$i" ] || ready=0; done
    [ "$ready" = 1 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      : > "$dir/cancel"; : > "$dir/go"; return 1
    fi
    sleep 0.01
  done
  : > "$dir/go"
}

osrc_race_report() {
  local dir="$1" count="$2" i
  for ((i=1; i<=count; i++)); do
    printf '  racer %s: status=%s\n' "$i" "$(cat "$dir/status.$i" 2>/dev/null || echo missing)"
    [ ! -s "$dir/out.$i" ] || sed 's/^/    stdout: /' "$dir/out.$i"
    [ ! -s "$dir/err.$i" ] || sed 's/^/    stderr: /' "$dir/err.$i"
  done
}

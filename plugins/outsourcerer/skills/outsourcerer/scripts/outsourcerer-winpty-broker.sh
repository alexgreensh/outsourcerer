#!/usr/bin/env bash
# outsourcerer-winpty-broker.sh — keeps a single live interactive session on Git Bash/MSYS
# without tmux. winpty gives the child a Windows console; this broker keeps winpty's stdin
# open, writes output to a log, and polls a file-mailbox so separate outsourcerer.sh
# invocations can send/read/clear/stop the same child.
#
# Expects: $1 = session state directory containing launch.bash (declare -p LAUNCH).
#
# NOTE: this path is only executed on OSRC_PLATFORM=windows. It must be verified on a
# real Windows Git Bash machine; winpty builds and MSYS FIFO semantics vary.
set -uo pipefail

SESS_DIR="${1:-}"
[ -d "$SESS_DIR" ] || { echo "broker: session dir missing: $SESS_DIR" >&2; exit 1; }
source "$SESS_DIR/launch.bash" 2>/dev/null || { echo "broker: launch.bash missing" >&2; exit 1; }

STDIN_FIFO="$SESS_DIR/stdin"
OUT_LOG="$SESS_DIR/out.log"
CMD_DIR="$SESS_DIR/cmd"
PID_FILE="$SESS_DIR/broker.pid"
WINPTY_PID_FILE="$SESS_DIR/winpty.pid"

mkdir -p "$CMD_DIR" || { echo "broker: cannot create $CMD_DIR" >&2; exit 1; }
: > "$OUT_LOG"

# Keep a write FD open on the stdin FIFO so winpty never sees EOF.
rm -f "$STDIN_FIFO"
mkfifo "$STDIN_FIFO" 2>/dev/null || { echo "broker: mkfifo failed" >&2; exit 1; }
exec 3>"$STDIN_FIFO"

# Probe whether this winpty supports the undocumented flags that allow redirection
# to a file/pipe. Git for Windows winpty usually does; if not, fall back to none.
WP_ARGS=()
if winpty -Xallow-non-tty -Xplain /bin/sh -c 'exit 0' >/dev/null 2>&1; then
  WP_ARGS=(-Xallow-non-tty -Xplain)
fi

winpty "${WP_ARGS[@]}" "${LAUNCH[@]}" < "$STDIN_FIFO" > "$OUT_LOG" 2>&1 &
WPID=$!
echo "$WPID" > "$WINPTY_PID_FILE"
[ -n "$$" ] && echo "$$" > "$PID_FILE"

# Ignore SIGPIPE so a dead winpty does not kill the broker mid-cleanup.
trap '' PIPE

# Polled file-mailbox loop. Command files are processed in mtime order and removed.
while kill -0 "$WPID" 2>/dev/null; do
  files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("${line#* }")
  done < <(
    { find "$CMD_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2- ; } \
    || ls -1tr "$CMD_DIR" 2>/dev/null
  )

  if [ "${#files[@]}" -eq 0 ]; then
    sleep 0.15
    continue
  fi

  for f in "${files[@]}"; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      stop|stop-*)
        break 2
        ;;
      send-*)
        [ -s "$f" ] && cat "$f" >&3
        printf '\r\n' >&3        # primary Enter
        sleep 0.3
        printf '\r\n' >&3        # second Enter some TUIs need
        ;;
      clear-*)
        printf '\x1b\x15' >&3   # Escape then Ctrl-U
        ;;
      model-*)
        filter=""
        [ -s "$f" ] && filter=$(cat "$f")
        printf '\x1b\x1bm' >&3   # Escape then Alt-m (Devin model picker)
        sleep 0.5
        [ -n "$filter" ] && { printf '%s' "$filter" >&3; sleep 0.5; }
        printf '\r' >&3
        ;;
    esac
    rm -f "$f"
  done
done

# Cleanup
kill "$WPID" 2>/dev/null
sleep 0.2
kill -9 "$WPID" 2>/dev/null || true
rm -f "$STDIN_FIFO" "$PID_FILE" "$WINPTY_PID_FILE"

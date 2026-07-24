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
umask 077

have() { command -v "$1" >/dev/null 2>&1; }
have winpty || { echo "broker: winpty missing" >&2; exit 1; }

SESS_DIR="${1:-}"
[ -d "$SESS_DIR" ] || { echo "broker: session dir missing: $SESS_DIR" >&2; exit 1; }
chmod 600 "$SESS_DIR/launch.bash" 2>/dev/null || true
source "$SESS_DIR/launch.bash" 2>/dev/null || { echo "broker: launch.bash missing" >&2; exit 1; }
[ -n "${LAUNCH+x}" ] && [ "${#LAUNCH[@]}" -gt 0 ] || { echo "broker: launch.bash has no LAUNCH array" >&2; exit 1; }

STDIN_FIFO="$SESS_DIR/stdin"
OUT_LOG="$SESS_DIR/out.log"
CMD_DIR="$SESS_DIR/cmd"
PID_FILE="$SESS_DIR/broker.pid"
WINPTY_PID_FILE="$SESS_DIR/winpty.pid"

mkdir -p "$CMD_DIR" || { echo "broker: cannot create $CMD_DIR" >&2; exit 1; }
: > "$OUT_LOG"
chmod 600 "$OUT_LOG" 2>/dev/null || true

# Keep a write FD open on the stdin FIFO so winpty never sees EOF.
rm -f "$STDIN_FIFO"
mkfifo "$STDIN_FIFO" 2>/dev/null || { echo "broker: mkfifo failed" >&2; exit 1; }
exec 3<>"$STDIN_FIFO"

# Probe whether this winpty supports the undocumented flags that allow redirection
# to a file/pipe. Git for Windows winpty usually does; if not, fall back to none.
WP_ARGS=()
if winpty -Xallow-non-tty -Xplain /bin/sh -c 'exit 0' >/dev/null 2>&1; then
  WP_ARGS=(-Xallow-non-tty -Xplain)
fi

winpty ${WP_ARGS[@]+"${WP_ARGS[@]}"} "${LAUNCH[@]}" < "$STDIN_FIFO" > "$OUT_LOG" 2>&1 &
WPID=$!
echo "$WPID" > "$WINPTY_PID_FILE"
[ -n "$$" ] && echo "$$" > "$PID_FILE"

# Polled file-mailbox loop. Command files are processed in mtime order and removed.
while kill -0 "$WPID" 2>/dev/null; do
  # A long-lived interactive session must not turn its transcript into an
  # unbounded disk consumer.  Rotation is deliberately simple and portable.
  if [ "$(wc -c < "$OUT_LOG" 2>/dev/null || echo 0)" -gt 10485760 ] 2>/dev/null; then
    : > "$OUT_LOG"
  fi
  files=()
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(
    if find "$CMD_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' >/dev/null 2>&1; then
      find "$CMD_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-
    else
      find "$CMD_DIR" -maxdepth 1 -type f -print 2>/dev/null | sort
    fi
  )

  if [ "${#files[@]}" -eq 0 ]; then
    sleep 0.15
    continue
  fi

  # Stop is a control command, not ordinary input: honour it before any send
  # even when the filesystem gives both files the same timestamp.
  for f in "${files[@]}"; do
    case "$(basename "$f")" in stop|stop-*) break 2 ;; esac
  done

  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      stop|stop-*)
        break 2
        ;;
      send-[0-9]*.txt)
        [ ! -s "$f" ] || cat "$f" >&3 || continue
        printf '\r\n' >&3        # primary Enter
        sleep 0.3
        printf '\r\n' >&3        # second Enter some TUIs need
        ;;
      clear-[0-9]*)
        printf '\x1b\x15' >&3   # Escape then Ctrl-U
        ;;
      model-[0-9]*.txt)
        filter=""
        [ ! -s "$f" ] || filter=$(cat "$f") || continue
        filter=$(printf '%s' "$filter" | tr -cd '[:alnum:][:space:]._:/-')
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

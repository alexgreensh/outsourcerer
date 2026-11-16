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

# winpty starts a Windows executable via CreateProcess, so it cannot run the extensionless sh
# shim npm installs next to `codex.cmd` (or any other npm-installed CLI): it fails with
# "cannot start 'codex': Not found in PATH". Resolve LAUNCH[0] to its .exe/.cmd/.bat sibling.
_wp_bin="$(command -v -- "${LAUNCH[0]}" 2>/dev/null || true)"
case "$_wp_bin" in
  ''|*.exe|*.EXE|*.cmd|*.CMD|*.bat|*.BAT|*.com|*.COM) ;;
  *) for _wp_ext in .exe .cmd .bat; do
       [ -f "$_wp_bin$_wp_ext" ] && { LAUNCH[0]="$_wp_bin$_wp_ext"; break; }
     done ;;
esac

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

# stdin is a FIFO and stdout a file, so winpty needs its (undocumented) non-tty flags: without them it
# exits with "stdin is not a tty". There used to be a `winpty -X... /bin/sh -c 'exit 0'` probe here;
# it is gone because it proves nothing either way: on Git for Windows winpty 0.4.3 a short-lived probe
# child hits `ASSERT_CONDITION("wp != nullptr && cols > 0 && rows > 0")` and STILL exits 0, while a
# real TUI under the same flags runs fine (verified 2026-11-16). `session start` now checks that the
# engine is actually alive after boot and fails loudly with its output when it is not.
WP_ARGS=(-Xallow-non-tty -Xplain)

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
        # ONE Enter. A blind second Enter lands on whatever the first one opened: verified live, it
        # picked "1. Update now" on Codex's update screen and ran `npm install -g @openai/codex`.
        # `session send` re-checks the log and asks for another Enter (enter-*) only when the text
        # is still sitting unsent in the composer.
        [ ! -s "$f" ] || cat "$f" >&3 || continue
        sleep 0.3
        printf '\r' >&3
        ;;
      enter-[0-9]*)
        printf '\r' >&3
        ;;
      answer-[0-9]*.txt)
        # A menu answer: a signed cursor move (+2 = Down twice, -1 = Up once, 0 = stay), then Enter.
        # Arrows, not digit hotkeys: every cursor menu honours them, and a digit alone was seen NOT to
        # confirm a Codex menu (Enter does). `session answer` computes the move from the cursor row.
        mv=""
        [ ! -s "$f" ] || mv=$(tr -cd '0-9+-' < "$f") || continue
        case "$mv" in
          +[0-9]*|[0-9]*) k=$'\e[B'; n=${mv#+} ;;
          -[0-9]*) k=$'\e[A'; n=${mv#-} ;;
          *) n="" ;;
        esac
        if [ -n "$n" ]; then
          while [ "$n" -gt 0 ]; do printf '%s' "$k" >&3; sleep 0.15; n=$((n - 1)); done
          sleep 0.3
          printf '\r' >&3
        fi
        ;;
      clear-[0-9]*)
        # Escape, a pause, then Ctrl-U. Sent close together, ESC+^U is read as ONE Alt-Ctrl-U key and
        # the Escape never happens (verified with Codex: a 0.3s gap did not close its menu; 1.2s did).
        printf '\x1b' >&3
        sleep 1
        printf '\x15' >&3
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

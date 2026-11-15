# shellcheck shell=bash
# lib/lane_life.sh: when is a lane really finished, who ended it, and is a waiter really a waiter.
# Sourced by outsourcerer.sh (lib loader). Function definitions only: nothing runs at source time.
# Three failures seen on 2026-11-15 (briefs/SUP.md), one helper group each:
#
# 1. Idle-but-waiting. A Claude Code lane that ended its turn while its own background shell runs
#    (`✻ Crunched for 44s · done 11:45 PM · 1 shell still running`, footer `⏵⏵ auto mode on · 1 shell`)
#    is not idle: Claude Code wakes it when the shell exits. And an idle lane whose done contract does
#    not hold is still owed a waiter. `supervise` used to call both "settled" (EVENT done all).
# 2. Owner-stopped lane read as a crash. `session stop` killed tmux BEFORE writing the registry `end`,
#    and any `end` (even the beacon's `crash-reap`) counted as a deliberate stop. Now: a recorded
#    stop is `stopped` (no wake), a lane that handed in and then vanished is `done`, the rest `failed`.
# 3. Waiter look-alikes. The stop guard matched `outsourcerer... wait <id>` anywhere in any `ps`
#    line, so `bash -c 'echo outsourcerer.sh wait j1; sleep 600'` (or a `# comment`) passed for a
#    waiter. Only a process that IS an outsourcerer run counts (env prefixes, `cd x &&`, full paths
#    and `| tail -N` never show in that process's own argv, so every real shape still matches).

# ---- 1. background shells ---------------------------------------------------------------------------
# Run right after _osrc_screen_analyze_text (needs its _SCR_L/_SCR_N arrays and OSRC_SCR_HIST_END).
# The turn-summary line (last non-blank history lines) and the status footer under the composer are
# both CLI chrome: the composer box sits between them and the lane's prose, so typed or printed text
# cannot reach either position. The summary drops `· N shell still running` the moment the shell
# ends (verified live, fixtures/supervise/cc-bg-shell-finished-working.txt).
_SV_BG_SUMMARY_RE='^[[:space:]]*[^[:alnum:][:space:]]{1,3}[[:space:]]+[A-Z][a-z]+ for [0-9].*[[:space:]][0-9]+ (background )?shells? still running[[:space:]]*$'
_SV_BG_FOOTER_RE='[[:space:]][0-9]+ (background )?shells?[[:space:]]*$'

_sv_bg_shell() { # -> 0 + evidence line when the analysed Claude Code frame shows a running background shell
  local end i n=0 l re
  end="${OSRC_SCR_HIST_END:--1}"
  case "$end" in ''|-*|*[!0-9]*) return 1 ;; esac
  re="$_SV_BG_SUMMARY_RE"; i="$end"
  while [ "$i" -ge 0 ] && [ "$n" -lt 3 ]; do
    l="${_SCR_L[$i]}"
    case "$l" in *[![:space:]]*) n=$((n + 1)); if [[ $l =~ $re ]]; then printf '%s' "$(_osrc_scr_trim "$l")"; return 0; fi ;; esac
    i=$((i - 1))
  done
  # Footer: the rows below the composer's closing rule.
  i=$((end + 2))
  while [ "$i" -lt "${_SCR_N:-0}" ] && ! _osrc_scr_is_rule "${_SCR_L[$i]}"; do i=$((i + 1)); done
  re="$_SV_BG_FOOTER_RE"; i=$((i + 1))
  while [ "$i" -lt "${_SCR_N:-0}" ]; do
    l="${_SCR_L[$i]}"
    if [[ $l =~ $re ]]; then printf 'status bar: %s' "$(_osrc_scr_trim "$l")"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# Is an idle lane owed a waiter? Not when its done contract holds or it is a fresh session nobody has
# prompted yet (that one is not live work). Every other idle lane is: it stopped short of done.
_sv_idle_owed() { # <session-id> -> 0 owed, 1 settled
  local out st
  type osrc_done_state >/dev/null 2>&1 && [ "$(osrc_done_state "$1" 2>/dev/null)" = done ] && return 1
  out="$(_sv_target_screen "$1" 2>/dev/null)"; st="${out%%$'\n'*}"
  case "$st" in done) return 1 ;; esac
  case "$st:$out" in composer:*"no turn yet"*) return 1 ;; esac
  return 0
}

# ---- 2. a lane whose pane is gone ------------------------------------------------------------------
# Sets SV_K/SV_D/SV_H/SV_DROP/SV_STOPPED like _sv_observe (whose SVS_* state it reads).
_sv_observe_gone() { # <id>
  local id="$1" last ev rc why
  SV_DROP=1
  last="$(_session_registry_last_event "$id" 2>/dev/null)"
  ev="$(printf '%s' "$last" | jq -r '.event // empty' 2>/dev/null)"
  rc="$(printf '%s' "$last" | jq -r '.receipt // empty' 2>/dev/null)"
  # Ended on purpose (session stop, control exit, a failed launch the start command already reported).
  # `crash-reap` is the beacon finding a dead engine: that is not anybody's decision.
  if [ "$ev" = end ] && [ "$rc" != crash-reap ]; then SV_STOPPED=1; return 0; fi
  [ "$SVS_HASH" = - ] && [ -z "$last" ] && return 0                 # never a session we saw
  case "$SVS_LK" in done:*) SV_STOPPED=1; return 0 ;; esac          # its finish was already reported
  why="$(_sv_gone_handin "$id" "$last")"
  if [ -n "$why" ]; then SV_K=done; SV_D="finished ($why), then its session closed"; SV_H=gone-done; return 0; fi
  SV_K=failed; SV_H=gone
  SV_D="session is gone (pane dead, no stop recorded${rc:+, registry says $rc}; end lanes with session stop so it reads as stopped)"
}

# Proof that a vanished lane had handed in: its done contract holds, or a watched hand-in file named
# for it (<lane>.DONE / <lane>-DONE, where the session id is <lane> or ends in -<lane>) was written
# after the session started. A DONE file left over from an earlier round never counts.
_sv_gone_handin() { # <id> <last-registry-record> -> reason on stdout
  local id="$1" start w p f b stem m
  if type osrc_done_state >/dev/null 2>&1 && [ "$(osrc_done_state "$id" 2>/dev/null)" = done ]; then
    printf 'done contract holds'; return 0
  fi
  start="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -rs --arg id "$id" \
    '[.[] | select(.session_id == $id and .event == "start") | (.ts // "" | fromdateiso8601? // empty)] | max // empty' 2>/dev/null)"
  case "$start" in ''|*[!0-9]*) return 0 ;; esac
  for w in "$OSRC_HOME"/watch/*.path; do
    [ -f "$w" ] || continue
    p="$(cat "$w" 2>/dev/null)"; [ -n "$p" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b="$(basename "$f")"; [ "$(_sv_handin_kind "$b")" = done ] || continue
      stem="$(printf '%s' "$b" | sed -E 's/[.-]?DONE$//')"; [ -n "$stem" ] || continue
      case "$id" in "$stem"|*-"$stem") ;; *) continue ;; esac
      m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
      [ "${m:-0}" -ge "$start" ] 2>/dev/null && { printf 'hand-in %s' "$b"; return 0; }
    done < <(_sv_watch_files "$p")
  done
  return 0
}

# ---- 3. who is a waiter ----------------------------------------------------------------------------
# A `ps -o command=` line -> the arguments after the outsourcerer script, when that process IS an
# outsourcerer run: `[/path/]bash [opts] [path/]outsourcerer[.sh] ARGS` or `[path/]outsourcerer[.sh] ARGS`.
# A `-c` shell (whose argv is a whole command string: echo, comments, `cd x && ...`) never matches;
# its child process, the real run, does. Paths may hold spaces (~/Library/Mobile Documents/...), but a
# word after a space never starts with - / ~ . or shell punctuation: that is a new argument, so
# `/bin/zsh -c -l ... /p/outsourcerer.sh wait j1` and `vim /p/outsourcerer.sh wait` are not one path.
_SG_SH_RE='^([^ ]*/)?(bash|sh|zsh|dash|ksh)(\.exe)?( -[abd-zA-Z-]+)* ([/.~][^ &|;#$=`'"'"'"]*( [^-/~. &|;#$=`'"'"'"][^ &|;#$=`'"'"'"]*)*/)?outsourcerer(\.sh)? (.*)$'
_SG_DIRECT_RE='^([/.~][^ &|;#$=`'"'"'"]*( [^-/~. &|;#$=`'"'"'"][^ &|;#$=`'"'"'"]*)*/)?outsourcerer(\.sh)? (.*)$'
_sg_osrc_args() { # <ps command line>
  local line="$1" re
  re="$_SG_SH_RE"; if [[ $line =~ $re ]]; then printf '%s' "${BASH_REMATCH[8]}"; return 0; fi
  re="$_SG_DIRECT_RE"; if [[ $line =~ $re ]]; then printf '%s' "${BASH_REMATCH[4]}"; return 0; fi
  return 1
}

# The ids running `wait <id>` / `fanout wait <gid>` processes cover, one per line.
_sg_ps_waits() {
  local line args v a b
  ps -axo command= 2>/dev/null | grep -F outsourcerer | while IFS= read -r line; do
    args="$(_sg_osrc_args "$line")" || continue
    read -r v a b _ <<< "$args"
    case "$v:$a" in
      fanout:wait) [ -n "$b" ] && [ -f "$(_fanout_dir "$b" 2>/dev/null)/members.tsv" ] && cut -f1 "$(_fanout_dir "$b")/members.tsv" 2>/dev/null ;;
      wait:?*) printf '%s\n' "$a" ;;
    esac
  done
}

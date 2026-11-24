# shellcheck shell=bash
# lib/send.sh: `session send` that provably lands (L3, 2026-11-13). Moved out of outsourcerer.sh.
#
# FINDINGS class 7 + Fable E6/E7:
# - E7: the old proof compared the bottom non-empty line of the pane. In Claude Code that line is the
#   status bar, so any redraw passed as "submitted" while the text sat unsent. The proof now reads the
#   engine's COMPOSER (lib/screen.sh): submitted means the composer no longer holds the text AND the
#   engine shows work, a prompt, or the text in history. Still in the composer -> one more Enter ->
#   still there -> fail loudly (`EVENT failed`). Unknown layouts fall back to the legacy check.
# - E6: obligation ids were send.<session>.<cksum(message)>, so a second identical "continue" or "y"
#   was refused forever. Each send is now its own obligation (nonce in the id); concurrent sends are
#   still serialised by the endpoint mutation lock.
# - Long messages (> OSRC_SEND_MAX_CHARS, default 1500) are written to <delegate cwd>/.osrc-msgs/ and
#   the delegate is sent a one-line "read <file>" instead, so nothing lands as an unsubmitted paste.

# ---- the obligation ledger -----------------------------------------------------------------------
# Every send writes the ledger under its state lock. Two sends to different lanes at nearly the same
# time queue on that lock; one acquire attempt gives up after ~5 s, and the second send used to be
# refused there. A writer now WAITS for the lock up to OSRC_SEND_LOCK_WAIT_SECS (default 30) and only
# then fails, with a message that names the cause. Records are whole lines appended under the lock,
# so concurrent writers never interleave.
_obligation_lock() {
  local bound="${OSRC_SEND_LOCK_WAIT_SECS:-30}" deadline
  case "$bound" in ''|*[!0-9]*) bound=30 ;; esac
  deadline=$(( $(date +%s) + bound ))
  until _state_lock_acquire "$OSRC_OBLIGATIONS"; do
    [ "$(date +%s)" -lt "$deadline" ] && continue
    printf 'outsourcerer: the obligation ledger %s stayed locked for over %ss, so nothing was sent. Another outsourcerer process is holding it; retry, or raise OSRC_SEND_LOCK_WAIT_SECS.\n' "$OSRC_OBLIGATIONS" "$bound" >&2
    return 1
  done
}

# Last state of one obligation. The grep keeps the read cheap on a long ledger (the old reader forked
# one jq per line while holding the lock, which is what kept the lock busy); ids are [A-Za-z0-9._-],
# so the literal key match is exact, and jq re-checks it.
_obligation_latest_state() { # <id>
  [ -f "$OSRC_OBLIGATIONS" ] && [ ! -L "$OSRC_OBLIGATIONS" ] || return 0
  grep -F "\"obligation_id\":\"$1\"" "$OSRC_OBLIGATIONS" 2>/dev/null \
    | jq -Rr --arg id "$1" 'fromjson? | select(.obligation_id==$id) | .state' 2>/dev/null | tail -1
}

_obligation_append() { # <id> <session-id> <state> <receipt>
  local id="$1" session_id="$2" state="$3" receipt="$4" now record rc=0
  _external_session_id_valid "$session_id" || return 1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg id "$id" --arg session "$session_id" --arg state "$state" --arg receipt "$receipt" --arg ts "$now" \
    '{schema_version:"1",obligation_id:$id,session_id:$session,state:$state,receipt:(if $receipt=="" then null else $receipt end),ts:$ts}')" || return 1
  _mkdir_private "$OSRC_HOME" || return 1
  ( umask 077; : >> "$OSRC_OBLIGATIONS" ) 2>/dev/null || return 1
  _obligation_lock || return 1
  _state_append_locked "$OSRC_OBLIGATIONS" "$record" || rc=1
  _state_lock_release "$OSRC_OBLIGATIONS"
  return "$rc"
}

# Creating an obligation is a mutation authority boundary: hold the lock through the read and the
# pending record, or two reply processes race. rc 2 = this id already has a live or settled state.
_obligation_admit() { # <id> <session-id>
  local id="$1" session_id="$2" latest now record rc=0
  _mkdir_private "$OSRC_HOME" || return 1
  ( umask 077; : >> "$OSRC_OBLIGATIONS" ) 2>/dev/null || return 1
  _obligation_lock || return 1
  latest="$(_obligation_latest_state "$id")"
  case "$latest" in submitted|delivery_unknown|pending|typing_started) _state_lock_release "$OSRC_OBLIGATIONS"; return 2 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg id "$id" --arg session "$session_id" --arg ts "$now" '{schema_version:"1",obligation_id:$id,session_id:$session,state:"pending",receipt:null,ts:$ts}')" || rc=1
  [ "$rc" -ne 0 ] || printf '%s\n' "$record" >> "$OSRC_OBLIGATIONS" 2>/dev/null || rc=1
  [ "$rc" -ne 0 ] || _state_sync "$OSRC_OBLIGATIONS" || rc=1
  _state_lock_release "$OSRC_OBLIGATIONS"
  return "$rc"
}

_managed_composer_state() { # <session-id> <pane> -> empty|unknown|unreadable (a prompt is open)
  local session_id="$1" pane="$2" prov
  case "$(_external_probe_configured "${OSRC_EXTERNAL_COMPOSER_PROBE:-}"; echo $?)" in
    0) _external_composer_state "$pane"; return ;;
    2) printf 'unknown\n'; return ;;   # broken adapter -> fail closed, never fall through to built-in
  esac
  [ "${OSRC_MANAGED_SEND_BUILTIN:-1}" = "1" ] || { printf 'unknown\n'; return; }
  prov="$(_managed_provider "$session_id")"
  # L3 / E7: read the composer for every engine whose layout lib/screen.sh knows, instead of assuming
  # a non-Claude composer is empty. Unknown layouts keep the old assumption (the pane was just
  # _tmux_reset_input'd, and C-u clears the line).
  local cap
  if cap="$(_osrc_screen_capture "$pane")"; then
    _osrc_screen_analyze_text "$prov" <<<"$cap"
    if [ "$OSRC_SCR_COMPOSER_FOUND" = 1 ]; then
      [ -z "$OSRC_SCR_COMPOSER" ] && printf 'empty\n' || printf 'unknown\n'
      return
    fi
    # No composer and a prompt on screen: the keys would go into the prompt (review round 3, #2).
    case "$OSRC_SCR_STATE" in approval|question) printf 'unreadable\n'; return ;; esac
  fi
  case "$prov" in
    cc|claude) _cc_composer_empty "$pane" && printf 'empty\n' || printf 'unknown\n' ;;
    *)         printf 'empty\n' ;;
  esac
}

# ---- submission verification for MANAGED session send (Bug A) -----------------------------------
# `session send` used to type a prompt into the composer and report "sent" without ever proving the
# text left the input line. An Enter eaten by a dialog, a composer that wasn't ready, or a multi-line
# input left the typed text sitting unsubmitted while the receipt said "sent", so a delegation could
# sit unsent indefinitely while looking dispatched. The fix is a direct, immediate observation of the
# composer at the mutation endpoint: snapshot the pane tail WITH the typed text resting in the composer
# (captured between the text send and the Enter), then poll until the pane changes away from that
# snapshot. A successful submit always changes the pane (the text moves into the transcript, or the
# composer clears, or a spinner appears); an Enter that was eaten leaves the pane byte-identical to
# the text-in-composer snapshot, so the check fails closed. This is NOT the old pane-scraping receipt
# (which matched a transcript occurrence and was forgeable): it observes the composer state in the
# bounded window right after the send. Verified against real tmux 3.6a: a typed-but-unsubmitted line
# sits on the bottom input line of `capture-pane -p`; after Enter it moves into history and the bottom
# line clears.
_managed_pane_tail() { # <pane> -> last N non-empty lines; rc 0 ok, 2 capture failed
  # Capture into a variable FIRST so the capture exit status is preserved. A pipeline
  # (capture-pane | grep | tail) loses the capture status behind tail's, so a capture
  # failure looked identical to a blank pane and forged submission success (infra F3 /
  # static F2). A genuinely blank pane is rc 0 with empty output; a capture failure is
  # rc 2 with empty output — the caller fails closed on 2.
  local pane="$1" cap
  cap="$(tmux capture-pane -t "$pane" -p 2>/dev/null)" || return 2
  [ -n "$cap" ] || return 0
  printf '%s\n' "$cap" | grep -v '^[[:space:]]*$' | tail -n "${OSRC_SEND_VERIFY_TAIL:-12}"
}

# 0 = submitted (positive evidence the typed text left the composer); 1 = not submitted (the
# composer line is still byte-identical to the moment the text sat typed — Enter was eaten);
# 2 = the pane could not be read. Bounded poll (condition-based, not one fixed sleep): a real submit
# clears the composer in well under a second; a stuck composer never changes, so the loop exits on the
# real state change.
#
# The proof is the COMPOSER LINE (the bottom non-empty line), not the whole tail. An unrelated
# redraw/scroll higher in the pane changes the tail without the message being sent; comparing only
# the composer line means that redraw cannot forge submission while the typed text still sits unsent
# in the composer (static F3). A capture failure (rc 2 from _managed_pane_tail) is never submission:
# it fails closed so a dead/unreadable pane is never reported as "sent" (infra F3 / static F2).
_managed_send_submitted() { # <pane> <typed-tail-snapshot>
  local pane="$1" typed="$2" polls="${OSRC_SEND_VERIFY_POLLS:-15}" i cur tail_rc typed_composer cur_composer
  # The composer line is the last non-empty line of the text-in-composer snapshot — the typed
  # message resting on the bottom input line at the moment Enter was pressed.
  typed_composer="$(printf '%s\n' "$typed" | grep -v '^[[:space:]]*$' | tail -1)"
  i=0
  while [ "$i" -lt "$polls" ]; do
    cur="$(_managed_pane_tail "$pane")"; tail_rc=$?
    # Capture failure is NOT submission: fail closed with a distinct code so the caller can
    # report the pane was unreadable rather than forging a success.
    [ "$tail_rc" -ne 2 ] || return 2
    # A blanked pane (empty capture, rc 0) means the composer cleared -> submitted.
    [ -n "$cur" ] || return 0
    # Positive evidence: the composer (bottom) line changed away from the typed message. An
    # unrelated redraw higher in the tail does not count — the typed text must have left the
    # composer line itself.
    cur_composer="$(printf '%s\n' "$cur" | grep -v '^[[:space:]]*$' | tail -1)"
    [ "$cur_composer" != "$typed_composer" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# ---- long messages -------------------------------------------------------------------------------
# Writes <message> to <delegate cwd>/.osrc-msgs/msg-<ts>-<n>.md (git-excluded when the cwd is a repo)
# and prints the one-line instruction to send instead. rc 1 = could not spill (caller sends inline).
_osrc_send_spill() { # <pane> <message>
  local pane="$1" msg="$2" cwd dir f common
  cwd="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)" || return 1
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 1
  dir="$cwd/.osrc-msgs"
  mkdir -p "$dir" 2>/dev/null || return 1
  find "$dir" -name 'msg-*.md' -mtime +7 -exec rm -f {} + 2>/dev/null   # read long ago; keep the dir small
  f="$dir/msg-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM.md"
  printf '%s\n' "$msg" > "$f" 2>/dev/null || return 1
  common="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || common=""
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$cwd/$common" ;; esac
    mkdir -p "$common/info" 2>/dev/null
    grep -qx '.osrc-msgs/' "$common/info/exclude" 2>/dev/null || printf '.osrc-msgs/\n' >> "$common/info/exclude" 2>/dev/null
  fi
  printf 'Read the file %s and follow the instructions in it (the orchestrator message, %s chars, sent as a file so it cannot land as an unsubmitted paste).' "$f" "${#msg}"
}

# ---- screen-verified submission ------------------------------------------------------------------
# After Enter: 0 = submitted, with proof about THIS send in OSRC_SEND_EVIDENCE; 2 = no proof either
# way (the composer is empty but nothing tied to this send was seen); 1 = the text is still in the
# composer after one extra Enter; 3 = layout unknown (caller uses the legacy check); 4 = pane
# unreadable. <snippet> is the first characters of what was typed.
# Proof (review finding 8) is one of: the text was SEEN in the composer and the composer is now empty
# (two reads running); a history row with the text that was not there before typing (count above
# <base_hist>); a move into `working` from a <base_state> that was not working. A state that already
# existed (an old question, an old identical line, an approval) proves nothing.
_osrc_send_verify_screen() { # <pane> <engine> <snippet> [base_state] [base_hist] [seen_typed 0|1]
  local pane="$1" eng="$2" snip="$3" base="${4:-unknown}" bhist="${5:-}" seen="${6:-0}" secs polls i cap retried=0 cleared=0 run=0
  case "$bhist" in ''|*[!0-9]*) bhist=999999 ;; esac   # no baseline -> history can never be the proof
  secs="${OSRC_SEND_VERIFY_SECS:-8}"; case "$secs" in ''|*[!0-9]*) secs=8 ;; esac
  polls=$((secs * 4)); OSRC_SEND_EVIDENCE=""
  i=0
  while [ "$i" -lt "$polls" ]; do
    cap="$(_osrc_screen_capture "$pane")" || return 4
    _osrc_screen_analyze_text "$eng" <<<"$cap"
    if [ "$OSRC_SCR_GENERIC" = 1 ] && [ "$OSRC_SCR_COMPOSER_FOUND" != 1 ]; then
      if [ "$OSRC_SCR_STATE" = working ] && [ "$base" != working ]; then OSRC_SEND_EVIDENCE="working (was $base): $OSRC_SCR_EVIDENCE"; return 0; fi
      [ "$i" -ge 2 ] && return 3
    elif [ "$OSRC_SCR_COMPOSER_FOUND" = 1 ] && [ -n "$OSRC_SCR_COMPOSER" ]; then
      run=0
      # Text still sitting in the composer (or a "[Pasted text ...]" chip). One more Enter, once.
      if [ "$retried" = 0 ] && [ "$i" -ge 6 ]; then
        tmux send-keys -t "$pane" Enter 2>/dev/null; retried=1; seen=1
      elif [ "$retried" = 1 ] && [ "$i" -ge 14 ]; then
        OSRC_SEND_EVIDENCE="text still in the composer after Enter x2: $(printf '%s' "$OSRC_SCR_COMPOSER" | cut -c1-80)"
        return 1
      fi
    else
      cleared=1; run=$((run + 1))
      if [ "$OSRC_SCR_STATE" = working ] && [ "$base" != working ]; then OSRC_SEND_EVIDENCE="working (was $base): $OSRC_SCR_EVIDENCE"; return 0; fi
      if [ "$OSRC_SCR_COMPOSER_FOUND" = 1 ] && [ "$(_osrc_scr_history_count "$snip")" -gt "$bhist" ]; then
        OSRC_SEND_EVIDENCE="new history row with the text above the composer"; return 0
      fi
      if [ "$seen" = 1 ] && [ "$run" -ge 2 ]; then
        OSRC_SEND_EVIDENCE="text seen in the composer, composer empty after Enter (now $OSRC_SCR_STATE)"; return 0
      fi
    fi
    sleep 0.25
    i=$((i + 1))
  done
  if [ "$cleared" = 1 ]; then OSRC_SEND_EVIDENCE="no proof this send landed within ${secs}s: text never seen in the composer, no new history row, no move into working (was $base, now $OSRC_SCR_STATE)"; return 2; fi
  OSRC_SEND_EVIDENCE="text still in the composer after ${secs}s: $(printf '%s' "$OSRC_SCR_COMPOSER" | cut -c1-80)"
  return 1
}

# Return codes: 0 = submitted and VERIFIED (screen proof: the composer cleared and the engine reacted
# or the text is in history; or an external receipt adapter proved delivery); 2 = submitted (the text
# left the composer) but no reaction was observed, or only the legacy check could run; 1 = genuine
# failure (nothing typed, send failed, or the text never left the composer). OSRC_SEND_EVIDENCE holds
# the reason for the caller. The obligation log records `submitted` with a "screen:" receipt on rc 0.
_managed_session_send() { # <session-id> <message>
  local session_id="$1" message="$2" pane="$1" oid key composer receipt generation typed_tail sub_rc tail_rc eng snip spilled spillf="" base bhist seen cap
  OSRC_SEND_EVIDENCE=""
  _managed_endpoint_live "$session_id" "$pane" || { OSRC_SEND_EVIDENCE="session endpoint not provably live"; return 1; }
  # E6: one obligation per send. A repeated identical message is a new send, not a replay.
  oid="send.$session_id.$(printf '%s' "$message" | cksum | awk '{print $1}').$(date +%s).$$$RANDOM"
  _obligation_admit "$oid" "$session_id" || { OSRC_SEND_EVIDENCE="obligation ledger refused the send"; return 1; }
  # Long message: spill only once the send is admitted; a refusal before typing removes the file.
  if [ "${#message}" -gt "${OSRC_SEND_MAX_CHARS:-1500}" ]; then
    spilled="$(_osrc_send_spill "$pane" "$message")" && { message="$spilled"; spillf="$(printf '%s' "$spilled" | sed 's/^Read the file \([^ ]*\) .*/\1/')"; }
  fi
  _endpoint_mutation_lock "$pane" || { OSRC_SEND_EVIDENCE="endpoint lock busy"; [ -n "$spillf" ] && rm -f "$spillf"; return 1; }
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  _managed_endpoint_live "$session_id" "$pane" || { _endpoint_mutation_unlock "$key"; [ -n "$spillf" ] && rm -f "$spillf"; OSRC_SEND_EVIDENCE="session endpoint not provably live"; return 1; }
  # One read, under the lock, BEFORE any key (round-2 review finding 1). It is both the modal guard
  # and the send baseline (round-1 finding 8: what is on screen now proves nothing about this send).
  # An open approval/question with no composer gets zero keys, not even C-u: on Devin a typed `e`
  # opens edit mode and the text lands in the pending command.
  eng="$(_osrc_screen_engine_of "$pane")"
  snip="$(printf '%s' "$message" | tr -s ' \t\n' '   ' | cut -c1-24)"
  base="unknown"; bhist=""; OSRC_SEND_MODAL=0
  if cap="$(_osrc_screen_capture "$pane")"; then
    _osrc_screen_analyze_text "$eng" <<<"$cap"; base="$OSRC_SCR_STATE"; bhist="$(_osrc_scr_history_count "$snip")"
    if [ "${OSRC_SCR_COMPOSER_FOUND:-0}" != 1 ] && { [ "$base" = approval ] || [ "$base" = question ]; }; then
      OSRC_SEND_MODAL=1; OSRC_SEND_EVIDENCE="modal open ($base): $OSRC_SCR_EVIDENCE; nothing typed"
      [ -n "$spillf" ] && rm -f "$spillf"; _endpoint_mutation_unlock "$key"; return 1
    fi
  fi
  _tmux_reset_input "$pane"
  _obligation_append "$oid" "$session_id" typing_started "" || { _endpoint_mutation_unlock "$key"; [ -n "$spillf" ] && rm -f "$spillf"; return 1; }
  _obligation_guard_begin "$oid" "$session_id"
  composer="$(_managed_composer_state "$session_id" "$pane" 2>/dev/null)"
  [ "$composer" = empty ] || { OSRC_SEND_EVIDENCE="composer not empty before typing (unsent text or unreadable)"; [ -n "$spillf" ] && rm -f "$spillf"; _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  tmux send-keys -t "$pane" -l -- "$message" || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  # Before Enter: did the text land in the composer, or did a prompt open and take the keys?
  seen=0
  if cap="$(_osrc_screen_capture "$pane")"; then
    _osrc_screen_analyze_text "$eng" <<<"$cap"
    if [ "$OSRC_SCR_COMPOSER_FOUND" != 1 ] && { [ "$OSRC_SCR_STATE" = approval ] || [ "$OSRC_SCR_STATE" = question ]; }; then
      OSRC_SEND_MODAL=1; OSRC_SEND_EVIDENCE="a $OSRC_SCR_STATE prompt opened while typing, so the keys went into it; Enter NOT pressed: $OSRC_SCR_EVIDENCE"
      _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1
    fi
    case "$(printf '%s' "$OSRC_SCR_COMPOSER" | tr -s ' \t\n' '   ')" in
      *"$(printf '%s' "$snip" | cut -c1-12)"*|*"[Pasted text"*) [ -n "$snip" ] && seen=1 ;;
    esac
  fi
  # Pre-Enter snapshot for the legacy check (unknown layouts). A failed capture means there is no
  # baseline to prove anything against: fail closed.
  typed_tail="$(_managed_pane_tail "$pane" 2>/dev/null)"; tail_rc=$?
  if [ "$tail_rc" -eq 2 ]; then
    OSRC_SEND_EVIDENCE="pane unreadable before Enter"; _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1
  fi
  tmux send-keys -t "$pane" Enter || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  _osrc_send_verify_screen "$pane" "$eng" "$snip" "$base" "$bhist" "$seen"; sub_rc=$?
  if [ "$sub_rc" -eq 3 ]; then
    _managed_send_submitted "$pane" "$typed_tail"; sub_rc=$?
    case "$sub_rc" in
      0) sub_rc=2; OSRC_SEND_EVIDENCE="legacy check: bottom line changed (layout not recognised)" ;;
      2) sub_rc=4 ;;
      *) OSRC_SEND_EVIDENCE="legacy check: pane never changed after Enter" ;;
    esac
  fi
  case "$sub_rc" in
    0|2) : ;;
    4) OSRC_SEND_EVIDENCE="pane unreadable after Enter"; _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1 ;;
    *) _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1 ;;
  esac
  generation="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$session_id" 'select(.event=="start" and .session_id==$id) | .model_generation // empty' | tail -1)"
  [ -n "$generation" ] || generation=1
  case "$(_external_probe_configured "${OSRC_EXTERNAL_RECEIPT_PROBE:-}"; echo $?)" in
    0) receipt="$(_external_receipt_verify "$pane" "$oid" 2>/dev/null)"
       if _external_receipt_valid "$receipt" "$pane" "$oid" "$generation"; then
         _obligation_append "$oid" "$session_id" submitted "$receipt" || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
         _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 0
       fi
       _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1 ;;
    2) _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1 ;;
  esac
  if [ "$sub_rc" -eq 0 ]; then
    _obligation_append "$oid" "$session_id" submitted "screen:$(printf '%s' "$OSRC_SEND_EVIDENCE" | cut -c1-120)" >/dev/null 2>&1 || true
    _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 0
  fi
  _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 2
}

# Resolve provider/model for a session subcommand from its start record when --provider/-m were not
# given. `session effort medium` on a Claude session used to resolve the global default lane (devin)
# and print "effort recorded as advisory for devin".
_osrc_session_adopt_record() {
  local rec p m
  rec="$(_session_record "$SESSION_NAME" 2>/dev/null)" || return 0
  [ -n "$rec" ] || return 0
  p="$(printf '%s' "$rec" | cut -f1)"; m="$(printf '%s' "$rec" | cut -f2)"
  [ "${PROVIDER_EXPLICIT:-0}" = 1 ] || { [ -n "$p" ] && PROVIDER="$p"; }
  [ "${MODEL_EXPLICIT:-0}" = 1 ] || { [ -n "$m" ] && MODEL="$m"; }
  return 0
}

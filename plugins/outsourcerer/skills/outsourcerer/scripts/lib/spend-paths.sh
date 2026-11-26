# =============================================================================
# lib/spend-paths.sh — spend gate on the launch paths that bypassed it
#
# Each helper here closes a path where a model could start without the spend
# question (osrc-spend-attack lane, tests/test_spend_attack.sh):
#   * `session control relaunch` and `session effort` start a NEW process on the
#     recorded model; consent given to the original `session start` covered that
#     one command only, so the relaunch asks again.
#   * `session model NAME` switches a live TUI to another model through its picker.
#   * A Devin launch with no -m (`session start`, `continue`) passed an EMPTY
#     --model to the CLI, while the gate judged the lane's Free default. The launch
#     now uses exactly that default, so the judged id is the launched id.
# =============================================================================

# _osrc_dv_model_or_default <token> -> the Devin id to launch: the resolved token, or
# when none was given the lane's run-time Free default (the id the spend gate judges
# for an empty model). Never prints an empty id.
_osrc_dv_model_or_default() {
  local m; m="$(_devin_resolve_model "${1:-}")"
  [ -n "$m" ] || m="$(_devin_default_free_model 2>/dev/null)"
  printf '%s' "${m:-swe-2-high}"
}

# _osrc_session_lane <provider> -> the lane code the session spend gate bills, same
# chain as _osrc_session_spend_gate (native first, then token, else the raw name).
_osrc_session_lane() {
  local p="${1:-}" l
  l="$(_lane_by_native "$p" 2>/dev/null)"; [ -n "$l" ] || l="$(_lane_by_token "$p" 2>/dev/null)"
  printf '%s' "${l:-$p}"
}

# _osrc_session_relaunch_gated <pane> <provider> <model> <effort> -> spend-gate the
# relaunch exactly like a session start, then relaunch. A refusal dies before the
# pane is touched.
_osrc_session_relaunch_gated() {
  [ -n "${OSRC_SPEND_NEXT:-}" ] || OSRC_SPEND_NEXT="$0 --spend-ok session control relaunch"
  _osrc_spend_gate "$(_osrc_session_lane "$2")" "$3" "$2" "session relaunch (a new process; consent covers one command)" || return 1
  _session_control_relaunch "$@"
}

# _session_relaunch_effort <provider> <model> <effort> — effort changes replace the pane
# process just like control relaunch, so they reuse the gated lifecycle path. Proven live,
# persisted, supervised and endpoint-verified before the caller records the effort event.
_session_relaunch_effort() {
  _osrc_session_relaunch_gated "$SESSION_NAME" "$1" "$2" "$3" >/dev/null
}

# _osrc_session_model_gate [NAME] -> `session model` refuses an excluded NAME, then
# spend-gates the switch. Devin's picker selects by search text, so the gate judges the
# exact NAME; with no NAME the picker's choice is unknown and the gate asks. The lane judged is the
# session's RECORDED provider (the TUI _managed_session_model drives); an explicit --provider that
# names another lane is refused, or it would bill-check one lane and switch another (rv F2).
_osrc_session_model_gate() {
  local name="${1:-}" prov
  [ -n "$name" ] && _exclude_refuse "$name" "session model"
  prov="$(_session_record "${SESSION_NAME:-}" 2>/dev/null | cut -f1)"
  if [ -n "$prov" ] && [ "${PROVIDER_EXPLICIT:-0}" = 1 ] && [ "$(_osrc_session_lane "${PROVIDER:-}")" != "$(_osrc_session_lane "$prov")" ]; then
    die "session model refused: --provider ${PROVIDER:-} does not match session '${SESSION_NAME:-}', which runs $prov. Nothing was switched. Drop --provider:  $0 session model${name:+ $(printf '%q' "$name")}"
  fi
  prov="${prov:-${PROVIDER:-}}"
  [ -n "${OSRC_SPEND_NEXT:-}" ] || OSRC_SPEND_NEXT="$0 --spend-ok session model${name:+ $(printf '%q' "$name")}"
  _osrc_spend_gate "$(_osrc_session_lane "$prov")" "$name" "$prov" "session model switch"
}
# _osrc_or_member_gate <model> -> delegate_cc / delegate_codex judge EVERY OpenRouter chain member
# before launching it. route_delegate showed (and the user consented to) one model; on a transport
# failure the chain escalates to the next metered model, which must be judged and shown too, so a
# consent bound to the first model never covers a different one (torture-room arch F6).
_osrc_or_member_gate() {
  [ -n "${OSRC_SPEND_NEXT:-}" ] || OSRC_SPEND_NEXT="$0 --spend-ok run -m $(printf '%q' "${1:-}")"
  _osrc_spend_gate or "${1:-}" openrouter "OpenRouter chain model ${1:-} (consent names one model)"
}

# _osrc_session_send_model_gate <text> -> `session send "/model X"` drives the same TUI picker as
# `session model X`, so it passes the same gate (live-test F3). The first token is matched in any
# case after leading blanks. One plain id after it is gated as `session model <id>` on the session's
# recorded provider; no id or anything else after /model is refused (the pick would be unknown).
_osrc_session_send_model_gate() {
  local t="${1:-}" arg rest
  t="${t#"${t%%[![:space:]]*}"}"
  case "$t" in /[Mm][Oo][Dd][Ee][Ll]|/[Mm][Oo][Dd][Ee][Ll][[:space:]]*) ;; *) return 0 ;; esac
  read -r _ arg rest <<<"$t"
  case "$arg" in ''|*[!A-Za-z0-9._:/@-]*) arg="" ;; esac
  [ -n "$arg" ] && [ -z "$rest" ] || die "session send refused: text starting with /model switches the model with no spend check. Nothing was typed. Use:  $0 session model <name>"
  _osrc_session_model_gate "$arg"
}

# _osrc_take_spend_ok <args...> -> _OSRC_ARGS = args without any --spend-ok before `--` (each one
# sets OSRC_SPEND_OK=1). `loop verify|escalate|resume --spend-ok` then consent like a leading flag.
_osrc_take_spend_ok() {
  _OSRC_ARGS=(); local dd=0 a
  for a in "$@"; do
    if [ "$dd" = 0 ] && [ "$a" = --spend-ok ]; then OSRC_SPEND_OK=1; continue; fi
    [ "$a" = -- ] && dd=1; _OSRC_ARGS+=("$a")
  done
  return 0
}
# _osrc_loop_needs_approval <shape> <lid> <ldir> <attempt> <next> -> rc0 when the attempt never ran
# because a spend/cap gate refused it (its EVENT approval line, or the fail-closed lib refusal).
# The loop then stops as needs-approval with one EVENT + NEXT: no check graded, no attempt counted
# (resume re-runs it), no escalation, no receipt for a run that did not launch (live-test F5).
_osrc_loop_needs_approval() {
  local out="$3/attempt-$4.out" ev
  ev="$(grep -a '^EVENT approval ' "$out" 2>/dev/null | tail -1)"
  [ -n "$ev" ] || grep -aq 'spend/cap gate library .* missing or damaged' "$out" 2>/dev/null || return 1
  [ -n "$ev" ] || ev="EVENT approval loop 0 spend gate library damaged"
  echo "[loop $1] $2: attempt $4 was not launched: a spend/cap gate needs your approval (nothing spent, no attempt counted). Approve with --spend-ok on the loop; each attempt's consent binds to that attempt's own lane/model." >&2
  printf 'needs approval: %s\n' "${ev#EVENT approval * * }" > "$3/last_fail" 2>/dev/null || true
  printf '%s\n' "$(( $4 - 1 ))" > "$3/attempt" 2>/dev/null || true
  _osrc_event approval "loop:$2" "${ev#EVENT approval * * }" "$5" spend
}

# _osrc_fanout_preflight <verb> -> bg's route preflight (spend, cap, dispatch) once per distinct
# provider|model the fanout members resolve to (same precedence as the launch loop: -m > --route >
# agent frontmatter > lane default), BEFORE any job is minted. One refusal refuses the whole fanout
# with its EVENT/NEXT, instead of "all N launched" and N exit-nonzero jobs (live-test F6). Reads the
# caller's labels/a_model/a_prov/g_model/g_prov/route_spec. Pairs approved at an interactive prompt
# consent their members (each member's marker binds to its own pair).
_osrc_fanout_preflight() {
  local verb="$1" i m p r seen=" " flag="${OSRC_SPEND_OK:-0}" asked=0 eng="$SCRIPT_PATH"
  # The engine itself, even when it was sourced (SCRIPT_PATH is then the sourcing script).
  [ -f "${_OSRC_FACTORY_DIR:-}/outsourcerer.sh" ] && eng="$_OSRC_FACTORY_DIR/outsourcerer.sh"
  for i in "${!labels[@]}"; do
    m="$g_model"; [ -z "$m" ] && [ -n "$route_spec" ] && m="$(_route_match "${labels[$i]}" "$route_spec")"
    [ -z "$m" ] && m="${a_model[$i]}"
    p="${g_prov:-${a_prov[$i]}}"
    case "$seen" in *" ${p:-$PROVIDER}|$m "*) continue ;; esac; seen="$seen${p:-$PROVIDER}|$m "
    # local lanes never spend (the same short-circuit fanout's cloud pre-ack uses)
    case "${p:-$PROVIDER}:$m" in local:*|*:ollama:*|*:lmstudio:*|*:lms:*|*:local|*:local:*) continue ;; esac
    local -a _pf_provider=() _pf_spend=() _pf_args=("$verb")
    { [ -n "$p" ] || [ "${PROVIDER_EXPLICIT:-0}" = 1 ]; } && _pf_provider=(--provider "${p:-$PROVIDER}")
    [ "$flag" = 1 ] && _pf_spend=(--spend-ok)
    [ -n "$m" ] && _pf_args+=(-m "$m"); _pf_args+=("fanout preflight")
    r="$(OSRC_SPEND_OK= OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_PROVIDER_ARG="${OSRC_PROVIDER_ARG:-0}" OSRC_PROVIDER_INJECTED="$(( ${#_pf_provider[@]} / 2 ))" \
         OSRC_SPEND_NEXT="${OSRC_SPEND_NEXT:-}" _osrc_bg_preflight "$eng")" \
      || die "fanout: refusing to launch -- member ${labels[$i]} (${p:-$PROVIDER}${m:+ / $m}) failed the route preflight (spend/cap/dispatch, see above). Nothing was started."
    [ "$(printf '%s' "$r" | cut -d'|' -f5)" = 1 ] && asked=1
  done
  [ "$asked" = 1 ] && OSRC_SPEND_OK=1
  return 0
}

# Per-task factory consent (torture-room arch F5, exact). `task add --spend-ok -m X` records X on
# the task (a protected field: a tasks file or plan JSON cannot set it), and the confirmation names
# X. Dispatch forwards --spend-ok only while the task still dispatches on exactly X; a retry or
# escalation onto another model asks again. A command-level --spend-ok keeps the first-task bind.
_osrc_task_spend_record() {  # <plan> <tid> <model>
  [ -n "${3:-}" ] || { echo "outsourcerer: task add --spend-ok needs -m <model>: consent covers exactly the id it names. $2 was added without consent." >&2; return 1; }
  _task_update "$1" "$2" '.spend_ok = $m' --arg m "$3" >/dev/null 2>&1 || return 1
  printf '>>> [spend] consent recorded for %s on task %s (this id only; any other model it dispatches on asks again).\n' "$3" "$2" >&2
}
_osrc_task_spend_own() {  # <task-json> <dispatch-model> -> rc0 when the task's own consent covers it
  _OSRC_TASK_OWN_CONSENT=0
  [ -n "${2:-}" ] && [ "$(printf '%s' "$1" | jq -r '.spend_ok // ""' 2>/dev/null)" = "$2" ] || return 1
  _OSRC_TASK_OWN_CONSENT=1
}

_OSRC_LIBEND_SPENDPATHS=1   # last line: the loader proves this lib loaded whole (_osrc_spend_libs_ok)

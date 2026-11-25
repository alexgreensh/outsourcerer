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
# exact NAME; with no NAME the picker's choice is unknown and the gate asks.
_osrc_session_model_gate() {
  local name="${1:-}"
  [ -n "$name" ] && _exclude_refuse "$name" "session model"
  [ -n "${OSRC_SPEND_NEXT:-}" ] || OSRC_SPEND_NEXT="$0 --spend-ok session model${name:+ $(printf '%q' "$name")}"
  _osrc_spend_gate "$(_osrc_session_lane "${PROVIDER:-}")" "$name" "${PROVIDER:-}" "session model switch"
}
# _osrc_or_member_gate <model> -> delegate_cc / delegate_codex judge EVERY OpenRouter chain member
# before launching it. route_delegate showed (and the user consented to) one model; on a transport
# failure the chain escalates to the next metered model, which must be judged and shown too, so a
# consent bound to the first model never covers a different one (torture-room arch F6).
_osrc_or_member_gate() {
  [ -n "${OSRC_SPEND_NEXT:-}" ] || OSRC_SPEND_NEXT="$0 --spend-ok run -m $(printf '%q' "${1:-}")"
  _osrc_spend_gate or "${1:-}" openrouter "OpenRouter chain model ${1:-} (consent names one model)"
}

_OSRC_LIBEND_SPENDPATHS=1   # last line: the loader proves this lib loaded whole (_osrc_spend_libs_ok)

# shellcheck shell=bash
# lib/lane_table.sh: the lane registry as one table, read once per process.
# Sourced by outsourcerer.sh. The table is built once, in the main shell: by the engine right after
# its last lane descriptor, or at the end of this file when the descriptors already exist.
#
# Every `lane_descriptor_<lane>` prints a constant `field=value` list. Reading it on each lookup cost a
# command substitution plus a heredoc per field, inside loops over all 18 lanes: one Devin launch made
# 536 such reads before anything started (~4 s under load). The table holds each field in its own
# variable, _OSRC_LF_<lane>__<field>; a lookup is one indirect expansion, no fork. It is rebuilt only
# when OSRC_LANE_REGISTRY changes. bash 3.2-safe: no associative arrays.

# _lane_table: build the table. The descriptors print with `printf '%s\n' ...`; a printf shim (this shell
# only, removed right after) stores their lines without a subshell per lane. A field's first line wins.
_lane_table() {
  [ "${_OSRC_LT_KEY:-}" = "$OSRC_LANE_REGISTRY" ] && return 0
  local _l _v
  [ -z "${_OSRC_LT_KEY:-}" ] || for _v in $(compgen -v _OSRC_LF_ 2>/dev/null); do unset "$_v"; done   # a changed registry starts clean
  printf() { # shellcheck disable=SC2059
    if [ "$1" = '%s\n' ]; then shift; local x f; for x in "$@"; do
        f="${x%%=*}"; case "$f" in ''|*[!a-z0-9_]*) continue ;; esac
        _v="_OSRC_LF_${_l}__$f"; [ -n "${!_v+x}" ] || builtin printf -v "$_v" '%s' "${x#*=}"; done
    else builtin printf "$@"; fi; }
  for _l in $OSRC_LANE_REGISTRY; do
    case "$_l" in *[!a-z0-9_]*) continue ;; esac
    type "lane_descriptor_$_l" >/dev/null 2>&1 && "lane_descriptor_$_l"
  done
  unset -f printf
  _OSRC_LT_KEY="$OSRC_LANE_REGISTRY"
}

# _lane_fv <lane> <field> -> sets _OSRC_LV to the field's value; rc1 when unregistered or unset. No fork.
_lane_fv() {
  local v
  _OSRC_LV=""
  case " $OSRC_LANE_REGISTRY " in *" ${1:-} "*) ;; *) return 1 ;; esac
  case "${1:-}${2:-}" in ''|*[!a-z0-9_]*) return 1 ;; esac
  _lane_table
  v="_OSRC_LF_${1}__$2"; [ -n "${!v+x}" ] || return 1
  _OSRC_LV="${!v}"
}

# _lane_field <lane> <field> -> the field's value, rc1 when unregistered or unset.
_lane_field() { _lane_fv "${1:-}" "${2:-}" || return 1; printf '%s' "$_OSRC_LV"; }

# _lane_by_token <lane-code|disp|legacy-alias> -> canonical lane name, rc1 unknown.
# Lane context ONLY: provider names never live in name/aliases/disp, so `codex`
# does not resolve here (it is or's transport provider, not a lane token).
_lane_by_token() {
  local t="${1:-}" l pair
  [ -n "$t" ] || return 1
  for l in $OSRC_LANE_REGISTRY; do
    [ "$l" = "$t" ] && { printf '%s' "$l"; return 0; }
    _lane_fv "$l" aliases; case " $_OSRC_LV " in *" $t "*) printf '%s' "$l"; return 0 ;; esac
    _lane_fv "$l" disp; [ "$_OSRC_LV" = "$t" ] && { printf '%s' "$l"; return 0; }
    _lane_fv "$l" disp_by_provider; _words_noglob "$_OSRC_LV"   # split WITHOUT globbing values against cwd
    for pair in ${WORDS[@]+"${WORDS[@]}"}; do
      case "$pair" in *"=$t") printf '%s' "$l"; return 0 ;; esac
    done
  done
  return 1
}

# _lane_by_disp <disp-vehicle> -> canonical lane, rc1 otherwise. Disp context ONLY:
# matches the `disp` field and `disp_by_provider` VALUES — never the canonical name
# or a provider token. This distinction is load-bearing: _is_cloud_lane and
# _route_resolution are keyed on dispatch vehicles, but the session path passes
# raw provider names through them (`session start --provider cc` skips the cloud
# gate today because `cc` hits the `*` arm). Resolving `cc` here would silently
# START gating those sessions, so canonical codes deliberately do not match.
_lane_by_disp() {
  local t="${1:-}" l pair
  [ -n "$t" ] || return 1
  for l in $OSRC_LANE_REGISTRY; do
    _lane_fv "$l" disp; [ "$_OSRC_LV" = "$t" ] && { printf '%s' "$l"; return 0; }
    _lane_fv "$l" disp_by_provider; _words_noglob "$_OSRC_LV"   # split WITHOUT globbing values against cwd
    for pair in ${WORDS[@]+"${WORDS[@]}"}; do
      case "$pair" in *"=$t") printf '%s' "$l"; return 0 ;; esac
    done
  done
  return 1
}

# _lane_by_model_glob <model-token> -> canonical lane whose model_globs match the
# token (local's ollama:/lmstudio:/lms:/local: endpoint prefixes), rc1 otherwise.
_lane_by_model_glob() {
  local m="${1:-}" l g
  [ -n "$m" ] || return 1
  for l in $OSRC_LANE_REGISTRY; do
    _lane_fv "$l" model_globs; _words_noglob "$_OSRC_LV"   # split WITHOUT globbing the patterns against cwd
    for g in ${WORDS[@]+"${WORDS[@]}"}; do
      case "$m" in $g) printf '%s' "$l"; return 0 ;; esac
    done
  done
  return 1
}

# _lane_by_field <field> <token> -> canonical lane whose space-joined field contains
# the token. Generic membership lookup; _lane_by_provider (providers) and _lane_by_native
# (native_of: codex->cx, claude->cc, gemini->gm, the provider's NATIVE family lane) are it.
_lane_by_field() {
  local f="${1:-}" t="${2:-}" l
  [ -n "$f" ] && [ -n "$t" ] || return 1
  for l in $OSRC_LANE_REGISTRY; do
    _lane_fv "$l" "$f"; case " $_OSRC_LV " in *" $t "*) printf '%s' "$l"; return 0 ;; esac
  done
  return 1
}
_lane_by_provider() { [ -n "${1:-}" ] && _lane_by_field providers "$1"; }   # <--provider value> -> canonical lane
_lane_by_native() { [ -n "${1:-}" ] && _lane_by_field native_of "$1"; }

# _lane_flag <token> <field> -> rc0 when the token's lane declares field=yes.
_lane_flag() {
  local l; l="$(_lane_by_token "${1:-}" 2>/dev/null)" || return 1
  _lane_fv "$l" "$2" && [ "$_OSRC_LV" = "yes" ]
}

# _lane_default -> the catch-all implicit-provider lane (dv). Reads default_lane
# from the registry; the literal is the hard floor while dv is unported.
_lane_default() {
  local l
  for l in $OSRC_LANE_REGISTRY; do
    _lane_fv "$l" default_lane && [ "$_OSRC_LV" = "yes" ] && { printf '%s' "$l"; return 0; }
  done
  printf 'dv'
}

# _catalog_path <lane> -> the lane's live catalog file. Lane whitelist: only lanes that declare
# `catalog_lane` (plus dv, the unported floor); a literal set closes any path traversal from a caller
# passing an attacker-influenced lane string.
_catalog_path() {
  local _l
  for _l in $OSRC_LANE_REGISTRY; do
    _lane_fv "$_l" catalog_lane && [ -n "$_OSRC_LV" ] && [ "$_OSRC_LV" = "${1:-}" ] && { printf '%s/catalogs/%s.json' "$OSRC_HOME" "$_OSRC_LV"; return 0; }
  done
  case "${1:-}" in dv) printf '%s/catalogs/%s.json' "$OSRC_HOME" "$1" ;; *) return 1 ;; esac
}

# Sourced after the descriptors (the engine sourced by a test or helper loads lib/ at its end): build now,
# in this shell, so no lookup inside a $(...) has to.
type lane_descriptor_or >/dev/null 2>&1 && _lane_table

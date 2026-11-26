# shellcheck shell=bash
# lib/hub-lanemeta.sh: who built a Mission Control track (lane, model) and which PR carries it.
# Sourced by outsourcerer.sh; function definitions only.
#
# Every track's hover reads "Lane: ...", the model, and its issues and PRs. Board tracks name them in
# the orchestrator's `hub report --board`; the tracks Outsourcerer derives on its own (jobs, sessions,
# cloud lanes) get the lane from their launch record (lib/hub.sh builders, via _osrc_hub_lane_label)
# and the PR from the GitHub cache the history pass already keeps (lib/hub-history.sh). This file
# never calls the network: a repo with no cache simply shows no PR yet.

# _osrc_hub_lane_label <lane-code|provider> [vehicle] -> sets _OSRC_LL to a human lane name. No fork.
_osrc_hub_lane_label() {
  case "${1:-}" in
    remote) case "${2:-}" in
        '') _OSRC_LL="Cloud lane" ;;
        claude*) _OSRC_LL="Claude cloud" ;; codex*) _OSRC_LL="Codex cloud" ;; devin*) _OSRC_LL="Devin cloud" ;;
        *) _OSRC_LL="$2 cloud" ;;
      esac ;;
    dv|devin) _OSRC_LL="Devin" ;;
    cx|codex) _OSRC_LL="Codex" ;;
    cc|claude) _OSRC_LL="Claude Code" ;;
    gm|gemini|agy) _OSRC_LL="Gemini" ;;
    gi) _OSRC_LL="Gemini API" ;;
    ci) _OSRC_LL="Image" ;;
    or|openrouter|ccor|codexor) _OSRC_LL="OpenRouter" ;;
    droid) _OSRC_LL="Factory Droid" ;;
    cursor) _OSRC_LL="Cursor" ;;
    hermes) _OSRC_LL="Hermes" ;;
    warp) _OSRC_LL="Warp" ;;
    cline) _OSRC_LL="Cline" ;;
    pi) _OSRC_LL="Pi" ;;
    claudex) _OSRC_LL="Claudex" ;;
    tokenrouter) _OSRC_LL="TokenRouter" ;;
    grokbot) _OSRC_LL="Grok" ;;
    opencode) _OSRC_LL="OpenCode" ;;
    local) _OSRC_LL="Local model" ;;
    *) _OSRC_LL="${1:-}" ;;
  esac
}

# _osrc_hub_pr_heads [repo-slug] -> {"<branch>": "#N", ...} from the cached `gh pr list` (hub/cache/gh-*.json),
# open PRs winning over closed ones, newest first. With a slug, only that repo's cache is read.
_osrc_hub_pr_heads() {
  local f fs=""
  for f in "$OSRC_HOME"/hub/cache/gh-*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -z "${1:-}" ] || [ "$f" = "$OSRC_HOME/hub/cache/gh-$(printf '%s' "$1" | tr '/' '_').json" ] || continue
    fs="$fs $f"
  done
  [ -n "$fs" ] || { printf '{}'; return 0; }
  # shellcheck disable=SC2086
  jq -cs '[.[] | (.prs // [])[]? | objects | select((.headRefName // "") != "" and .number != null)]
    | sort_by((if (.closedAt // .mergedAt) then 0 else 1 end), .number)
    | map({key: .headRefName, value: ("#" + (.number | tostring))}) | from_entries' $fs 2>/dev/null || printf '{}'
}

# _osrc_hub_lanes_prs <lanes-json> [repo-slug] -> the lanes, each with a branch and no prs given the
# PR whose head is that branch (when the cache knows one).
_osrc_hub_lanes_prs() {
  local h
  case "$1" in *'"branch"'*) ;; *) printf '%s' "$1"; return 0 ;; esac   # no branch anywhere: nothing to look up
  h="$(_osrc_hub_pr_heads "${2:-}")"
  [ "$h" = '{}' ] && { printf '%s' "$1"; return 0; }
  jq -c --argjson h "$h" 'map(if ((.prs // "") == "") and ((.branch // "") != "") and $h[.branch] then . + {prs: $h[.branch]} else . end)' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

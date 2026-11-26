# shellcheck shell=bash
# lib/hub-lanemeta.sh: what a Mission Control track says beyond its raw state: who built it (lane,
# model), which PR carries it, and states the builders in lib/hub.sh must not round up to "Done".
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

# _osrc_hub_pr_heads [repo-slug] [merged] -> {"<branch>": "#N", ...} from the cached `gh pr list` (hub/cache/gh-*.json),
# open PRs winning over closed ones, newest first. With a slug, only that repo's cache is read. With
# "merged", only merged PRs: {"<branch>": true}.
_osrc_hub_pr_heads() {
  local f fs=""
  for f in "$OSRC_HOME"/hub/cache/gh-*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -z "${1:-}" ] || [ "$f" = "$OSRC_HOME/hub/cache/gh-$(printf '%s' "$1" | tr '/' '_').json" ] || continue
    fs="$fs $f"
  done
  [ -n "$fs" ] || { printf '{}'; return 0; }
  # shellcheck disable=SC2086
  jq -cs --arg m "${2:-}" '[.[] | (.prs // [])[]? | objects | select((.headRefName // "") != "" and .number != null)]
    | if $m == "merged" then map(select(.mergedAt) | {key: .headRefName, value: true}) | from_entries else
      sort_by((if (.closedAt // .mergedAt) then 0 else 1 end), .number)
    | map({key: .headRefName, value: ("#" + (.number | tostring))}) | from_entries end' $fs 2>/dev/null || printf '{}'
}

# _osrc_hub_landed <id> [head] -> rc0 when a merge of the lane's work is evidenced: its cloud record says
# landed, or a review item of it (of that head, when given) closed as merged. A MERGE verdict alone is an
# approval, not a merge: the page says Approved until one of these (or a merged PR, below) shows up.
_osrc_hub_landed() {
  local f
  [ "$(jq -r '.landed // false' "$OSRC_HOME/remote/$1.json" 2>/dev/null)" = true ] && return 0
  for f in "$OSRC_HOME/review/items/$1"-*.json; do
    [ -f "$f" ] && jq -e --arg h "${2:-}" '.state == "closed" and .closed_reason == "merged" and ($h == "" or .head == $h)' "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# _osrc_hub_lanes_prs <lanes-json> [repo-slug] -> the lanes, each with a branch and no prs given the
# PR whose head is that branch (when the cache knows one); an Approved lane whose PR merged reads Merged.
_osrc_hub_lanes_prs() {
  local h mg
  case "$1" in *'"branch"'*) ;; *) printf '%s' "$1"; return 0 ;; esac   # no branch anywhere: nothing to look up
  h="$(_osrc_hub_pr_heads "${2:-}")"
  [ "$h" = '{}' ] && { printf '%s' "$1"; return 0; }
  mg="$(_osrc_hub_pr_heads "${2:-}" merged)"
  jq -c --argjson h "$h" --argjson mg "$mg" 'map(if ((.prs // "") == "") and ((.branch // "") != "") and $h[.branch] then . + {prs: $h[.branch]} else . end
    | if .status == "Approved" and $mg[.branch // ""] then . + {status: "Merged", pct: 100} else . end)' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# ---- states the builders must not round up -------------------------------------------------------
_osrc_hub_job_state() {
  local id="$1" jd="$OSRC_JOBS/$1" st rc
  st="$(_reconcile_status "$id" 2>/dev/null || cat "$jd/status" 2>/dev/null)"
  case "$st" in running|working|live|launching|stalled\?|exploring\?|no-progress-writes)
    # A supervisor may outlive the delegate whose exit it has already recorded. Exit 0 is not proof of
    # done until reconcile has seen the OSRC::DONE marker: unverified, the same as reconcile would say
    # without it, so a lane never reads Done and then flips back to Unverified.
    if [ -s "$jd/exit" ]; then
      rc="$(cat "$jd/exit" 2>/dev/null)"
      case "$rc" in 0) st='done?' ;; ''|*[!0-9]*) : ;; *) st=failed ;; esac
    fi ;;
  esac
  printf '%s' "$st"
}

# _osrc_hub_ad_failed <id> -> 0 when an auto-detached run recorded a non-zero exit (autodetach/<id>.rc):
# it failed, whatever a done verdict or the closed pane suggests. No fork.
_osrc_hub_ad_failed() {
  local rc="" f="$OSRC_HOME/autodetach/$1.rc"
  [ -s "$f" ] || return 1
  IFS= read -r rc 2>/dev/null < "$f"; rc="${rc//[!0-9]/}"
  [ -n "$rc" ] && [ "$rc" != 0 ]
}
# _osrc_hub_paused <id> <state> -> 0 when the disk policy paused this still-running lane (lib/disk_policy.sh).
_osrc_hub_paused() {
  case "${2:-}" in done|done\?|failed|canceled|gone|interrupted) return 1 ;; esac
  type _osrc_disk_target_paused >/dev/null 2>&1 && _osrc_disk_target_paused "$1" 2>/dev/null
}

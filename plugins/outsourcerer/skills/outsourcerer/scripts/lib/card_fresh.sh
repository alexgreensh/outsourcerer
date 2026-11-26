# shellcheck shell=bash
# lib/card_fresh.sh: an orchestrator may not end a turn while its Mission Control card is stale.
# Orchestrators must keep their card current: it is the project's public status.
# A board read 14 h after the questions were answered elsewhere is worse than no board. The Stop
# hook (cmd_stop_guard) asks this first: when the session's card was last reported more than
# OSRC_CARD_STALE_MIN minutes ago (default 30), or a question on it has waited more than
# OSRC_DECISION_STALE_H hours (default 2) without being re-confirmed, the stop is blocked with the
# exact `hub report` commands to run. A board track that names no model or lane is stale too, and so is
# one whose branch has a PR (GitHub cache) that it does not name: the hover card is where the user reads
# who built it. A session that owns lanes and never reported is asked too (its card reads "never"). Supervise turns the same check into an EVENT card
# on its 10-min tick, so an orchestrator that rarely ends a turn is still asked.
# Loop safety: at most one block per OSRC_CARD_STALE_MIN window.
# OSRC_CARD_GUARD=0 turns it off. Any error allows the stop.

# _sg_board_unnamed <project-json> -> the board tracks that name no model or no lane, or whose branch
# has a known PR (lib/hub-lanemeta.sh) while they name no prs, comma-joined.
_SG_UNNAMED_JQ='[(.board.tasks // [])[]? | objects
      | select(((.model // "") | tostring) == "" or ((.lane // "") | tostring) == ""
          or (((.prs // "") | tostring) == "" and ((.branch // "") | type) == "string" and $h[.branch // ""] != null))
      | ((.short // .name // .id // "?") | tostring)[0:50]] | join(", ")'
_sg_pr_heads() { local f; for f in "$OSRC_HOME"/hub/cache/gh-*.json; do [ -f "$f" ] && type _osrc_hub_pr_heads >/dev/null 2>&1 && { _osrc_hub_pr_heads; return 0; }; done; printf '{}'; }
_sg_board_unnamed() { jq -r --argjson h "$(_sg_pr_heads)" "$_SG_UNNAMED_JQ" "$1" 2>/dev/null; }
# Decisions older than <lim> seconds that are still open, as "id (question)", comma-joined.
_SG_OLD_JQ='map(objects | select(.status != "done") | select(((.confirmedAt // .askedAt // "" | tostring) | sub("\\.[0-9]+";"") | fromdateiso8601? // $now) < ($now - $lim)))
      | map("\(.id // "?") (\((.q // .short // "" | tostring)[0:60]))") | join(", ")'

# _sg_card_nag <sid> -> prints a block reason and returns 0 when the card needs a refresh now.
_sg_card_nag() {
  [ "${OSRC_CARD_GUARD:-1}" = "0" ] && return 1
  have jq || return 1
  local sid="$1" pf="$OSRC_HOME/hub/projects/$1.json" df="$OSRC_HOME/hub/decisions/$1.json" sf="$OSRC_HOME/hub/status/$1.json"
  local smin="${OSRC_CARD_STALE_MIN:-30}" dh="${OSRC_DECISION_STALE_H:-2}" st="" name age="" mk mt old="" old_b="" n now
  case "$smin" in ''|*[!0-9]*) smin=30 ;; esac; case "$dh" in ''|*[!0-9]*) dh=2 ;; esac
  # A session that owns lanes and has no card is asked only where the caller allows it (_SG_CARD_OWNED=1:
  # the stop guard once nothing more urgent blocks the stop, and supervise's card EVENT).
  local owns=0 f
  [ "${_SG_CARD_OWNED:-0}" = 1 ] && for f in "$OSRC_HOME/owners/$sid"/*; do
    [ -f "$f" ] || continue; case "${f##*/}" in watch.*) continue ;; esac; owns=1; break; done
  [ -f "$pf" ] || [ -f "$df" ] || [ "$owns" = 1 ] || return 1
  if [ ! -L "$OSRC_HOME/hub/status" ] && [ -f "$sf" ] && [ ! -L "$sf" ]; then
    jq -e 'type == "object" and (.shippedBy == "user" or .status == "shipped")' "$sf" >/dev/null 2>&1 && return 1
  fi
  now="$(date +%s)"
  local hasb=0 unnamed="" ok=1 rec
  name="this project"
  if [ -f "$pf" ]; then
    # Every card field in ONE jq (it was nine): ok, status, name, report age, stale board questions,
    # has a board, unnamed tracks. \037 separates; newlines inside values become spaces.
    rec="$(jq -r --argjson lim $(( dh * 3600 )) --argjson now "$now" --argjson h "$(_sg_pr_heads)" '
      def one: tostring | gsub("[\n\u001f]"; " ");
      if type != "object" then "0" else
      [ "1", (.status // ""), (.name // "this project"),
        ((.reportedAt // "") | tostring | if . == "" then "" else (sub("\\.[0-9]+";"") | fromdateiso8601? // null | if . == null then "" else ($now - .) end) end),
        ((if (.board | type) == "object" and (.board.decisions | type) == "array" then .board.decisions else [] end) | '"$_SG_OLD_JQ"'),
        (if (.board | type) == "object" and (.board.tasks | type) == "array" and (.board.tasks | length) > 0 then 1 else 0 end),
        ('"$_SG_UNNAMED_JQ"') ] | map(one) | join("\u001f") end' "$pf" 2>/dev/null)" || return 1
    IFS=$'\037' read -r ok st name age old_b hasb unnamed <<<"$rec"
    [ "$ok" = 1 ] || return 1
    [ "$st" = shipped ] && return 1
    name="${name:-this project}"; [ "$hasb" = 1 ] || unnamed=""
  fi
  if [ -f "$df" ]; then
    old="$(jq -r --argjson lim $(( dh * 3600 )) --argjson now "$now" '
      (if type == "array" then . elif type == "object" and (.decisions | type) == "array" then .decisions else [] end) | '"$_SG_OLD_JQ" "$df" 2>/dev/null)"
  fi
  [ -z "$old_b" ] || old="${old:+$old, }$old_b"
  if [ ! -f "$pf" ] && [ -z "$old" ] && [ "$owns" = 0 ]; then return 1; fi
  if [ -z "$old" ] && [ -z "$unnamed" ] && [ "$hasb" = 1 ] && [ -n "$age" ] && [ "$age" -lt $(( smin * 60 )) ]; then return 1; fi
  local mkd="$OSRC_HOME/hub/card-nag"
  mk="$mkd/$sid"
  [ -L "$OSRC_HOME/hub" ] || [ -L "$mkd" ] || [ -L "$mk" ] && return 1
  if [ -f "$mk" ]; then
    mt="$(stat -c %Y "$mk" 2>/dev/null || stat -f %m "$mk" 2>/dev/null || echo 0)"
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    [ $(( now - mt )) -lt $(( smin * 60 )) ] && return 1
  fi
  mkdir -p "$mkd" 2>/dev/null && [ ! -d "$mk" ] && : > "$mk" 2>/dev/null || return 1
  n="$( [ -n "$age" ] && printf '%s min ago' $(( age / 60 )) || printf 'never')"
  printf 'Outsourcerer: the user reads Mission Control as the truth, and your card for "%s" was last reported %s.' "$name" "$n"
  [ -z "$old" ] || printf ' These questions on it are over %s h old: %s.' "$dh" "$old"
  [ -z "$unnamed" ] || printf ' These board tracks do not say who built them: %s.' "$unnamed"
  printf '\nBefore ending your turn, from this session:\n  %s hub report --pct <N> --next "<one line>" [--status building|review|waiting|shipped]\n' "$SCRIPT_PATH"
  printf '  For every question already answered anywhere (chat, a board): %s hub report --done-ask <id>\n' "$SCRIPT_PATH"
  printf '  A question still open: re-ask it with --why "<background>" --rec "<your pick>" and close the old id, so its age is honest.\n'
  printf '  Publish your board (the same JSON your board page renders: release, freeze, themes, tasks with human names, decisions): %s hub report --board <board.json>\n' "$SCRIPT_PATH"
  printf '  Every task names its "model" and "lane" (e.g. "Opus 5.5", "Claude cloud"), plus "issues"/"prs" ("#80 #82"), "reviewer" and "branch" when known: the hover card shows them.\n'
  printf 'Plain human words only: no code names, job ids or lane ids anywhere the user reads.'
  return 0
}

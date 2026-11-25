# shellcheck shell=bash
# lib/hub_board.sh: an orchestrator's board drives its Mission Control project page.
# The project page must show THE board, its design and its data: the work tracks
# (not raw job ids), the six-step flow, release, freeze and the board's decisions. The orchestrator
# keeps ONE board JSON (the same {updated, release, releaseNote, freeze, tagline, themes, tasks,
# decisions, flow?} its claude.ai board renders) and publishes it with `hub report --board <file>`.
# The card stores it under .board; the export below turns it into the project's lanes, pct, eta,
# freeze, themes, flow and decisions. Jobs still decide liveLanes (is anything running).

_OSRC_BOARD_FLOW='[
 {"t":"Build","i":"hammer","match":["building","queued","blocked"],"w":"Lanes write the fix","d":"Each track builds in its own branch, in the cloud or on the Mac."},
 {"t":"Review","i":"eye","match":["reviewing","fixing","fixing review","review"],"w":"Fresh review, track fixes","d":"A reviewer that did not write the code reads every change before it merges. Real problems go back to the track."},
 {"t":"Merged","i":"git-merge","match":["merged","done","approved"],"w":"Joined the release","d":"The reviewed change joins the release branch. Nothing is pushed to users."},
 {"t":"Freeze","i":"snowflake","match":[],"w":"","d":"Free local gate on the finished tree: full tests and benchmarks."},
 {"t":"Your checks","i":"user-check","match":[],"w":"After the free gate","d":"Your yes on the release, plus your own quick checks."},
 {"t":"Live","i":"rocket","match":["shipped"],"w":"","d":"Published to users."}]'

# A task's percent: a number, or a "40" / "40%" string. Anything else is no percent, never 0: a board
# whose tasks carry no pct used to average to 0% and hide the orchestrator's reported --pct for hours.
_OSRC_BOARD_TPCT='def tpct: if (.pct | type) == "number" then .pct elif (.pct | type) == "string" then (try (.pct | sub("%$"; "") | tonumber) catch null) else null end;'

# _osrc_hub_board_pct_says <board-file> <card-pct> -> the line `hub report --board` prints: which
# percent the page will show (same rule as _osrc_hub_apply_board).
_osrc_hub_board_pct_says() {
  jq -r --arg cp "${2:-}" "$_OSRC_BOARD_TPCT"' [.tasks[]? | objects | tpct | numbers] as $n
    | if ($n | length) > 0 then "page shows \($n | add / length | round)%: the average of the \($n | length) board task(s) with a pct"
      elif $cp != "" then "page shows \($cp)%: your reported --pct (no board task has a pct)"
      else "page shows no percent: no board task has a pct and no --pct was reported" end' "$1" 2>/dev/null
}

# _osrc_hub_apply_board <project-json> <card-json> -> project with the board's data, or unchanged.
# A task's state may be given as .status or .state. The project percent is the average of the tasks
# that have one; with none, the card's reported pct stays (pctSource says which).
_osrc_hub_apply_board() {
  jq -c --argjson card "$2" --argjson fl "$_OSRC_BOARD_FLOW" "$_OSRC_BOARD_TPCT"'
    ($card.board // null) as $b
    | if ($b | type) != "object" or ($b.tasks | type) != "array" or ($b.tasks | length) == 0 then . else
      . as $p
      | ($b.tasks | to_entries | map(select(.value | type == "object") | .key as $k | .value
          | ((.id // ("T" + (($k + 1) | tostring))) | tostring) as $tid
          | {id:$tid, short:((.short // $tid) | tostring), status:((.status // .state // "Building") | tostring),
             theme, model, issues, note}
          + (tpct as $x | if $x == null then {} else {pct:$x} end)
          + (if .plats then {plats} else {} end))) as $lanes
      | [$lanes[] | .pct | numbers] as $nums
      | if ($lanes | length) == 0 then . else
        ((if ($b.decisions | type) == "array" then $b.decisions else [] end)
          | to_entries | map(select(.value | type == "object") | .key as $k | .value
              | ((.id // ("D" + (($k + 1) | tostring))) | tostring) as $did
              | . + {id:$did, status:(if .status == "done" then "done" else "wait" end),
                     q:((.q // .short // "") | tostring), short:((.short // .q // "") | tostring),
                     weight:(if (.weight | type) == "string" and (.weight | test("^(Critical|High|Medium|Low)$")) then .weight else "High" end),
                     affects:(if (.affects | type) == "array" then .affects elif (.affects | type) == "string" then [.affects] else [] end),
                     options:(if (.options | type) == "array" then .options else [] end)})) as $bd
        | ($bd | map(.id)) as $bids
        | (if ($p.decisions | type) == "array" then $p.decisions else [] end) as $pdec
        | (if ($p.lanes | type) == "array" then $p.lanes else [] end) as $jobs
        | ($jobs | map(select(((.proof | type) == "object" and (.proof.stopped // false) == true) or (.reviewNeedsYou != null)))) as $stops
        | (if ($b.freeze | type) == "string" then $b.freeze else "" end) as $bfz
        | (if ($b.release | type) == "string" then $b.release else "" end) as $brel
        | (if ($b.releaseNote | type) == "string" then $b.releaseNote else "" end) as $brn
        | . + {lanes:$lanes, boardTracks:($lanes | length), sessionsRun:($p.sessionsTotal // ($jobs | length)),
               sessionsNow:($jobs | map(select(((.status // "") | test("^(done|merged|approved|shipped|canceled|cancelled|failed|stopped|idle)$"; "i") | not) and ((.state // "") != "idle"))) | length),
               flow:((if ($b.flow | type) == "array" and ($b.flow | length) > 0 then $b.flow else $fl end)
                     | map(if type == "string" then {t:.} elif type == "object" then . else empty end
                           | if .t == "Freeze" and ((.w // "") == "") then .w = $bfz
                             elif .t == "Live" then (if (.w // "") == "" then .w = $brel else . end) | .d = (((.d // "") | tostring) + (if $brn != "" then " " + $brn else "" end))
                             else . end)),
               decisions:($bd + ($pdec | map(select(.id as $i | $bids | index($i) | not))))}
        + (if ($nums | length) > 0 then {pct:($nums | add / length | round), pctSource:"board"} else {pctSource:"report"} end)
        + (if ($stops | length) > 0 then {proofStops:$stops} else {} end)
        + (if ($b.themes | type) == "array" and ($b.themes | length) > 0 then {themes:$b.themes} else {} end)
        + (if $brel != "" then {eta:$brel} else {} end)
        + (if $brn != "" then {etaNote:$brn} else {} end)
        + (if $bfz != "" then {freeze:$bfz} else {} end)
        + (if ($b.tagline | type) == "string" and $b.tagline != "" then {tagline:$b.tagline} else {} end)
        + (if ($b.updated | type) == "string" and $b.updated != "" then {boardUpdated:$b.updated} else {} end)
      end
    end' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

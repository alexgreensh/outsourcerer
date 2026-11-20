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

# _osrc_hub_apply_board <project-json> <card-json> -> project with the board's data, or unchanged.
_osrc_hub_apply_board() {
  jq -c --argjson card "$2" --argjson fl "$_OSRC_BOARD_FLOW" '
    ($card.board // null) as $b
    | if ($b | type) != "object" or ($b.tasks | type) != "array" or ($b.tasks | length) == 0 then . else
      . as $p
      | ($b.tasks | to_entries | map(select(.value | type == "object") | .key as $k | .value
          | ((.id // ("T" + (($k + 1) | tostring))) | tostring) as $tid
          | {id:$tid, short:((.short // $tid) | tostring), status:((.status // "Building") | tostring),
             pct:(if (.pct | type) == "number" then .pct elif (.pct | type) == "string" then (try (.pct | sub("%$";"") | tonumber) catch 0) else 0 end),
             theme, model, issues, note}
          + (if .plats then {plats} else {} end))) as $lanes
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
               pct:(($lanes | map(.pct) | add) / ($lanes | length) | round),
               flow:((if ($b.flow | type) == "array" and ($b.flow | length) > 0 then $b.flow else $fl end)
                     | map(if type == "string" then {t:.} elif type == "object" then . else empty end
                           | if .t == "Freeze" and ((.w // "") == "") then .w = $bfz
                             elif .t == "Live" then (if (.w // "") == "" then .w = $brel else . end) | .d = (((.d // "") | tostring) + (if $brn != "" then " " + $brn else "" end))
                             else . end)),
               decisions:($bd + ($pdec | map(select(.id as $i | $bids | index($i) | not))))}
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

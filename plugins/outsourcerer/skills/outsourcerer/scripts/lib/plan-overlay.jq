# plan-overlay.jq — lib/plan-probe.sh `_osrc_plan_overlay`. Input: the lane-summary rows.
# $p = cached probe answers keyed by harness id ({codex,agy,devin,droid,claude}), $now epoch,
# $lt the limit line (spent), $ct the conserve line (running low). Every row leaves with a
# checked state: a number, or words that say what is known and why. Never "not checked yet".

def num1: (. * 10 | round) / 10;
def pct: num1 | tostring;
def st($used): if $used >= $lt then "out" elif $used >= $ct then "low" else "ok" end;
def epoch: if type == "number" then (if . > 100000000000 then . / 1000 else . end | floor)
           elif type == "string" then (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) else null end;
def ago($t): ($now - $t) as $d
  | if $d < 120 then "1 min" elif $d < 7200 then "\($d / 60 | floor) min"
    elif $d < 172800 then "\($d / 3600 | floor) h" else "\($d / 86400 | floor) days" end;
def hm($t): $t | strflocaltime("%H:%M");
# renew($t) -> "today · 18:40" | "tomorrow · 09:10" | "in 4 days · Thu 19 Nov" (local), like _osrc_renew_text.
def tzoff: ($now | localtime | mktime) - $now;
def lday($t): (($t + tzoff) / 86400 | floor);
def renew($t): if ($t | type) != "number" or $t <= $now then null
  else (lday($t) - lday($now)) as $d
  | if $d == 0 then "today · " + ($t | strflocaltime("%H:%M")) elif $d == 1 then "tomorrow · " + ($t | strflocaltime("%H:%M"))
    else "in \($d) days · " + ($t | strflocaltime("%a %e %b") | gsub("  +"; " ")) end end;
def wlabel: if . == "claude5h" or . == "codex5h" then "5 hours" else "Week" end;
# The newest reading wins: a cached live probe only replaces a row that already has its own reading
# (the session log) when the probe is not older than it.
def row_age: ([.windows[]?.age_s | numbers] | min);
def probe_newer: (row_age) as $a | $a == null or ($now - ($p.codex.checked // $now)) <= $a;
def unmeasured: (.state == "unknown" or .state == "wait");
# A kept last-good probe whose refresh failed is stale: shown with the reason, never headroom.
def refresh_flag($c): if ($c.refresh_failed // "") != "" then
    . + {stale: true, note: "\(.note // "") Refresh failed (\($c.refresh_failed)); showing the last good reading."}
    | if .state == "ok" or .state == "low" then .state = "unknown" else . end else . end;
def checked($t): . + {updated: ($t | todate), checked_at: $t};

# rows: [{k, label, used, renews_at}] -> the row fields for the tightest live window.
def from_windows($ws; $why):
  ($ws | map(select(.renews_at == null or .renews_at > $now))) as $live
  | if ($live | length) == 0 then {state: "ok", left: "Renewed", renews_at: null, renews: null, used: null, window: null,
        windows: {}, note: "Every window renewed since the last reading. \($why)"}
    else ($live | max_by(.used)) as $w
      | {state: st($w.used), left: "\(100 - $w.used | pct)% left", used: $w.used, window: $w.k, renews_at: $w.renews_at,
         windows: ($live | map({(.k): {used, left: (100 - .used | num1), renews_at, label}}) | add)}
    end;

def claude_fix:
  if ($p.claude | type) != "object" then
    . + {left: "No reading", note: "Claude Code has not reported its 5-hour and weekly limits here yet. One-time fix: outsourcerer tap install."} | checked($now)
  else $p.claude as $c | . as $row
    | [["claude5h", $c.five_hour], ["claude7d", $c.seven_day]]
    | map(select((.[1] | type) == "object" and (.[1].used_percentage | type) == "number")
          | {k: .[0], label: (.[0] | wlabel), used: .[1].used_percentage, renews_at: (.[1].resets_at | epoch)}) as $ws
    | ("Last reading \(ago($c.ts)) ago (\(hm($c.ts))) from the Claude Code statusline, which reports while Claude Code runs; usage can only have risen since.") as $why
    | $row | if ($ws | length) == 0 then . + {left: "No reading", note: "The Claude Code statusline reported no limit windows. \($why)"} | checked($c.ts)
      else . + from_windows($ws; $why) | . + {note: (.note // $why)} | checked($c.ts) end
  end;

def codex_fix:
  ($p.codex // {}) as $c
  | if $c.ok == true then
      ($c.windows | to_entries | map({k: .key, label: (.key | wlabel), used: .value.used, renews_at: (.value.renews_at | epoch)})) as $ws
      | ("Checked live with codex app-server" + (if ($c.plan // "") != "" then " (plan \($c.plan))" else "" end) + "."
         + (if ($c.resets_available // 0) > 0 then " \($c.resets_available) free full resets available." else "" end)) as $why
      | . + from_windows($ws; $why) | . + {note: (.note // $why), source: "codex app-server"} | checked($c.checked // $now) | refresh_flag($c)
    elif ((.windows // {}) | length) > 0 then
      row_age as $ra
      | (.windows | to_entries | map({k: .key, label: (.key | wlabel), used: .value.used, renews_at: (.value.renews_at | epoch)})) as $ws
      | ("Live check failed (\($c.why // "codex app-server unavailable")); showing the last Codex session-log reading. Usage can only have risen since.") as $why
      | . + from_windows($ws; $why) | . + {note: (.note // $why)} | checked(if $ra != null then $now - $ra else ($c.checked // $now) end)
    else . + {state: "unknown", left: "No reading", note: "Live check failed: \($c.why // "codex app-server is not available")."} | checked($c.checked // $now)
    end;

def agy_fix:
  ($p.agy // {}) as $a
  | if $a.ok == true then
      ($a.groups | to_entries | map(.key as $gi | .value as $g | $g.windows[]
         | {k: "agy\($gi)\(.kind)", group: $g.name, kind, left, renews_at, note, disabled: (.disabled // false),
            label: "\($g.name) · \(if .kind == "5h" then "5 hours" else "week" end)"})) as $all
      | (($a.groups | map(select(.name | test("^Gemini Models$"; "i"))) | first) // {}) as $main
      | ($all | map(select(.group == $main.name and .left != null))) as $mw
      | ($all | map(select(.group != $main.name and .left != null and .kind == "week"))
         | map("\(.group): \(.left | pct)% left this week") | join("; ")) as $others
      | ($mw | map(select(.disabled != true)) | min_by(.left)) as $w
      | . + (if $w == null then {state: "unknown", left: "No reading"}
             else {state: st(100 - $w.left), left: "\($w.left | pct)% left",
                   used: (100 - $w.left | num1), window: $w.k, plan_seen: true,
                   renews_at: (if $w.left < 100 then $w.renews_at else null end)} end)
      | . + {windows: ($all | map({(.k): ({label, left: (if .left == null then null else (.left | num1) end),
                                           used: (if .left == null then null else (100 - .left | num1) end), renews_at}
                                          + (if (.note // "") != "" and .left == null then {note} else {} end))}) | add),
             models: ($main.models // null),
             note: ("Checked live from Antigravity's /usage screen (\($main.name // "Gemini Models missing"))." + (if $others != "" then " \($others)." else "" end)),
             source: "agy /usage"}
      | checked($a.checked // $now) | refresh_flag($a)
    else . + {state: "unknown", left: "No reading", note: "Antigravity's /usage screen could not be read: \($a.why // "agy is not available")."} | checked($a.checked // $now)
    end;

def devin_fix:
  ($p.devin // {}) as $d
  | if $d.ok == true and (($d.free // []) | length) > 0 then
      . + {state: "ok", left: ((if ($d.plan // "") != "" then "\($d.plan) " else "" end) + "subscription"),
           note: ("Devin " + (if ($d.plan // "") != "" then "\($d.plan) " else "" end) + "subscription (paid monthly, not free)"
            + ": \($d.free | length) models come with no per-use charge (\($d.free[0:3] | join(", "))). Other models bill per token on top."
            + " Devin Cloud runs use your plan's cloud quota, which the Devin CLI does not report: see it at app.devin.ai."),
           source: "devin models"} | checked($d.checked // $now)
    elif $d.ok == true then
      . + {state: "unknown", left: "Signed in", note: "Signed in to Devin, but `devin models` listed no free models; paid models bill per token."} | checked($d.checked // $now)
    else . + {state: "unknown", left: "No reading", note: "Devin could not be checked: \($d.why // "devin is not available")."} | checked($d.checked // $now)
    end;

def droid_fix:
  ($p.droid // {}) as $d
  | (if (.cap // "") != "" then " Your cap: \(.cap)." else " No cap set in Outsourcerer." end) as $cap
  | if $d.ok == true then
      . + {state: "ok", left: "Subscription", source: "droid doctor",
           note: ("Signed in to Factory" + (if ($d.token_until // "") != "" then " (token valid until \($d.token_until | epoch | if . then strflocaltime("%a %d %b %H:%M") else "later" end))" else "" end)
                  + ". Factory is a monthly subscription; the CLI shows no remaining balance." + $cap)} | checked($d.checked // $now)
    else . + {state: "unknown", left: "Subscription", note: ("Sign-in not confirmed: \($d.why // "droid is not available")." + $cap)} | checked($d.checked // $now)
    end;

def generic_fix:
  if .billing == "free" or .id == "local" then . + {state: "ok", left: "Free", note: "Runs on your own hardware: no meter, no bill."} | checked($now)
  else . + {left: "No usage meter", note: "\(.name) publishes no usage limit Outsourcerer can read, so runs are not gated on one."} | checked($now) end;

map(if (type == "object") | not then .
    elif .id == "codex" and ($p.codex.ok // false) == true and probe_newer then codex_fix   # the live reading names its source
    elif unmeasured then
      (if .id == "claude" then claude_fix elif .id == "codex" then codex_fix elif .id == "agy" then agy_fix
       elif .id == "devin" then devin_fix elif .id == "droid" then droid_fix else generic_fix end)
    else . end
    | if (.windows | type) == "object" then .windows |= with_entries(.value |= (if (.label // null) == null then . + {label: (.key | wlabel)} else . end)) else . end
    | if (.renews_at | type) == "number" and (.renews // null) == null then .renews = renew(.renews_at) else . end
    | if (.windows | type) == "object" then .windows |= map_values(if (.renews_at | type) == "number" and (.renews // null) == null then .renews = renew(.renews_at) else . end) else . end
    | if (.left // "") == "" or .left == "not checked yet" then .left = "No reading" else . end
    # A session-log reading keeps its own age as its checked-at time.
    | if (.checked_at | type) != "number" and row_age != null then . + {checked_at: ($now - row_age)} else . end
    # Every measured reading carries its age. Past $stale it is unknown, never headroom (an exhausted
    # one stays exhausted: stale only ever understates use). Under the low line it says so.
    | if (.used | type) == "number" then
        (if (.checked_at | type) == "number" then (($now - .checked_at) | if . < 0 then 0 else . end) else null end) as $age
        | (if $age != null then . + {age_s: $age} else . end)
        | if $age != null and $age > $stale then . + {stale: true, left: "\(.left) · checked \(ago($now - $age)) ago"}
            | if .state == "ok" or .state == "low" then .state = "unknown" else . end
          elif (100 - .used) <= $ll then . + {low: true, left: "\(.left) · LOW: stop routing here"}
          else . end
      else . end
    # "Waiting for reset" never shows without the reset time.
    | if .state == "wait" and ((.renews_at // null) == null) then .state = "unknown" else . end)

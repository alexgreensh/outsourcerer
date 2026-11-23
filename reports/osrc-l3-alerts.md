# osrc-l3-alerts — alerts people can trust

Branch: `cloud/osrc-l3-alerts`. Scope stayed inside `lib/screen.sh` and its tests/fixtures.
`lib/supervise.sh` was not touched; the two changes it still needs are under
`## Needs from other lanes`.

## What changed

`plugins/outsourcerer/skills/outsourcerer/scripts/lib/screen.sh` (605 -> 738 lines, < 1000):

- **New state `limit`.** `_osrc_scr_limit()` scans the live history region
  (`OSRC_SCR_HIST_END` when the engine has a composer box, else the last ~14 tail lines) for
  rate-limit / quota banners and runs after every engine reader when the state is
  `idle|composer|unknown` — a parked provider outranks a ready-looking composer. Two shapes
  count, both requiring limit-hit vocabulary so status warnings never match:
  - strict phrases anywhere on the line (`usage limit reached`, `you've hit your usage limit`,
    `quota reached|exceeded|exhausted`, `insufficient credits|funds|balance|quota`,
    `resource_exhausted`, `rate limit reached|exceeded|hit`, ...);
  - a warning/error prefix (`⚠ ⛔ ⎿ ! Error FATAL WARNING WARN ✖ ✗ × ⨯ ■`) plus a blocking verb
    (`reach exceed exhaust "hit your/the ..." "try again" "rate limited" "usage|rate|plan limit"
    blocked cannot can't denied throttl "too many" insufficient credit 429`).
  - Prose and tool output never match: `⏺ ❯ › >`-led lines are skipped, and a `⎿` line whose
    previous line is a `⏺ Name(` tool-call header is the command's own output (same guard as
    `_sv_api_banner`).
  - The evidence carries the banner plus the reset the lane stated, verbatim, and a numeric
    epoch when `_lane_limit_reset_secs` parses it (`resets in 1h13m1s`, `try again at 22:28`,
    `resets 3pm`, `Retrying in 42s` — retry/refresh/backoff phrasings are normalized to
    `resets` first). `approval`, `question` and `working` keep precedence over `limit`.
- **Wider busy detection for unrecognized engines** (`_osrc_scr_generic`). The old last-3-lines
  check missed healthy agents in unknown layouts — the 962-event stall storm. A second scan now
  covers rows n-12..n-4 for structural busy signals only: interrupt hints (`esc to interrupt`,
  `ctrl+c to interrupt`, `ctrl+c:`), `Verb… (detail)` rows, `Working (`, and spinner-led status
  lines (spinner glyph + a letter + `…`/`...`/`(`). Two guards keep it honest: the scan runs
  only when the last line is not already a proven prompt (it can rescue `unknown`, never
  override `idle`), and a marker counts only *below* the last `· done`/`Worked for` summary, so
  a stale busy line above a completion stays scrollback.
- **New pane-level state `dead` + `_osrc_screen_pane_dead()`.** tmux keeps a dead pane's last
  frame (remain-on-exit), so a successful capture can describe a corpse. The helper asks
  `display-message -p '#{pane_dead}'` and returns rc 0 only on a proven `1` (rc 1 alive, rc 2
  cannot tell — no tmux, old tmux, odd answer). `osrc_screen_state` prints `dead` and
  `osrc_screen_report` prints `STATE=dead` + `PANE_DEAD=1|0|?`. `analyze_text` is unchanged in
  kind: it sees text, not liveness.
- **Compatibility.** `_pane_state_classify` maps `limit`/`dead` through its `*` arm to
  `unknown` on purpose: the legacy JSON vocabulary has no "blocked on quota" value, and `idle`
  would invite a send into a lane that cannot take a turn. `review.sh` already treats any
  non-idle/working/approval state as `unknown` (never sends); `owner_state.sh` already maps
  `limit`/`failed` to `waiting`; `menu.sh`/`send.sh` treat `limit` like `idle`/`composer`
  (a send there fails verification harmlessly — no consent gate is weakened, `limit` is not a
  consent state).

## Why

The incident had three independent leaks, all rooted in the screen reader:

1. **False stalls.** A healthy busy agent whose chrome the reader did not know classified
   `unknown`; supervise's `_sv_confirm` + unchanged-hash logic turned that into
   `stalled: screen unrecognised` after ~20 s. 962 of 1,024 stalled events were this shape.
   The wider generic busy scan converts proven-busy unknown screens to `working`, which can
   never stall on a frozen hash.
2. **Invisible limits.** Rate-limit/quota screens classified as `idle`/`composer`/`unknown`,
   so `_sv_target_screen`'s plan-limit grep was the only detector and it missed whole engines.
   `limit` is now a first-class screen state with the reset in evidence; supervise already
   branches on it (`SV_K=limit`, NEXT = move work to another lane).
3. **Dead panes.** A corpse's frozen frame kept classifying (and re-emitting) forever; tmux's
   `pane_dead` flag now proves the corpse so callers can stop trusting the frame.

## Tests

New suite `tests/test_screen_alerts.sh` (registered in `tests/conformance.sh` `_ALL_SUITES`
next to `test_screen_state`): 34 assertions, exit 0. Covers every incident reproduction:

- limit banners -> `limit` + reset for cc/codex/devin (new `.ansi` fixtures derived from real
  captures), agy quota + retry-backoff (existing real `.txt` captures), and a generic engine;
  engine-guess mode lands the same verdict; reset epoch present.
- unrecognized busy screens -> `working` (interrupt hint and spinner variants); a busy marker
  above a `· done` summary stays `unknown`; a busy marker above a bare `$` prompt stays `idle`.
- negatives: prose `429 Too Many Requests`, `⎿ HTTP 429` tool output under a `⏺ Bash(` header,
  codex `⚠ weekly limit: only 2% left` warning, devin `Pro · 0% remaining (resets in 43m)`
  status — none classify `limit`.
- `pane_dead`: `1` -> `STATE=dead PANE_DEAD=1`, `0` -> normal + `PANE_DEAD=0`, unreadable ->
  normal state + `PANE_DEAD=?`.
- supervise e2e through `_sv_observe_emit` + file-backed fake tmux: busy-unknown pane emits
  nothing across polls; a genuinely unrecognized frozen screen still emits `stalled`; a frozen
  `working` screen still emits `stalled` (noise fix did not blunt real stalls); a
  working -> limit transition emits `limit` exactly once and re-observation dedupes
  (file-backed state = survives watcher restart); a vanished pane emits `failed` exactly once
  inside the dedupe window.

New fixtures under `tests/fixtures/screen/`: `cc-limit-usage.ansi`, `cx-limit-usage.ansi`,
`dv-limit-plan.ansi` (real captures + one banner line, registered as `limit` rows in
`test_screen_state.sh`'s table), and synthetic `.txt` cases `generic-limit`,
`unknown-busy-esc`, `unknown-busy-spinner`, `unknown-busy-stale`, `unknown-busy-prompt`,
`unknown-prose-limit`, `unknown-toolresult-429`.

Commands run (each `nice -n 19`, one at a time, from `plugins/outsourcerer/skills/outsourcerer/scripts/tests/`):

- `nice -n 19 bash test_screen_alerts.sh` — **exit 0** (34 passed, 0 failed)
- `nice -n 19 bash test_screen_state.sh` — **exit 0** (246 passed, 0 failed)
- `nice -n 19 bash test_pane_state.sh` — **exit 0** (14 passed, 0 failed; run because it
  exercises `_pane_state_classify`, the JSON face of the changed reader)

Not run, per the local overrides: the conformance suite, full suites, builds, installs,
Docker, benchmarks. `test_release_0175.sh` section 13 (agy quota/backoff through
`_sv_target_screen`) and `test_stall.sh`/`test_supervise*.sh` are related coverage owned by
the integration run, not executed here.

## What remains unproven

- **Pane-dead-in-live-session is detected but not yet acted on.** `_osrc_screen_pane_dead`
  and the `dead` state are proven at the `osrc_screen_state`/`report` layer, but
  `_sv_target_screen`/`_sv_observe` (other lanes' files) do not call it yet, so a remain-on-exit
  corpse inside a live session still reports whatever its frozen frame says until the
  supervise-side wiring lands (see Needs).
- **`failed` re-emission window.** The dedupe test proves one `failed` row inside the remind
  interval; the 20-minute "still unresolved" remind cycle for terminal `failed` is unchanged
  (Needs item 3), so the multi-hour repeat is expected to persist until that lands.
- **Unknown-escalation window.** `unknown` still becomes `stalled` after
  `OSRC_SUPERVISE_CONFIRM` (20 s) with no longer quiet window or not-working evidence — that
  policy lives in `lib/supervise.sh` (Needs item 2). The screen-side half of the fix (busy
  unknowns now read `working`) removes the incident's false-positive class; a *genuinely*
  unrecognized frozen screen still escalates on the old clock.
- **Limit phrase coverage is fixture-driven.** The strict list covers the engines named in the
  brief plus generic shapes; an engine whose quota screen uses novel wording will still fall to
  `unknown` (and then the longer-window policy once it lands).
- **`limit` reset epoch for clock-shaped resets** ("resets at 3pm") depends on
  `_devin_plan_quota_reset_secs`'s local-time interpretation; evidence always carries the
  verbatim phrase regardless.

## Needs from other lanes

`lib/supervise.sh` / `lib/lane_life.sh` (not owned here):

1. **Wire pane liveness into `_sv_observe`.** After `cap="$(_osrc_screen_capture "$id")"`,
   call `_osrc_screen_pane_dead "$id"` (new in `lib/screen.sh`; rc 0 = proven dead). On rc 0,
   treat the target like the gone path but terminal: `SV_K=failed`,
   `SV_D="pane process dead; last frame: <evidence>"`, `SV_DROP=1`, `SV_H="dead:$h"` — reported
   once, never re-derived from the frozen frame's state. This is the only way a
   remain-on-exit corpse stops emitting `working`/`idle`/`stalled` forever.
2. **Unknown escalation needs the longer window + not-working evidence.** In the `unknown` arm
   of `_sv_observe` (currently `SV_K=stalled` after `_sv_confirm` at `OSRC_SUPERVISE_CONFIRM`,
   20 s), require a separate, longer, configurable quiet window — e.g.
   `OSRC_SUPERVISE_UNKNOWN_SECS` (suggest default 300) measured on `SVS_CHANGED` — *and*
   evidence the process is not working: `_osrc_screen_pane_dead "$id"` != proven-alive, or the
   pane hash unchanged for the whole window. Until then `unknown` should keep reporting
   `unknown`-flavored evidence, not `stalled`.
3. **Terminal `failed` must not re-remind.** `_sv_emit`'s remind cycle
   (`_sv_remind_secs` -> 1200 s for non-prompt kinds) re-logs "still unresolved" for
   `SV_K=failed`/`SV_H=gone` every 20 minutes for as long as the owner record exists — the
   340-event dead-pane leak. Make terminal kinds (`failed`, `done`) non-reminding (log once,
   ever, per `SV_H`), or drop the owner record when `SV_DROP=1` regardless of scope, matching
   what `_sv_main` already does for non-explicit scopes.

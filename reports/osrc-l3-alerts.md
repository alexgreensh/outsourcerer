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

## Round 2

Branch `cloud/osrc-l3-r2b` (from `cloud/osrc-l3-alerts` @ `9d43a90`). Files: `lib/screen.sh`
(740 -> 800 lines), `tests/test_screen_alerts.sh` (rewritten), 16 new fixtures under
`tests/fixtures/screen/`, one expectation in `tests/test_pane_state.sh`. `lib/supervise.sh` is
untouched; what it must change is listed under **Needs from other lanes (round 2)** below.

### What changed and why (by review finding)

- **P1 older spinner hides a newer refusal.** `_osrc_scr_set` now records the row that proved a
  state (`OSRC_SCR_AT`). In `_osrc_screen_analyze_text`, the limit reader also runs on `working`,
  and the refusal wins only when its row is newer than the busy row. A live approval or question
  keeps precedence, and so does a newer spinner.
- **P1 rate limit retried as an API error (screen side).** `⎿ API Error: 429 Too Many Requests`
  now reads `limit` (fixture `cc-limit-429.txt`). The retry itself happens in `_sv_target_screen`,
  which checks API errors before limits, so the fix is in the Needs list below.
- **P1 dead pane read as working; unknown stalls after 20s; failed/limit re-logged every 20 min.**
  These are emission bugs in `supervise.sh`. The screen side now provides `osrc_screen_alert
  <pane> [engine]`, which prints `<state> TAB <new|seen> TAB <evidence>`:
  - It checks liveness first: if capture fails or `#{pane_dead}`=1, the state is `failed`, and the
    evidence quotes the frozen frame without trusting it.
  - It keeps three separate states: `working`; `stalled` (a recognized busy frame unchanged for
    `OSRC_SCREEN_STALL_SECS`, default 900); and `unknown`. An unknown screen becomes `stalled`
    only after `OSRC_SCREEN_UNKNOWN_SECS` (default 600) of quiet **and** independent evidence:
    the pane's process tree (`#{pane_pid}` plus its descendants, read with `ps -A -o
    pid=,ppid=,time=`, which parses on both Linux and macOS) used under `OSRC_SCREEN_UNKNOWN_CPU`
    (default 2) CPU seconds over that window. When `ps` cannot be read (for example on Git Bash),
    twice the window stands in for that evidence.
  - `new` means the state differs from the last one recorded in
    `$OSRC_HOME/screen-alerts/<pane>`. Because that record is on disk, a restarted watcher does
    not report the same state again. Nothing is re-announced on a timer.
- **P2 errors and prose read as quota.** A row now counts only when it starts like a banner (a
  warning glyph, `⎿`, `Error`/`FATAL`/`WARN`, or the refusal phrase itself) **and** contains
  quota-refusal wording (`limit reached/exceeded/hit`, `rate limited`, `quota exceeded`, `429`,
  `too many requests`, `insufficient credits`, ...). Generic verbs (`denied`, `cannot`,
  `blocked`) no longer count. An indented row belongs to its block: when the block opens with a
  tool call (`⏺ Name(`, `• Ran`, `✓ cmd`), the row is tool output and is skipped.
- **P2 recovered lane stays limited.** The scan stops at the newest turn boundary (a user prompt
  row, or a `Worked for` / `· done` summary). A recognized composer with empty history now
  returns no match; before, `HIST_END=-1` fell through to scanning the composer and footer.
- **P2 busy meaning depends on pane height.** The generic reader now uses one structural matcher
  over the live tail (rows below the last done summary): interrupt hints, `Working (`, a braille
  spinner followed by a word, or another spinner glyph followed by a `…`/`...`/`(` status. Bare
  words (`Thinking`, `Running`) and loose `… (` prose no longer count. A bare prompt on the last
  row still outranks a busy row above the last three rows (the earlier behaviour).
  `test_pane_state.sh` case 2b expected bare `Running tests` to read as working. That case now
  uses `⠋ Running tests`, and the bare word must not read as working, because the send verifier
  accepts `working` as proof that a send landed.
- **P2 reset parsing.** The reset phrase is captured whole: the clock, am/pm and a `UTC`/`GMT`
  zone. Only trailing punctuation is stripped. Before, `Resets 22:28` became `22:2` (this reproduced
  on Linux too) and `09:00 UTC` lost its zone.
- **P2 frozen countdown.** `_osrc_screen_analyze_text` no longer invents an epoch for a relative
  reset ("try again in 2h"); it reports only the displayed duration. `osrc_screen_alert` anchors
  the epoch to the first time that exact banner was seen. If the banner text changes (a ticking
  countdown), it re-anchors to now.
- **P2 `set -e` caller killed.** `osrc_screen_report` now captures the pane-dead status with `||`.
- **P3** The final commit subject starts with `READY:`.

### Tests (all run on Linux, bash 5, niced; exit codes as observed)

- `nice -n 19 bash tests/test_screen_alerts.sh`: **exit 0**, 48 passed. Against the base
  `screen.sh` from `9d43a90` (with the load guard pointed at a function that exists there), 30
  of 48 failed. That covers every finding above, and both the `22:2` and the `set -e` failures
  reproduce. Sections: refusals for Claude, Codex, Devin, Antigravity and generic screens, with
  exact reset phrases and a UTC epoch checked under `TZ=XYZ5`; non-refusals (permission error,
  Codex prose, Claude and Codex multiline tool output, a recovered turn, an empty-history
  composer); busy row vs refusal; one busy matcher at every height; liveness under `set -e`;
  alert sequences from a fresh watcher per call, including past the 20-minute reminder interval.
  - Incident 1: an unrecognized healthy pane reads unknown at 0s, 25s and 700s while CPU moves.
  - Both sides of the window with flat CPU: unknown at 599s, stalled (new) at 600s, then seen at
    601s and at +20 min. The configurable window (60s) and the unreadable-CPU fallback (1199
    vs 1200) are tested too.
  - Deliverable 4 (a real stall still fires): a frozen `cx-working` frame reads working at 899s
    and stalled at 900s.
  - Incident 2: a dead pane with a readable working frame reports failed once, then seen at
    +20 min and +2h. A vanished pane does the same.
  - Incident 3: working, then limit (new), then seen at +20 min and +2h; after recovery, a new
    limit is new again. The Claude 429 banner reads limit. A frozen "2h" countdown keeps one
    deadline.
- `nice -n 19 bash tests/test_screen_state.sh`: **exit 0** (246 passed)
- `nice -n 19 bash tests/test_pane_state.sh`: **exit 0** (15 passed)
- Suites that read screens, each **exit 0**: test_approver_tick (31), test_managed_send (12),
  test_session_send_verify (49), test_session_control (16), test_stall (58), test_supervise (99),
  test_supervise_dedupe (47), test_supervise_lifecycle (43), test_limit_gate (124).
- `nice -n 19 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`: **exit 1**,
  242 passed, 6 failed, 1 skipped (live probes), 872s, run as root (uid 0) in a Linux container.
  None of the 6 is caused by this change; each fails the same way with the base `9d43a90`
  `screen.sh` restored:
  - `test_harness_isolation`, `test_vocab_hygiene`, `test_supervise_pgroup_kill` and
    `test_parity_insource_refresh` each exit 1 on the base. They check read-only files, process
    groups and MCP inheritance, which likely behave differently for root inside this container.
  - `test_conformance_suite_timeout` ("watchdog timer survived the gate's return on the TERM
    path") failed on 3 of 4 base runs, so it is flaky here. It does not touch the screen code.
  - `test_sealed_fixes` is registered with the runner, but `tests/test_sealed_fixes.sh` does not
    exist on this branch (rc 127).

### What remains unproven

- Not run on macOS bash 3.2 or Git Bash. The code uses only `[[ =~ ]]` with regexes stored in
  variables, `case` globs and POSIX awk; there is no `mapfile`, `${,,}` or associative array.
  The macOS `ps` time format (`m:ss.cc`) is parsed by the same awk, but only the Linux
  `hh:mm:ss` shape was exercised (through a fake `ps`).
- The CPU evidence is a heuristic. A healthy agent can wait on a long model call with a frozen,
  unrecognized screen and almost no CPU, and it would be called stalled after 10 minutes. That
  is still about 30 times rarer than the old 20-second rule, and `OSRC_SCREEN_UNKNOWN_SECS`
  raises the window.
- Supervise does not call `osrc_screen_alert` yet, so the noise fix reaches users only once the
  changes below land.

### Needs from other lanes (round 2) — `lib/supervise.sh`, owner osrc-l1-r2

These replace round 1's list.

1. **Liveness before the approver and screen reader** (`_sv_observe`, at the top of the
   `elif have tmux && tmux has-session -t "=$id"` branch, before `osrc_approver_tick`):
   `if _osrc_screen_pane_dead "$id"; then SV_K=failed; SV_D="pane process exited (remain-on-exit)"; SV_H=dead; SV_DROP=1; _sv_state_write "$id"; return 0; fi`
   Test: a fake tmux answering `has-session` with 0, `#{pane_dead}` with 1, and a capture of
   `fixtures/screen/cx-working.ansi` must emit one `failed` and no `working`/`stalled`.
2. **No 20-second stall for unknown** (`_sv_observe`, the `unknown)` arm, around supervise.sh:395):
   replace `SV_K=stalled; SV_D="screen unrecognised and unchanged for ..."` with
   `out="$(osrc_screen_alert "$id" "$(_osrc_screen_engine_of "$id")")"; if [ "${out%%$'\t'*}" = stalled ]; then SV_K=stalled; SV_D="${out##*$'\t'}"; else SV_PEND=1; fi; SV_OUT=1`
   and keep `_sv_fixture_drop` only on the stalled path. Delete the base branch's test that
   expects a stall after 1s with `OSRC_SUPERVISE_CONFIRM=0`.
3. **A confirmed limit is never retried as an API error** (`_sv_target_screen`, directly after
   `case "$st" in approval|working) ...` at supervise.sh:165): add
   `[ "$st" = limit ] && { printf 'limit\n%s\n' "$ev"; return 0; }`
   Test: `fixtures/screen/cc-limit-429.txt` with `OSRC_SUPERVISE_AUTORETRY=1` emits `limit`, and
   no `session send` is invoked (stub `SCRIPT_PATH`).
4. **Parked and terminal states are not re-logged** (`_sv_observe` limit arm, supervise.sh:337):
   set `SV_H=limit`, so a ticking countdown is one incident. Then in `_sv_emit`, before the
   remind check, add:
   `case "$SV_K" in failed|limit) [ "$SVS_LK" = "$SV_K:$SV_H" ] && return 0 ;; esac`
   The key lives in `lanes/state/<id>`, so it survives a watcher restart. The working arm
   already resets `SVS_LK=-` on recovery, so the next limit is a new incident. Test: emit at T,
   then from a fresh process at T+1300s and T+7200s; exactly one row each for `limit` and for an
   explicitly watched vanished pane's `failed`.

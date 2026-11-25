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

## Round 3

Base `cloud/osrc-l3-r2b` at `a4944f2` (confirmed with `git log --oneline -3`). Branch `cloud/osrc-l3-r3`.
Files: `lib/screen.sh`, `tests/test_screen_alerts.sh`, `tests/test_screen_state.sh`, two new fixtures,
this report. The round-2 handoff markers (`osrc-l3-r2b.READY`/`.RESULT`) are deleted.

### What changed and why (by review finding)

- **P1 1, a finished lane read `limit`.** `_osrc_scr_limit` now requires the refusal to be the
  newest row of the turn. The newest-first scan stops (no limit) at any assistant or tool row
  (`⏺ • ● ✦ ✓ ✔`), a shell prompt (a row ending `$`/`%`/`#`, or `$ cmd`) and the Devin prompt `❭ `
  (P3), as well as the old user-prompt and `Worked for`/`· done` boundaries. In the block walk-up, a
  space-indented row under prose is a wrapped reply line, not a banner. Only a `⎿` row may sit under
  prose, because Claude prints its own errors that way (`cc-limit-429.txt` still reads `limit`).
  A finished lane now reads `idle`, so supervise's done-contract check runs again.
- **P2 2, bullets with parentheses read `working`.** `(` was dropped from the non-braille spinner
  arm; that arm now needs `…` or `...`.
- **P2 3 and 4, the unwired alert layer.** `osrc_screen_alert`, `_osrc_scr_cpu`, `_osrc_scr_num`,
  the `screen-alerts/<pane>` state files, the three `OSRC_SCREEN_*` settings and
  `OSRC_SCR_LIMIT_SECS` are deleted. I did not wire them into supervise: `lib/supervise.sh` is
  another lane's file, and supervise stays the only owner of alert state. The negative-CPU stall
  (P2 3), the stale `screen-alerts` file, the undocumented settings, the doubled clock read in the
  alert and the "capture failure means pane gone" issue all go with the deleted code. Their tests
  (old section 6 and the fake `ps`) are deleted as well. No regression test can fail on code that
  no longer exists. The CPU idea is carried forward under Needs.
- **P2 5, an expired limit never cleared.** The newest-row rule covers this case: a refusal
  followed by output and a prompt reads `idle`. Nothing anchors an epoch any more, because the
  alert layer is gone.
- **P2 6, a Claude banner was missed.** `[0-9]+-hour|opus|sonnet` was added to the limit-kind
  alternation. The new fixture `cc-limit-5hour.ansi` is the real `cc-limit-usage.ansi` capture with
  its banner replaced by the reported string `⎿  5-hour limit reached ∙ resets 3pm`.
- **P3 Devin turn boundary.** `❭ ` now ends the scan. The fixture `dv-limit-then-continue.ansi` is the
  real `dv-limit-plan.ansi` capture plus `❭ continue please` and a reply.
- **P3 mid-line spinners.** The busy matcher allows one leading `[`, so `[⠋] Compiling crate 12/40`
  reads `working` again.
- **P3 cost.** A `case` glob over the refusal words now runs before any `tr` fork, and the main
  scan trims rows with parameter expansion instead of a subshell. Here are 10 analyses per fixture
  on Linux, measured with the Bash tool:
  - `cx-working`: 200 ms on `ea34fe0`, 268 ms now.
  - `cx-idle`: 246 ms on `ea34fe0`, 342 ms now.
  - `generic-limit` with both fixtures together: 1628 ms on r2b, 1413 ms now.

  A screen that does read `limit` still pays for the reset-phrase parse (grep, sed and
  `_lane_limit_reset_secs`). That cost falls only on parked lanes.

### Not fixed

- **Epoch can flap by one second.** `_lane_limit_reset_secs`, in `outsourcerer.sh`, which is not
  my file, reads the clock and the reader adds `date +%s` again. The test still tolerates one
  second.

### Tests (Linux, bash 5, niced)

Each new case was run against the r2b `lib/screen.sh`, swapped in temporarily: all 10 FAIL there
and pass here.
- `bash tests/test_screen_alerts.sh`: rc=0, 45 passed, 0 failed. On base, 35 passed and 10 failed.
- `bash tests/test_screen_state.sh`: rc=0, 252 passed, 0 failed. It has two new table rows, one for
  each new fixture.
- `bash tests/test_pane_state.sh`: rc=0, 15 passed.
- `bash tests/test_session_send_verify.sh`: rc=0, 49 passed.
- `bash tests/test_stall.sh`: rc=0, 58 passed. `test_supervise.sh`: rc=0, 99 passed.
  `test_done_contract.sh`: rc=0, 53 passed. `test_pr10_falsestall_before_quota.sh`: rc=0, 7 passed.
  `test_managed_send.sh`: rc=0, 12 passed.
- `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`: rc=1. It reported
  242 passed, 6 failed and 1 skipped (live). These 6 suites fail:
  - `test_harness_isolation`
  - `test_vocab_hygiene`
  - `test_supervise_pgroup_kill`
  - `test_parity_insource_refresh`
  - `test_conformance_suite_timeout`
  - `test_sealed_fixes`

  Each one also fails with rc=1 on an untouched `a4944f2` worktree in this container. The container
  runs as uid 0, so the read-only and permission probes succeed when they are meant to be refused.
  None of these suites touch `lib/screen.sh`.

### What remains unproven

- Not run on macOS bash 3.2 or Git Bash. The new code uses only `case` globs, `${var#pattern}`
  trims and the existing `[[ =~ ]]`-with-variable form.
- **Shell-prompt boundary.** A row ending `$`, `%` or `#` ends the limit scan. An unknown TUI whose
  refusal is followed by a status row ending in `%`, such as `ctx 12%`, would read its underlying
  state instead of `limit`. That direction fails safe: the lane is never parked.
- `⎿ ... limit` under a prose `⏺` still counts as a refusal, since that is how Claude prints its own
  errors. This rests on `cc-limit-429.txt`, an invented fixture, not a real capture.

### Needs from other lanes (round 3), `lib/supervise.sh` (owner osrc-l1)

Round 2's Needs items 2 and 4 pointed at `osrc_screen_alert`, which is deleted. Replace them with
the following.

1. **Unknown escalation.** In `_sv_observe`'s `unknown)` arm, wait for a longer configurable window
   (`OSRC_SUPERVISE_UNKNOWN_SECS`) before calling the lane stalled. If you use process-tree CPU as
   evidence, a negative delta (a child exited) must count as activity and re-baseline the sample.
2. **Failed and limit dedupe.** Keep the `SVS_LK` dedupe from round 2's item 4 in supervise's own
   state file. Clear it when a lane name is reused.
3. Round 2's items 1 and 3 stand unchanged.

## Round 4

Base `cloud/osrc-l3-r3` at `11295d4` (confirmed with `git log --oneline -3`). Branch `cloud/osrc-l3-r4`.
Files: `lib/screen.sh`, `tests/test_screen_alerts.sh`, two fixtures deleted, this report. The
round-3 markers (`osrc-l3-r3.READY`/`.RESULT`) are deleted.

### Design change (instead of a fourth round of patches)

Three rounds each added a text guard and each review found a new false reading. Round 4 changes
the rule:

- **`limit` comes only from the engine's own banner, matched as a whole row, in the bottom status
  region.** The region is the last history row above the composer, or the row above it when that
  last row is a plain trailer (agy's `Error ID: ...`, Claude's `/upgrade ...`). With no
  recognized composer, `_osrc_scr_bottom` gives the row above the last rule or bare input prompt
  in the last six rows, or else the last row. The banner must start at column 0
  (`⚠ You've hit your usage limit. Try again at 22:28.`), or, for Claude, be a `⎿` row that hangs
  directly under the user's prompt or the turn summary, which puts it below the last tool or
  bullet block. The row, lowercased, must match `_OSRC_SCR_LIMIT_RE` from start to end: an
  optional glyph, an optional `Error:`, one closed set of headlines, and an optional
  reset/upgrade clause. The headlines are taken from the banners in `fixtures/screen/*limit*` and
  `fixtures/supervise/agy-*`, plus the six Claude wordings the round-3 review verified. Text
  anywhere else never yields `limit`. That covers tool output, todo rows, bullets, wrapped prose,
  quoted errors, line numbers and counts.
- **`working` for unknown engines comes only from a busy indicator in that same region.** One
  helper, `_osrc_scr_busy_row`, accepts an interrupt hint in a status shape (`(`… or `· `…), a
  row starting `Working (`, a braille spinner followed by a word, or a spinner frame followed by a
  word and `…`/`...`. `●` is no longer a spinner frame. The per-engine readers (cc, codex, devin,
  agy) already read busy from their own live region and are unchanged.
- **Anything else reads `unknown`**, as before. `unknown` raises no alert by itself.
- **Deleted:** `_OSRC_SCR_LIMIT_HEAD`, `_OSRC_SCR_LIMIT_WORDS`, `_OSRC_SCR_TOOL_HDR`, the
  14-row newest-first scan with its stop list, the block walk-up, the 12-row generic busy scan
  that forked once per row, the stale `OSRC_SCR_LIMIT_SECS` comment, a dead
  `case ... in "") ;; esac` line in the Devin reader, a no-op `sed` on the reset phrase, the
  unused fixture `generic-unrecognized.txt`, and `cc-limit-429.txt`, which is now an inline
  negative case.

Net lines: `lib/screen.sh` +61 −81. Code and tests together: +98 −104. Including markers and
the report, the total goes up only because of this report section.

### Review findings

| # | Finding | Now |
|---|---|---|
| P1 1 | todo row under the spinner read `limit` | `working` (3 todo variants tested) |
| P2 2 | `● Bash(` / MCP tool output read `limit` | not `limit`: `⎿` under anything but a prompt or summary is not a banner (3 cases) |
| P2 3 | `429` line number / count read `limit` | not `limit`: no headline matches (2 cases) |
| P2 4 | `● Done. See the notes...` above `$` read `working` | `idle` |
| P3 | refusal followed by 4 output rows, no prompt, read `limit` | not `limit`: the banner must be the last row or sit above one trailer |
| P3 | prose `press esc to interrupt` 6 rows up read `working` | not `working`: the hint needs a status shape, inside the region |
| P3 | fork per row in the generic scan | gone: inline trims, and at most 2 `tr` forks, only on rows containing `limit`/`quota` |
| P3 | stale `OSRC_SCR_LIMIT_SECS` comment | deleted |
| P3 | r3 markers at the repo root | deleted |

**Behaviour change, on purpose:** Claude's `⎿  API Error: 429 ...` under a prose bullet no longer
reads `limit`. It was an invented fixture, not a real capture, and it hangs inside a bullet
block. supervise's own `_sv_api_banner` (`lib/supervise.sh`) already reads that row as
`api-error`. There is no separate `refused` state in `lib/screen.sh`. Provider refusals with a
limit banner are `limit`. The API/login error banner is supervise's `failed api-error`, which I
did not touch (not my file).

**Not changed:** bare `Thinking…` / `Running…` still read `unknown` for unknown engines (round 3's
decision, P3). A spinner-led row reads `working`. Needs item 1 (longer unknown window in
supervise) is still the fix for unknown layouts. `dead` is still only groundwork.

### Tests (Linux, bash 5, niced)

The 12 new cases (4 review findings, expanded, plus 2 P3 cases) were first run against the r3
`lib/screen.sh`: `test_screen_alerts.sh` gave 49 passed, 12 failed, and every failure was a new
case. After the change:


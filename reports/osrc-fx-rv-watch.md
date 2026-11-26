# osrc-fx-rv-watch: release-review fixes for status, the watcher, supervise and Mission Control

Base: `cloud/osrc-int` at `80575c4`. Work branch: `cloud/osrc-fx-rv-watch`. Each finding is its own
commit, and each commit was pushed (F25 has a follow-up commit). All regression tests are in one new
suite, `tests/test_rv_watch.sh`, registered in `tests/conformance.sh` (`_ALL_SUITES`). The suite
sources the engine against scratch homes, uses a local bare git repo as the remote and a fake clock,
and never touches the network or live state.

"Fails before" means I ran the new test with only that finding's code change reverted (`git stash` of
the touched lib file) and saw FAIL. "Passes after" means the same test passed with the change.

## Findings

### F4 (P1): `status` blanked the progress column of every running job
- **Mechanism:** `[ "$st" = running ] && prog="$(_osrc_disk_paused_note ...)" && st=paused` assigns
  `prog` the note's empty output even when the note returns 1 (the job is not paused).
- **Fix:** `outsourcerer.sh` `_status_line`: `if [ "$st" = running ] && _w="$(_osrc_disk_paused_note "$id")"; then prog="$_w"; st=paused; fi`
  (`_w` is already a local there). The line count of `outsourcerer.sh` does not change.
- **Test:** a running job (a real `sleep` pid) with `progress` = "reading the parser". Before:
  `... running 0s example-model —` with an empty progress column, FAIL. After: PASS.

### F17 (P1): a READY tip whose commit touches many files was missed
- **Mechanism:** `printf '%s\n' "$names" | grep -qxE ...` under `pipefail`. `grep -q` exits on the
  early-sorting `<id>.READY` line, `printf` gets SIGPIPE, the pipeline returns 141 and the match reads
  as a miss. The head never moves again, so the lane goes from `live` to `stalled`.
- **Fix:** `lib/remote.sh` `_osrc_lane_poll`: the three matches (names against the marker, names
  against READY/RESULT, tree against READY and RESULT) now read here-strings.
- **Test:** the tip commit adds 20,000 files under `zz/` plus `big1.READY`. Before:
  `head_ready=false`, no event, FAIL (reproduced on Linux bash 5). After: `head_ready=true` and
  `EVENT done big1 ... READY`, PASS.

### F21: every supervise received every other session's card nag
- **Mechanism:** card events have target `card`, and every waiter's target set held the literal
  `card`, so `_sv_read_range` matched them on target for every owner.
- **Fix:** `lib/supervise.sh`: a small `_sv_target_set` builds the set (lanes plus `supervise`, no
  `card`). Card events reach only their owner, which `_sv_read_range` already matches by `owner`.
  `--all` still sees everything, as before.
- **Test:** append a card event owned by `sess-a`, then read as `sess-b` with its target set. B gets
  nothing and A gets the card row: PASS. On base, the same read with the old set
  (`lane-b supervise card`) gave B the `card` row. I checked that by hand. The new test calls
  `_sv_target_set`, which the base does not have, so the base check is the manual one.

### F22: blocked lanes were all described as "waiting for approval"
- **Mechanism:** `dtext` hard-coded the blocked wording, whatever the reason.
- **Fix:** `lib/hub-truth.sh`: `dwhy` classifies each blocked lane (question, paused, limit,
  unverified, approval, otherwise blocked), and `dcount` carries the per-reason counts as `.why`.
  `dmerge` sums them. `dtext` words the summary per reason ("1 paused (low disk), 1 at a usage
  limit, 1 waiting for an answer") and the next step ("Unblock X, Y: paused (low disk), at a usage
  limit"). A disk-paused lane is matched by status `Paused` or a note starting "Paused" (hub.sh
  sets both) before `state == limit`, because a disk pause also reads as lane state `limit`. A
  derived object without `.why` falls back to "N blocked".
- **Test:** three lanes (disk-paused, limit, question). Before: "3 waiting for approval", FAIL.
  After: each reason is worded, PASS. A plain approval lane still reads "waiting for approval" (PASS
  both before and after).

### F23: "session <ref> is live" was never checked, and the line fired only once
- **Fix:** `lib/remote.sh`: the wording is now "the launch reported session <ref>". The event repeats
  every stall interval (`_osrc_ev_due ... neverstarted "$stall"`). The no-session "never started"
  failure still fires once.
- **Test:** a lane with `session_ref`, no push. At +50 there is one stalled row with the new wording.
  At +60 there is none. At +145 (past the 90-unit stall interval) it repeats. Before: the old
  wording, and no repeat, FAIL. After: PASS. `test_fx_mc2.sh` pinned the old wording, so I updated
  its regex and label only.

### F24: an unreadable lane record was silent
- **Fix:** `lib/remote.sh`: `_osrc_remote_rec_or_say` replaces both `_osrc_remote_rec || continue`
  sites in `osrc_remote_events`. It emits `failed <id> lane record unreadable: <file>` with
  `NEXT jq . <file>` once per renotify window. `osrc_remote_state` now prints `failed` for such a
  lane, not an empty string.
- **Test:** a lane JSON that does not parse. Before: no event and an empty state, FAIL. After: one
  event, none 10 units later, a repeat after the renotify window, and state `failed`, PASS.

### F25: READY plus a failing RESULT was queued for review
- **Fix:** `lib/remote.sh` `_osrc_lane_poll`: on a READY head whose tip file list or tree names
  `<id>.RESULT`, read line 2 (`git show head:<id>.RESULT`, or the gh raw contents API). A non-zero
  `rc=` clears READY and records `.result_rc`. `osrc_remote_state` is `failed`, and
  `osrc_remote_events` emits `failed <id> READY <sha> ..., but its <id>.RESULT reports rc=N: not
  queued for review` once per head. The RESULT is read only when it is listed, so a plain READY makes
  no extra gh call. `test_remote_review.sh` pins that ("no contents calls"), and this is why F25 has
  a follow-up commit.
- **Test:** lane `rcfail` pushes READY, then RESULT with `rc=2`. Lane `rcok` does the same with
  `rc=0`. Before: `EVENT done rcfail ... (queued for review)`, FAIL. After: `rcfail` is failed with
  no review queued, and `rcok` is still READY for review, PASS.

### F26: supervise --loop exited silently when the loop marker could not be written
- **Fix:** `lib/supervise.sh`: `|| { _sv_fail "cannot write the loop marker" "$rearm"; return 2; }`.
- **Test:** a file stands where the session's supervise directory goes. Before: only a mkdir error
  and rc 2, FAIL. After: `EVENT failed supervise ... cannot write the loop marker` and rc 2, PASS.

### F27: a slow export lost its single-flight lock to age
- **Fix:** `lib/hub-truth.sh` `_osrc_hub_single_flight`: the leader runs a background beat that
  touches the lock every `stale/3+1` s. The beat runs only while the lock still records the leader
  and the leader's pid is alive. Its stdio goes to /dev/null, so a `$(...)` caller never waits on
  it. It is killed when the export ends. Age-based takeover is unchanged, so a dead or SIGKILLed
  leader, or one whose pid was reused, still loses the lock after `OSRC_HUB_EXPORT_STALE` without a
  beat. I chose the refresh over "takeover only when the pid is dead" because a reused pid would
  otherwise hold the lock forever.
- **Test:** `OSRC_HUB_EXPORT_STALE=2`, a 6 s export, and a follower that arrives 1 s later. Before:
  `runs=2`, FAIL. After: `runs=1`, and the follower prints the leader's result, PASS.

### F28 (PLAUSIBLE, confirmed): a hub for the same home spelled differently was "not ours"
- **Confirmed:** with a hub argv of `--osrc-home=/t/real`, `_osrc_mc_hub_ours` returned 0 for
  `OSRC_HOME=/t/real`, 1 for `/t/real/` and 1 for a symlink `/t/link` pointing to it. The engine
  does not normalize `OSRC_HOME`.
- **Fix:** `lib/mc_alive.sh`: compare the strings first, then the `pwd -P` of both directories.
- **Test:** the trailing-slash home and the symlinked home now own the hub, and a different home
  still does not. Before: 2 FAIL. After: 3 PASS.

### F29 (PLAUSIBLE, confirmed): a slow hub was killed after one 3 s probe
- **Confirmed:** `cmd_hub_mc` probes with `curl -m 3`. On no answer, `_osrc_mc_hub_reuse ""` stopped
  any live hub of ours, with no retry.
- **Fix:** `lib/mc_alive.sh` `_osrc_mc_hub_reuse`: one more probe of the live hub's recorded port,
  with `OSRC_MC_PROBE_RETRY_SECS` (default 10). If it answers (and is not on older code), its URL is
  printed and rc is 0. `lib/hub.sh` `cmd_hub_mc` takes that URL. A hub that still does not answer is
  stopped as before.
- **Test:** a fake hub process (`hub_server.py --osrc-home=<home>`) and a fake `curl` that answers
  200 only when given a 5 s or longer timeout. Before: "did not answer; restarting it" and the
  process killed, FAIL. After: the process is alive and the URL is returned, PASS.

### F30: relaunch ignored the MCP mode the session started with
- **Fix:** `lib/leanlaunch.sh` adds `_session_mcp_mode`. It returns lean or full from the
  environment: `OSRC_LEAN_LAUNCH=1` means lean, `OSRC_CLAUDE_USER_CONFIG=1` or
  `OSRC_SESSION_MCP=full` means full. It also adds `_session_mcp_restore`.
  `_session_registry_append` (`outsourcerer.sh`, same line count) records `mcp_mode` on cc/claude
  start events. `_session_record` (`lib/done.sh`) returns it as field 6. `_osrc_perm_restore_profile`
  (`lib/perm.sh`), which every relaunch and effort change already calls, now restores it as well, and
  `_session_relaunch_cc` reads `_session_mcp_mode`. Older records without the field keep today's
  behaviour, which is to read the environment.
- **Test:** a session started with `OSRC_CLAUDE_USER_CONFIG=1`, relaunched from a plain shell.
  Before: `--strict-mcp-config ... {"mcpServers":{}}`, FAIL. After: no strict flag, PASS. Also, a
  lean session relaunched from a full shell stays lean (PASS).

### F31: lean MCP by default (behaviour change)
- **Fix:** `lib/leanlaunch.sh` `_session_cc_mcp_flags` prints one stderr line at start:
  `[outsourcerer] MCP servers: none (lean default). A brief that needs a connector: --with mcp=<names>, or OSRC_SESSION_MCP=full`.
  The other modes print "full (your configured set)", "lean, only those declared with --with mcp="
  or "lean, from OSRC_LEAN_MCP_CONFIG".
- **Test:** the lean default and full mode lines. Before: no line, FAIL. After: PASS.
- **Proposed release note (0.18.0, Changed):** "**Interactive Claude lanes start with no MCP
  servers.** Each full set cost about 0.85 GB per lane. Load the ones a brief needs with `--with
  mcp=<names>`, or all of yours with `OSRC_SESSION_MCP=full`. Session start prints which mode it
  used, and a relaunch keeps it."

## Test runs

New suite: `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_rv_watch.sh` gave
**passed: 22 failed: 0**, rc 0, on the final head.

Suites touching the changed files, each run once after its last related change (niced, from the
scripts dir):

| suite | result |
|---|---|
| test_disk_r2.sh (F4, `_status_line`) | 21 pass, 1 fail. **The same failure is on the base** (see Needs) |
| test_remote_review.sh (F17, F23-F25) | 112 passed, 0 failed, rc 0 |
| test_fx_mc2.sh (F23 wording) | rc 0 (it also ran clean after F25, before the F25 follow-up) |
| test_watcher.sh (remote.sh) | rc 0 |
| test_card_who.sh (F21) | 10 passed, 0 failed |
| test_hub_truth.sh (F22, F27) | 29 pass, 0 fail |
| test_hub_mc3.sh (F22) | rc 0 |
| test_mc_alive.sh (F28, F29) | 59 passed, 0 failed |
| test_hub_home.sh (F29, `cmd_hub_mc`) | 92 pass, 0 fail |
| test_perm_profiles.sh, test_relaunch_bookkeeping.sh, test_session_effort.sh, test_session_registry_end.sh (F30) | rc 0 each, 0 FAIL |
| test_lean_launch.py (F30, F31) | 7 tests OK |

Conformance: see `## Conformance` below.

## What remains unproven
- The F25 gh transport branch (raw contents API) is not exercised by a test. The git transport is
  tested, and the gh suite proves no contents call is made when no RESULT is listed.
- F29 was tested with a fake curl, not a real loaded hub server.
- All runs were on Linux bash 5. Every construct I added is in bash 3.2 (here-strings, `pwd -P`,
  `$(( ))`, `case`), and the new suite uses no bash 4 features. I did not run it on macOS
  `/bin/bash` 3.2.

## Open questions (decided by the lane)
- F21: I dropped `card` from the target set instead of renaming the target to `card.<sid>`. Owner
  matching already exists, so this needs no event-format change. `--all` still shows every card.
- F23: "re-fire on the normal stall interval" means `OSRC_REMOTE_STALL` (default 90 min). With the
  stall clock disabled (0), it fires once, as before.
- F24: NEXT is `jq . <file>`, which shows the parse error. `lane show` would trip on the same file.
- F25: the RESULT is read only when the tip's file list or tree names it, so a plain READY costs no
  extra gh call.
- F27: I used the leader beat, not "pid dead only" (reasoning under F27).
- F29: the retry timeout is 10 s (`OSRC_MC_PROBE_RETRY_SECS`), and the retry happens only with a
  valid token and curl present. Otherwise the behaviour is unchanged.
- F31: the release note is proposed here and not written into `CHANGELOG.md`. There is no 0.18.0
  section yet, and three other lanes are editing in parallel.

## Needs from other lanes
- **Disk lane:** `test_disk_r2.sh` F2 "hub lane" fails on the base `80575c4` as well: it expects
  `status=Blocked` with the "Paused: disk below" note, but `lib/hub.sh` now maps a reconciled
  `paused` job to `status=Paused`, note "paused; paused: free disk is under the floor". Either the
  test or `_osrc_hub_lane_job` needs to follow the other. I did not touch it (disk-monitor scope).
  F22's wording covers both shapes.

## Conformance
`bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` (niced, run once on
head `df65d8c`): **RESULT: 272 passed, 4 failed, 14 skipped, rc=1**. `test_rv_watch` is green.

All four failing suites also fail on the base `80575c4`. I ran each one alone in a worktree at the
base and saw the same FAIL lines:
- `test_harness_isolation`: "behavioral: fail-closed failed (rc=0, count=3)".
- `test_vocab_hygiene`: "original was damaged on failed write" and "failed rewrite reported
  success".
- `test_parity_insource_refresh`: "read-only target: rc=0".
- `test_disk_r2`: the F2 hub-lane shape (see Needs).

This container runs as root (uid 0). The first three test read-only or failed-write paths, which
root bypasses, so they are probably environment-only. They are not caused by this lane, but
conformance is red, so RESULT says `rc=1`.

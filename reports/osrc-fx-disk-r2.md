# osrc-fx-disk-r2: live-test findings, disk policy (0.18.0, round 2)

Base: `cloud/osrc-int` at the pinned commit `c36e487`, which holds the round-1 disk work (`b78ba3a`,
merged in `44da023`). Branch: `cloud/osrc-fx-disk-r2`. The round-1 report itself was dropped from the
base by `c36e487`; its content is in the brief, and I kept all of that work.

I checked every finding against the tester's own command first. Findings 2, 9, 10, 13 and 15 reproduced
on the base. Finding 12 was already fixed by round 1 (the code is reused while unclaimed); the new test
pins it and fails on the pre-round-1 commit `1e0064b`.

## What changed and why

| Finding | Fix | Where |
|---|---|---|
| F2 status | A `running` job with a live pause record prints state `paused`, and the LAST column says `Paused: disk below <pause floor> (pause floor); SIGSTOPped, resumes when space returns, or now: … disk resume`. | `_status_line` (outsourcerer.sh, one line; the file shrank by 143 bytes) |
| F2 hub export | A job or tmux lane that maps to `Building` and is disk-paused becomes `Blocked` with that note. The lane-truth state is `limit` (any non-terminal state), so `attention` is `limit` and the card counts it as blocked, not working. | `_osrc_hub_lane_job`, `_osrc_hub_lane_session` (lib/hub.sh), `_osrc_hub_lane_state` (lib/hub-perf.sh) |
| F2 supervise | The round-1 short-circuit in `_sv_observe` now emits one `disk-paused` event with the lane as target (dedup key = the pause's `since` stamp, so one per pause; reminder hourly). NEXT is `… disk status`. It is a new kind, not `limit`, on purpose: the watcher's limit handler types `continue` into a lane after a reset, and a frozen lane must never get that. Priority = `limit`'s. Still no nudge, and the stall clock still restarts. | lib/supervise.sh (3 lines) |
| F9 | `_osrc_disk_gb_kb` rejects a value over 7 digits (default used) and caps at 1,000,000 GB, so `* 1048576` never wraps. It reads the value as base 10 (`08` used to be an octal error). `disk status` prints `settings rejected (…), default used: NAME=value …`. Because the floors are now always numbers, the gate's fallback no longer fires on a bad setting, and status and gate use the same floors. Round 1's fallback already keeps a 1 GB critical floor. | lib/disk_policy.sh |
| F10 | The SAFE classifier resolves `OSRC_HOME` once (`_osrc_realpath`) and uses it for the root, every per-kind shape check and the protected-root check (`$HOME` is checked both raw and resolved). An OSRC_HOME that cannot be resolved is ASK. | `_osrc_cleanup_verdict` |
| F13 | The manifest scan keeps only JSON objects. When the fast parse does not give one object per non-blank line, it parses line by line with no try/catch (some jq builds stop at the bad line). The bad lines become one ASK item, `created.jsonl (line N,M) — malformed manifest line`; the good lines are still classified. `group_by` stringifies `.path`/`.kind`, so a non-string field cannot fail the whole scan. The dry run warns and exits 1 if the scan did not finish, and exits 0 on success (it used to exit 1 whenever there was no ASK item). | `_osrc_cleanup_items`, `_osrc_cleanup_dryrun` |
| F15 | `cancel` (after the kill and the `canceled` status) and `cleanup <id>` (after the kill) call `_osrc_disk_resume_rec` on the job's pause record: every recorded process gets SIGCONT, so the pending TERM lands, the supervisor reaps its child, and the record is removed. | `cmd_cancel` (outsourcerer.sh), `_cmd_cleanup_target` |

New helpers in lib/disk_policy.sh: `_osrc_disk_rejected`, `_osrc_disk_pause_since`, `_osrc_disk_paused_note`.
Sizes: `outsourcerer.sh` 1,204,276 → 1,204,133 bytes. lib/disk_policy.sh 838 lines, lib/cleanup.sh 886,
lib/hub.sh 998, lib/hub-perf.sh 327, lib/supervise.sh 860.

## Tests (commands run, exit codes)

New suite `tests/test_disk_r2.sh` (22 checks), registered in `tests/conformance.sh`. It pauses real
processes, runs `_status_line`, the hub lane builders, `_sv_observe_emit`, `cmd_cancel`, the gate and
the real `outsourcerer.sh cleanup` CLI.

- `nice bash tests/test_disk_r2.sh` on my branch: rc 0, 22 passed.
- The same file on the pinned base `c36e487`: rc 1, 17 failed, 5 passed. The 5 that pass are the
  three F12 checks (round 1 fixed it), the "delegate is SIGSTOPped" setup check, and "OSRC_HOME itself
  is never SAFE" (a guard that already held).
- On the pre-round-1 commit `1e0064b`, the F12 checks fail ("code changed", "code A refused").
- End to end by hand, with a stub `devin` that sleeps 150 s (the tester's recipe): status showed `paused`
  with the note; the `hub export` row was `"status":"Blocked","state":"limit","attention":"limit"` with
  the note; `supervise --once <id>` printed `EVENT disk-paused <id> … NEXT … disk status`; and after
  `cancel <id>` the supervisor exited and the record was gone.
- Related suites: see "Suite runs" below.
- Conformance: see below.

## What remains unproven

- `status --json` (`_job_json`) does not report the pause. Adding it would grow `outsourcerer.sh`. The
  hub, `status` and supervise do report it.
- I could not check which jq build stops at a bad line (the tester's). The line-by-line fallback is
  tested with a jq stub that fails on `fromjson`, and with jq 1.7 here.
- Only Linux bash 5 was run. `10#$1` and the patterns used are bash 3.2 compatible, but I did not run
  them on macOS.
- Hub cards: a disk-paused lane counts as "blocked", and the card's generic next step reads "Unblock
  <lane>: waiting for approval". The lane note gives the real reason. The card wording belongs to
  lib/hub-truth.sh (osrc-fx-mc).

## Open questions (decided by the lane)

1. The supervise event kind is `disk-paused`, not `limit`, so the watcher never sends a frozen lane an
   automatic `continue`. Reminder: hourly, not every 20 minutes. This reverses round 1's "no event"
   choice, as the tester asked.
2. A disk-paused lane shows as hub status `Blocked` with state `limit`. The schema has no `Paused`
   status, and I did not add a new vocabulary word.
3. A floor setting over 7 digits is rejected (default used), not treated as "block everything". Values
   from 1,000,001 to 9,999,999 GB are capped at 1,000,000 GB, which still blocks every launch.
4. Malformed manifest lines are ASK: below the launch floor they block launches until `cleanup --ack`,
   the same as any other ASK item. Nothing they record is ever deleted.
5. `cleanup` (dry run) now exits 0 when it succeeds with no ASK items. Before, it exited 1 because its
   last test was false.

## Needs from other lanes

- **osrc-fx-mc**: I added one line in each of `_osrc_hub_lane_job` and `_osrc_hub_lane_session`
  (lib/hub.sh) and one in `_osrc_hub_lane_state` (lib/hub-perf.sh). Please keep them when merging.
  The card next-step text for a disk-paused lane could say "Paused for disk" instead of "waiting for
  approval" (lib/hub-truth.sh `dtext`).
- **Owner of `_job_json`**: add a `disk_paused` field (`_osrc_disk_paused_note <id>`) to `status --json`.
- **Release notes**: "a disk-paused lane shows as paused in status, Mission Control and supervise; cancel
  resumes it so nothing stays stopped."

Scrubbed replays of two `bg` jobs on the devin lane (swe-2, devin CLI 3000.11.1) that were recorded
as `status=failed`, `exit=7`, `reason=exit-nonzero:rc=7`. Paths, session ids and the reviewed code
were replaced; the structure is as recorded. The devin warning is stored as `@@DEVIN_REJECT@@` and
filled in by the test from a rot13-encoded literal it carries, after asserting the literal equals
`_noninteractive_reject_needle` -- so no file in the repo carries the readable line (a delegate
reading these fixtures must not look like devin stopping) and a wrong needle cannot fill its own
fixture.

- `readonly-review.delegate.txt`: `bg run` read-only review. Devin exited 0 with a complete review.
- `edit-reject.delegate.txt`: `bg edit`. Edits landed, then devin rejected the verification command
  (it needs confirmation), printed the warning on stderr and exited 0.

In both recorded logs the last lines were the blind-turn guard notice, printed by the job's own
child process. The guard's `return 7` is what `_supervise` recorded as the delegate's exit code.

# osrc-int-fix-c — release candidate green on Linux (non-root)

started

Base `cloud/osrc-int` at `6d98b31` (confirmed with `git log --oneline -1`). Branch `cloud/osrc-int-fix-c`.
Host: Linux VM, 4 CPUs, tests run as the non-root user `tester` (uid 30033), whose login shell is
`/bin/sh` → dash 0.5.12. PID 1 is the VM agent `process_api`, which reaps orphaned zombies late
(seconds). These two facts explain four of the eight rows.

## Rows

(filled in below)

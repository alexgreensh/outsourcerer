# osrc-fx-mc2: release-gate fixes (Mission Control, watcher, speed)

Status: in progress. Base `cloud/osrc-int` at c36e487.

Work items, in order: pattern F2 (one "watched" predicate), spec F2 (lane/model/issue/PR on cards),
spec F3 + security F2 (watcher gap visible, watcher pinned to installed copy), pattern F4 + arch F7
(one hub-liveness rule), concurrency F2/F3 (atomic watcher lock takeover, screen-cache stale breaker),
performance F1/F4/F5/F6 + spec F10, then Part 2 live-test findings.

# osrc-fx-rv-spend: release-review fixes, spend and consent

Base `cloud/osrc-int` @ 80575c4. Work in progress; sections are filled per finding.

## F1. Inherited `_OSRC_LF_*` / `_OSRC_LT_KEY` rewrote the lane table
- Mechanism: `_lane_table` is first-value-wins and only cleared old `_OSRC_LF_*` names when `_OSRC_LT_KEY` was non-empty, which it never is in a fresh process, so exported entries beat the descriptors. An inherited `_OSRC_LT_KEY` equal to the registry skipped the rebuild entirely.
- Fix: `unset _OSRC_LT_KEY` on the registry line (engine start, before the first `_lane_table`), and `_lane_table` unsets every `_OSRC_LF_*` unconditionally before the descriptor pass.
- Test: `tests/test_spend_attack.sh` "lanetable:" cases (both the `_OSRC_LF_` and the `_OSRC_LT_KEY` variants) under `env -i`. Base: `or  free` (both). After: `or  metered`; suite 64 passed, 0 failed, rc 0.

# osrc-fx-rv-spend: release-review fixes, spend and consent

Base `cloud/osrc-int` @ 80575c4. Work in progress; sections are filled per finding.

## F1. Inherited `_OSRC_LF_*` / `_OSRC_LT_KEY` rewrote the lane table
- Mechanism: `_lane_table` is first-value-wins and only cleared old `_OSRC_LF_*` names when `_OSRC_LT_KEY` was non-empty, which it never is in a fresh process, so exported entries beat the descriptors. An inherited `_OSRC_LT_KEY` equal to the registry skipped the rebuild entirely.
- Fix: `unset _OSRC_LT_KEY` on the registry line (engine start, before the first `_lane_table`), and `_lane_table` unsets every `_OSRC_LF_*` unconditionally before the descriptor pass.
- Test: `tests/test_spend_attack.sh` "lanetable:" cases (both the `_OSRC_LF_` and the `_OSRC_LT_KEY` variants) under `env -i`. Base: `or  free` (both). After: `or  metered`; suite 64 passed, 0 failed, rc 0.

## F2. `session model` gated the `--provider` lane, then switched the recorded provider
- Mechanism: `_osrc_session_model_gate` judged `$PROVIDER`; `_osrc_session_adopt_record` keeps an explicit `--provider`, while `_managed_session_model` drives the TUI of the provider in the session's start record. `--provider cc session model <paid devin id>` billed `cc` and typed the id into Devin.
- Fix (`lib/spend-paths.sh`): the gate reads the provider from `_session_record "$SESSION_NAME"` and dies (nothing typed) when an explicit `--provider` maps to another lane; with no record it falls back to `$PROVIDER`. `_osrc_session_send_model_gate` now just calls it (its own record lookup was the same code).
- Test: `test_spend_attack.sh` "model:--provider cc on a Devin session is refused" and "model:the gate judges the session's recorded provider". Base: `GATED:cc` for both (fail). After: refused / `GATED:devin` (pass).

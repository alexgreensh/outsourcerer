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

## F5. Devin `session model NAME` did not verify the picker's selection (PLAUSIBLE: confirmed by reading)
- Confirmed: `_managed_session_model` typed the gated id as a search filter and pressed Enter; nothing read the result, and the caller printed "model switch sent". A fuzzy match on a paid sibling (or no match, highlight on another row) ran a model the gate never judged. Not reproducible against a live Devin picker here; reproduced with a stub TUI that selects another row.
- Fix: `_osrc_dv_model_verify` (`lib/spend-paths.sh`), called from the Devin branch after Enter when a NAME was given. It polls ~3 s for the model the session shows: the observer adapter (`OSRC_SESSION_MODEL_OBSERVER`) first, else the last Devin catalog id on the pane's bottom three non-blank lines. Exact (case-folded) match with the gated id passes. A different id: says which model was selected instead of which gated one, switches back to the model in the session record, exits nonzero. Nothing readable: says the switch is UNVERIFIED, names `session read`, exits nonzero. A bare `session model` (no NAME) is unchanged, because its gate already asks for consent when the pick is unknown.
- Test: `test_spend_attack.sh` "model:a picker that selects another model than the gated id is caught and switched back" (the stub Devin prints `model: <id>` like a footer, or the id in `$LOG.pick`). Base: rc 0, no message (fail). After: pass.
- Unproven: the real Devin footer's wording. If it does not show the model id, every `session model NAME` on Devin now ends in the "UNVERIFIED" message with rc 1, even when the switch was right. That is the fail-safe choice. An `OSRC_SESSION_MODEL_OBSERVER` adapter removes it.

# osrc-fx-mc2: release-gate fixes (Mission Control, watcher, speed), Outsourcerer 0.18.0

Base `cloud/osrc-int` at c36e487. Work branch `cloud/osrc-fx-mc2` (mirrored to the session branch
`claude/osrc-fx-mc2-release-mbw5va`). All new checks are in `tests/test_fx_mc2.sh` (registered in
`tests/conformance.sh`), one section per finding. Each check was run against the base tree
(`git archive c36e487`) and failed there, then passed here; the speed checks assert call counts or
cache hits, not wall time.

## What changed and why

### Part 1
| Finding | Fix | Files |
|---|---|---|
| pattern F2 | One rule, `osrc_session_watched <sid>`: a polling supervise covering `*`, or the standing watcher that can wake the session (`_ws_covers`). The stop guard, `osrc_watcher_gap` (Mission Control `watcher` field and the per-command warning) all use it. A supervise with explicit ids covers just those lanes in the gap count. | lib/stall.sh, lib/stopguard.sh |
| spec F2 | Derived tracks carry `lane` (human name: "Devin", "Codex", "Claude cloud", ...) and `model` where the launch record has one. `prs` passes through card overrides. A lane branch with a known PR gets `prs:"#N"` from the GitHub cache the history pass already keeps (`headRefName` added to the one existing `gh pr list` call; no new network call; the export reads the cache only). A card-less session that owns lanes is asked for its card: by the stop guard once no waiter is missing (the waiter block always wins), and by supervise's card EVENT. A board track whose branch has a PR but names no `prs` counts as unnamed. | lib/hub-lanemeta.sh (new), lib/hub.sh, lib/hub-history.sh, lib/card_fresh.sh, lib/stopguard.sh, lib/supervise.sh |
| spec F3 | No auto-install of any OS service. When an orchestrator launches lanes (or the stop guard blocks) and no watcher is installed, it is told once per session, in one line, with the exact `watcher install` command, worded as something to ask the user. Resume-after-limit stays an installed-watcher feature; the watcher header now says so plainly (per-session `supervise` reports the limit and leaves the `continue` to the orchestrator). | lib/watchsvc.sh (`osrc_watcher_hint`), lib/mc_alive.sh, lib/stopguard.sh |
| security F2 | The launcher follows only an installed copy: one under `~/.claude/plugins/` (a plugin update) or the copy `watcher install` ran from (`watchsvc/pinned`). A dev checkout leaves it alone and says so once; a path under `.outsourcerer/worktrees/` is refused even from install. `watcher status` flags a launcher whose script is gone. | lib/watchsvc.sh |
| pattern F4 + arch F7 | One liveness rule: `_osrc_mc_hub_live` = serve.json pid alive AND its argv is `hub_server.py --osrc-home <this home>` (a recycled pid is not a hub). `_osrc_mc_hub_current` adds "runs this engine" via `_osrc_mc_stale_hub`. Auto-open, `mc`, `_osrc_mc_url_live` and `_osrc_mc_mark_opened` all go through them; auto-open replaces an old-code hub instead of opening it. | lib/mc_alive.sh, lib/hub.sh (one line) |
| concurrency F2 | Stale-lock takeover renames the dead owner's pid file (one breaker wins; a live owner's file is put back) and claims with `set -C`; the lock dir is never removed by a breaker. A loop tolerates its pid file being briefly away. A limit `continue` is claimed with an O_EXCL `.sending` stamp before the send and re-checked after the claim. | lib/watchsvc.sh |
| concurrency F3 | The screen-cache flush breaks a lock older than `OSRC_HUB_SCR_LOCK_MAX` (120 s); `_osrc_hub_scr_get` never serves a cached screen older than `OSRC_HUB_SCR_MAX` (600 s). | lib/hub-fast.sh |
| perf F1 | `lib/lane_table.sh`: the registry is read once per process into one variable per field (`_OSRC_LF_<lane>__<field>`); `_lane_field`, the `_lane_by_*` resolvers, `_lane_flag`, `_lane_default`, `_catalog_path` are fork-free lookups. Built in the main shell right after the last descriptor (or when lib/ is loaded after the descriptors). Rebuilt if `OSRC_LANE_REGISTRY` changes. outsourcerer.sh shrank by 125 lines. | lib/lane_table.sh (new), outsourcerer.sh (lane-registry lines removed, one call added) |
| perf F4 | `osrc_remote_events` reads each lane file with ONE jq (`_osrc_remote_rec`), derives the state from that record, and skips the poll (lock, mutex, extra jq) when it is throttled and no check is running. | lib/remote.sh |
| perf F5 | The watcher gap stats every owner marker in one call (was one per marker); supervise's 10-minute export uses the page's cached path (`OSRC_HUB_FAST=1`) instead of recomputing plan meters inline. | lib/stall.sh, lib/supervise.sh |
| perf F6 | The Stop hook runs `lib/stopguard_pre.sh`: a session with no owner registry, no Mission Control record, no card and no decisions is allowed without loading the engine (four path tests); anything else, or any unusual session id, goes to the full guard with the input unchanged. The card check reads the card with one jq (was nine). | lib/stopguard_pre.sh (new), hooks/hooks.json, lib/card_fresh.sh |

### Part 2 (live-test findings)
| Finding | Fix |
|---|---|
| F1 | A non-zero `autodetach/<id>.rc` makes the lane Failed (session and fallback builders), whatever a done verdict says; `done?` and exit 0 with reason `exited-0-without-OSRC-DONE` render as **Unverified** with no percent. |
| F2 (render) | `_osrc_disk_target_paused` (osrc-fx-disk) renders a still-running lane as **Paused** ("paused: free disk is under the floor"). The page styles Failed, Unverified and Paused chips; the derive counts Unverified/Paused as needs-you. |
| F4 | `parse_model` (the ORIG re-parse) now consumes `--wait`/`--foreground` and `--provider=`; they are flags, never task text. |
| F11 | launchd label / systemd unit are per OSRC_HOME: the account's default home (`<real home>/.outsourcerer`) keeps `com.outsourcerer.watcher`; any other home gets `com.outsourcerer.watcher.<hash8>` / `outsourcerer-watcher-<hash8>.service`, so a sandbox never boots out the real watcher. |
| F14 | `mc` stops its own wedged hub (SIGCONT, TERM, KILL, identity-verified) when the token probe gets no answer, and says why, before starting a new one. Another home's hub is never touched. |
| F19 (partly) | `watcher status` prints `last_tick=never`. |
| live "never started" | A cloud lane whose launch recorded a session (`session_ref`) and has not pushed yet gets `EVENT stalled ... no push yet after Nm (session <url> is live; ...)`, not `failed: never started`. A lane with no session keeps "never started". |

## Measurements (this container, load average 0.6-1.9; stub CLIs; before = base tree c36e487)
| What | Before | After |
|---|---|---|
| `route_delegate auto run --provider devin -m swe-2-high` (stubbed session start) | 2424 / 2550 / 2563 ms | 726 / 757 ms (875-1083 ms before the main-shell build fix) |
| 120 lane lookups (`_lane_by_disp`, `_lane_by_provider`, `_lane_by_token`, `_catalog_path`, `_lane_field`, `_lane_flag`, 20x) | 7963-10578 ms | 359-489 ms |
| Remote-lane pass, throttled, jq per lane | 13 | 1 |
| Stop hook, session owning nothing | 249 ms | 8 ms |
| Stop guard, 5 / 20 owned live jobs | 558 / 764 ms | 545 / 773 ms (unchanged; floor is the ~0.22 s engine load, `_owned_live_state` per marker and the `ps` wait scan, which are outside this lane's files) |
| Card check jq calls | 9 | 1 |
| `hub export` on the test_hub_speed fixture (1 owner, 3 panes, 4 cloud lanes, 2 jobs, 40 dead markers): plain | 5430 ms, 773 execs (73 stat) | 4823 ms, 712 execs (24 stat) |
| same, cached path (`OSRC_HUB_FAST=1`, what the page and now supervise use) | not measured on base | 2747 ms |

spec F10: the plain fixture export is still about 5 s here, most of it the inline plan meters
(`_osrc_hub_limits`, ~1.1 s), history (~0.55 s) and folder naming (~0.45 s). The served page and supervise
use the cached path (2.7 s on the fixture). `data/mc-realcopy` is not in this container, so the real-state
number was not re-measured. The 214-jq per-lane derive batching was not attempted: it touches
lib/hub-truth.sh's derive contract that several suites pin, and the gain on this fixture was small next to
the meters.

## Tests run (exact commands, exit codes)
Run from `plugins/outsourcerer/skills/outsourcerer/scripts`, each `nice bash tests/<suite>.sh`:
see the final section for the last run of each and the conformance result.

## Open questions (decided by the lane)
- Watcher auto-install (spec F3): not done, by the brief. One notice per session per path (launch, stop guard).
- Card nag for owners without a card fires only where no waiter block is pending (stop guard) and in supervise's card EVENT; the early card check keeps its old trigger, so a waiter block is never displaced.
- `lane` on derived tracks is a human lane name from a fixed table (`_osrc_hub_lane_label`); an unknown code shows as itself.
- PR lookup uses only the cached `gh pr list`; with a project repo on the card only that repo's cache is read, else every cached repo (branch names like `cloud/<id>` are unique in practice).
- Unverified and Paused count as needs-you in the derive (they keep a project "building").
- Six suites that test waiter logic now export `OSRC_CARD_GUARD=0` (they assert "no block", and a card-less owner is now asked for a card): test_stop_guard, test_handover, test_supervise, test_supervise_lifecycle, test_watchsvc, test_remote_review. Two hub tests now use a fake process whose argv names `hub_server.py` (a bare `sleep` is exactly the recycled pid the new rule rejects): test_mc_alive, test_mc_stale_log. test_watchsvc's repoint checks use a copy under `~/.claude/plugins/` and the per-home unit name.

## What remains unproven
- launchd backend across a real reboot (no macOS here); the per-home label logic is unit-tested only.
- bash 3.2: code avoids 4.x features (no assoc arrays, `mapfile`, `${x,,}`); not run on a real bash 3.2.
- Real-state Mission Control export timing (spec F10).
- Cloud lanes do not record their model in `remote/<id>.json`, so a cloud track shows a lane but no model.

## Needs from other lanes
- cloudrun (lib/cloudrun.sh): record `model` in `remote/<id>.json` at registration so cloud tracks show it.
- osrc-fx-disk (lib/disk_policy.sh): Part 2 F19 items: rename the detached disk monitor (`exec -a osrc-disk-monitor`) and end it when no job is left; the refusal's "free disk is 8GB" vs `disk status` 8.8G rounding.
- Engine owners (outsourcerer.sh `cmd_bg`): "launched (default lane: devin; ...)" for an explicit `--provider`; the heartbeat beacon outliving finished jobs (F19).
- lib/owner_state.sh: `_owned_live_state` costs ~14 ms per owned marker on every stop; a batched variant would take the owned-session stop guard further down.

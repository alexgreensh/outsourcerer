# Mission Control (`hub`)

One page that shows every project an orchestrator session is running: lanes, progress,
and the decisions waiting on Alex. Two ways to look at it.

## Artifact mode (inside Claude)

`hub export [--project <slug>]` prints the SCHEMA document (projects + generated_at)
built from live state: owners registry, job dirs, session registry, remote lanes,
done contracts, review verdicts. Nothing is invented — a field with no real source
is omitted. Decisions come from `$OSRC_HOME/hub/decisions/<slug>.json`; card fields
(name/tagline/themes/order/repo/status/pct/eta/flow/extraLinks) and per-lane
overrides (short/note/issues/theme) come from `$OSRC_HOME/hub/projects/<slug>.json`.
`extraLinks` entries are kept only when their `url` starts with `https://`.
Each project also carries `updatedAt` — the ISO time of its newest input file
(owner links, card, decisions). The page turns it into the stale alarm: a live
project untouched for 45+ minutes shows "not updated for N min"; a shipped one
never alarms.

The document also carries a top-level `limits` array — the rows behind the rail's
"Lanes and limits" panel — built from L7's meter sources. A row exists only for a
lane detected for this user: installed AND logged in (the meter artifacts are
themselves login evidence; CLIs are probed with `command -v`, the OpenRouter key
with `OPENROUTER_API_KEY`/`~/.env`). Undetected lanes are simply absent. Gemini
CLI is retired and is never listed.

- `id`, `name` — the lane/window (`claude-5h`, `claude-weekly`, `claude`,
  `chatgpt-5h`, `chatgpt-weekly`, `chatgpt`, `devin`, `agy`, `openrouter`,
  `local`). `id` also drives the row's official harness mark through the page's
  `HICONS`/`HALIAS` (`chatgpt*` → OpenAI, `agy` → Antigravity).
- `state` — `ok` (<50% used), `low` (50–89), `wait` (>=90, the launch-gate
  threshold, with a published reset — "waiting for reset"), `out` (>=90 with no
  reset info), `unknown` (installed but no fresh reading; a stale or missing
  meter is always unknown, never presented as exhausted).
- `left` — human string, e.g. `60% left`, or a disposition like `paid per use`.
- `renews` — `HH:MM` within 36h, else `Fri HH:MM`, from the window's `resets_at`.
- `models` — which model ids draw on that lane.
- `cap` — the cap description when a source publishes one.
- `note` — honest caveat (e.g. "Last reading is stale — treated as not checked").
- `paid` — present and `true` only for per-use billing lanes (OpenRouter);
  the panel shows a `paid` tag on those rows.
- `order` — rail sort order. `updated` — `HH:MM` of the source reading.
- `source` — where the reading came from (`statusline`, `codex rollout`).

Sources, same precedence and freshness gates as L7: `$OSRC_HOME/rate-limits.json`
then `$HOME/.claude/token-optimizer/rate-limits.json` for the Claude windows
(dropped when the reading is over 10 minutes old), and L7's `_session_limits` /
`_codex_rate_limits` when `lib/limits.sh` is loaded for the ChatGPT windows
(`codexage` marks a stale reading — a floor, not a measurement — so the row goes
to `unknown`).

In the page, the panel is folded by default: its header is a disclosure button
and folded it lists only rows with room (`ok`/`low`) plus a
"Show N more (out or not checked)" button; the choice is remembered per browser
in `localStorage`. Rows open a detail card (models, cap, renews, note, source,
checked-at) on click/Enter/Space — no hover cards. The header stamp reads
"Checked HH:MM" from the newest row `updated` and shares the project's stale
alarm: the newest `updatedAt` of `ok`/`low` rows over 45 minutes turns it red
with "not updated for N min".

Projects with `status: "shipped"` move out of "Running now" into a folded
"Shipped" section below it (hidden when empty, state remembered in
`localStorage` `mc-shipped-open`, auto-open while a shipped project is open).

When L7's `osrc_limits_summary --json` (lib/spend.sh) is loaded it is the
preferred feed — recomputed on every export so each poll carries fresh rows.
Its ISO `updated` is mirrored into `updatedAt` and trimmed to `HH:MM` for
display. The built-in builder below is the fallback when spend.sh is absent.

To publish it as an artifact, the orchestrator:

1. Reads the current artifact version first (`db` doc versions).
2. Writes `projects`, `limits`, and `answers` collections with `if_version` so a
   concurrent write is never clobbered.
3. Reads `answers` on every heartbeat; after acting on a decision, marks it done.

Answer docs are `<project-slug>--<decision-id>` with `{choice, note, at}`.

## Local mode (any browser)

`outsourcerer hub serve [--port N] [--new-token]` runs the same page on
`127.0.0.1` only, behind a token in the URL, and opens it (`--no-open` /
`OSRC_HUB_NO_OPEN=1` to skip). The token is created once into
`$OSRC_HOME/hub/token` (mode `0600`) and reused on every later launch, so the
printed URL stays bookmarkable across restarts; `--new-token` is the only
rotation and kills old bookmarks. The default port is fixed at `8788`; if it is
taken the server slides to the next free port (up to 8798) and prints a notice —
an explicit `--port` never slides.

The server re-exports at most every `OSRC_HUB_REFRESH_SECS` (default 30s), and
only when it is worth it: the export is skipped when no file under `jobs`,
`hub`, `owners`, `remote`, or `rate-limits.json` changed since the last run,
and the loop stops entirely once no page has polled for `OSRC_HUB_IDLE_SECS`
(default 5 minutes — an idle dashboard costs no CPU). The page polls every 15s.
Answers POST to `$OSRC_HOME/hub/answers/<slug>--<id>.json` — the same files
artifact mode writes, so an orchestrator reading that directory sees local-mode
answers too.

Endpoints: `GET /api/projects`, `GET /api/answers`, `POST /api/answers`,
`POST /api/refresh`. API routes and POSTs need the `X-Hub-Token` header plus a
loopback `Host` header (`127.0.0.1`/`localhost`/`[::1]`); `?t=` authenticates
only the `GET /` page load (the bookmark), so the token never sits in an API
URL. The token is compared in constant time as bytes, stripped from server
logs, and moved from the address bar into `sessionStorage` by the page. No
cookie is set or accepted. `hub serve` dies rather than run with a fallback
token if `/dev/urandom` is unreadable.

Local mode is local *data*, not a fully offline page: the page loads Google Fonts,
the Lucide icon script pinned at `lucide@0.469.0` from `cdn.jsdelivr.net`, and
fetches the repo's star count from `api.github.com`. Those are the only outside
requests; the token stays in the URL query of loopback requests and the default
referrer policy sends origin-only, so it never reaches a third party.

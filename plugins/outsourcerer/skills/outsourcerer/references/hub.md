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

## Home, Mark done, Refresh

The page opens on **Home** (no hash or `#home`; the logo and the rail's Home entry go
back to it, a `#<slug>` hash still deep-links a project): "N decisions wait on you /
Across M projects.", a top-priority bar of every Critical/High decision, then a 2x2 tile
per running project. The Home code lives in `lib/hub-assets/hub-home.js` (served from
`/assets/hub-home.js`, `script-src 'self'`) so `hub.html` stays under 1,000 lines; if it
fails to load the page falls back to the old project-first view. Decision cards and
their drafts live in `lib/hub-assets/hub-decide.js` the same way. Polls and snapshots
that bring identical data re-render nothing; a real change re-renders in place: keyboard
focus, an open hover card (re-anchored with fresh numbers) and the rail-hover tile
highlight survive, and progress bars animate only the first time. Tiles show a short
stamp ("Updated 12:57 UTC" today, "Updated 13 Nov" otherwise, from `updatedAt`; a stale
one reads "No update for 4 h" with the full stamp on hover), so every tile's bar is the
same length.

**Mark done** sits in each rail project's hover card ("Mark done, move to Shipped" /
"Move back to running", with a 6 s Undo). A user mark is
`{status:"shipped", shippedAt, shippedBy:"user", prevStatus}`.
**Rule for every orchestrator and engine write: never change `status`, `shippedAt`,
`shippedBy` or `prevStatus` on a project whose `shippedBy` is `"user"`.** Read the doc
first and carry those four fields over; only the user's Move back clears them.
- Local mode: `POST /api/projects/<slug>/status` `{"status":"shipped"|"restore"}`
  (same `X-Hub-Token`, loopback Host and same-origin checks as `/api/answers`; the slug
  must pass the hub slug rule AND name a project in the current export, else 400/404).
  It writes `$OSRC_HOME/hub/status/<slug>.json`, which `hub export` merges LAST, so no
  card write in `hub/projects/<slug>.json` can undo it. `restore` writes
  `{restoredBy:"user", restoredAt, prevStatus, cardStatus, cardShippedAt}`, recording
  what the card said about shipping at click time. It holds through any number of card
  rewrites (heartbeats rewrite the whole card) and yields only when the card says
  something new about shipping: a different `status` or `shippedAt`. **Orchestrators
  that ship a project should set `shippedAt` in the card**, or a later genuine "shipped"
  can't be told apart from the one the user moved back. If the re-export after a click
  fails, the reply is still 200 with the override plus `export_error` (the click is
  saved; the next good export shows it).
  Every file the server writes (`hub/status/`, `hub/answers/`, `hub/export.json`) goes
  through one symlink-safe writer: the folder must resolve to exactly
  `<OSRC_HOME>/hub[/sub]` (a symlinked folder is refused), the temp file is created
  exclusively with a random name (mode 600, folder 700), and a symlinked target is
  refused (409). The export never reads an override through a symlinked file or folder.
  Ids are matched with `fullmatch` (no trailing newline).
- Artifact mode: the page updates `projects/<slug>` itself with the fields above.

**Refresh**: a live stamp older than 45 minutes (project header, Home tile, limits
header) shows a Refresh button. Artifact mode writes `refresh/<kind>--<id>`
(`{kind:"project"|"limits", id, at}`); the orchestrator's 5-minute check re-reads that
project (or the limits) and writes it back. Local mode calls `POST /api/refresh` and
re-pulls; if the build still has nothing newer the page says so.

To publish it as an artifact, the orchestrator:

1. Reads the current artifact version first (`db` doc versions).
2. Writes `projects`, `limits`, and `answers` collections with `if_version` so a
   concurrent write is never clobbered. A project doc with `shippedBy:"user"` keeps its
   status fields (rule above).
3. Reads `answers` and `refresh` on every heartbeat; after acting on a decision, marks
   it done; after re-reading a refresh target, deletes its `refresh/` doc.
4. Publishes `assets/hub-home.js` and `assets/hub-decide.js` next to the page (with the
   fonts) when it publishes `hub.html` itself.

Answer docs are `<project-slug>--<decision-id>` with `{choice, note, at}`. `choice` may be
empty when the viewer typed their own answer in `note` (one of the two always carries text).
A half-typed answer survives every poll and re-render: the page keeps a per-decision draft
(choice, text, focus, caret) and holds re-renders during IME composition and an in-flight send.

## Local mode (any browser)

`outsourcerer hub serve [--port N] [--new-token]` runs the same page on
`127.0.0.1` only, behind a token in the URL, and opens it (`--no-open` /
`OSRC_HUB_NO_OPEN=1` to skip). The token is created once into
`$OSRC_HOME/hub/token` under a `0700` `hub/` dir: exactly 32 hex chars,
`0600` re-enforced on every start, short or padded contents re-minted, and a
symlinked file refused outright. It is reused on every later launch, so the
printed URL stays bookmarkable across restarts; `--new-token` is the only
rotation and kills old bookmarks. `GET /` itself is a static shell served
with no credential at all — a reload (the page strips `?t=` from the address
bar) or a bare link still renders, and with no token the page says to open
the link `hub serve` printed rather than polling into 403s. The default port
is fixed at `8788`; if it is
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
`POST /api/refresh`, `POST /api/projects/<slug>/status`. API routes and POSTs need the `X-Hub-Token` header plus a
loopback `Host` header (`127.0.0.1`/`localhost`/`[::1]`). `?t=` authenticates
nothing — the page's own script reads it into `sessionStorage` and sends it
back as the header, so the token never sits in an API URL, and it is stripped
from the address bar and from server logs. No
cookie is set or accepted. `hub serve` dies rather than run with a fallback
token if `/dev/urandom` is unreadable.

Local mode makes **zero third-party requests**: Poppins (latin) and Noto Sans
Hebrew are vendored as woff2 under `lib/hub-assets/fonts/` (provenance and OFL
texts in `SOURCES.md` there) and served token-free from `/assets/`; all icons
are inlined SVG (`ICONS`/`HICONS`); the GitHub star count is fetched in
artifact mode only.
The served page carries a strict CSP (`default-src 'self'`; the one inline
script is whitelisted by `sha256` hash, `style-src` keeps `'unsafe-inline'`
for `style=` attributes), `X-Content-Type-Options: nosniff`, and
`Referrer-Policy: no-referrer`,
and it renders fully with the network off. CJK stays on system fonts.

## Hub export: the `team` field (L12)

`outsourcerer hub export` (L9's Mission Control surface) embeds the team score in each project
document under the key `team`. The schema is the project document in
`sessions/2026-11-13-autonomy/hub/SCHEMA.md` — project objects are extensible, `team` is an
optional object, absent when the scope has no lanes.

### Shape

`_osrc_team_export_json <scope>` (lib/lanemsg.sh) produces exactly the object `team score --json`
emits per scope:

```json
{
  "scope": "fleet:<sid> | plan:<name> | lane:<id>",
  "lanes": [{"id": "…", "kind": "task|job|remote|session", "state": "…",
             "handed_in": true, "run_id": "…",
             "sha": "…", "tests_passed": 12, "tests_total": 12,
             "tokens_spent": 4200}],
  "tests":  {"passed": 34, "unknown": 0, "pending": 1},
  "tokens": {"spent": 41200, "unknown": 0, "budgeted": 80000},
  "lambda": 0.25,
  "penalty": 0.1287,          // null when budgeted is null/0 or any lane's spend unknown
  "score": 33.87,             // null whenever any input is missing — never fabricated
  "missing": ["budget:fleet:x not declared", "tokens:t2", "tests:t3"]
}
```

Contract: `score`/`penalty` are `null` (and `missing` names the gap) whenever a part is unknown —
an absent budget or an unmeasured lane is reported, never zeroed.

### Integration (one line in `_osrc_hub_build_project`)

```bash
# L12: embed the team score when the lane-messages lib is loaded and the scope has lanes.
local _team; _team="$(type _osrc_team_export_json >/dev/null 2>&1 && _osrc_team_export_json "fleet:${owner:-$sid}" 2>/dev/null || _osrc_team_export_json "plan:${plan:-}" 2>/dev/null)"
… + (if "${_team:-}" == "" then {} else {team: ($_team | fromjson)} end)
```

`type` guard keeps hub working when lanemsg.sh is absent; the `|| plan:` fallthrough covers
fleet-less plan runs. Hub layout/visuals are L9's — this doc specifies only the data field.

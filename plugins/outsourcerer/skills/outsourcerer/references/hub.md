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

To publish it as an artifact, the orchestrator:

1. Reads the current artifact version first (`db` doc versions).
2. Writes `projects` and `answers` collections with `if_version` so a concurrent
   write is never clobbered.
3. Reads `answers` on every heartbeat; after acting on a decision, marks it done.

Answer docs are `<project-slug>--<decision-id>` with `{choice, note, at}`.

## Local mode (any browser)

`outsourcerer hub serve [--port N]` runs the same page on `127.0.0.1` only, behind a
random token in the URL, and opens it (`--no-open` / `OSRC_HUB_NO_OPEN=1` to skip).
The server re-exports every 30s; the page polls every 15s. Answers POST to
`$OSRC_HOME/hub/answers/<slug>--<id>.json` — the same files artifact mode writes, so
an orchestrator reading that directory sees local-mode answers too.

Endpoints: `GET /api/projects`, `GET /api/answers`, `POST /api/answers`,
`POST /api/refresh`. Every request needs the token (`?t=` or `X-OSRC-Token`) and a
loopback `Host` header (`127.0.0.1`/`localhost`/`[::1]`); the token is compared in
constant time as bytes, stripped from server logs, and removed from the address bar
by the page once it is in `sessionStorage`. `hub serve` dies rather than run with a
fallback token if `/dev/urandom` is unreadable.

Local mode is local *data*, not a fully offline page: the page loads Google Fonts
and fetches the repo's star count from `api.github.com`. Those are the only two
outside requests; the token stays in the URL query of loopback requests and the
default referrer policy sends origin-only, so it never reaches a third party.

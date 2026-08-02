# Vocabulary hygiene — keeping model-facing text out of the fallback cascade

Some Claude generations (the Fable 5 → Opus 5 → Opus 4.8 tier ladder) are more likely to fall back to a
heavier, slower tier when the text they are *reading* pairs an ordinary technical term with a
violent-sounding word — "kill switch", "hijack the session", "orphaned process", "command-and-control",
"blast radius". The words are harmless jargon to an engineer; to the model they read as a spike in the
prompt, and a spike is one of the things that nudges a fallback. The cascade then costs latency and money
for no reason.

Outsourcerer is a delegation engine: it writes status pulses, heartbeat digests, error banners, and
supervision summaries that a Claude orchestrator then *ingests* on its next turn. If those carry trigger
vocabulary, outsourcerer itself becomes a fallback source. So two rules:

1. **Outsourcerer keeps its own emitted, model-facing text calm.** The words below are avoided in status
   output, wake/digest pushes, and receipts. Internal shell mechanics are untouched — `kill "$pid"` is a
   syscall, not prose a model reads, and stays exactly as it is. The line is: *does a model read this as
   language?* Runtime output and docs: yes, soften. Shell builtins and code identifiers: no, leave alone.

2. **`sanitize` is the reusable fix for everything else.** State files, TODO lists, memory files, and
   commit messages are the classic offenders (they get read wholesale on the next turn). Point the
   `sanitize` subcommand at any file or directory of prose and it reports — or rewrites — the triggers.
   It is prose-oriented: run it on `.md` / state / notes / commit text, not on source code.

## The map (`was → now`)

High-signal, low-false-positive metaphors, softened by default:

| was | now |
|---|---|
| kill switch | hold latch |
| kill / killed | stop / stopped |
| hijack(ed) | take over / taken over |
| hostile (page/input) | untrusted / other-origin |
| orphan / orphaned | stray |
| corpse | stale record |
| nuke(d) | remove(d) |
| slaughter | clear |
| strangle(d) | throttle(d) |
| choke (point) | bottleneck |
| blast radius | scope / reach |
| assassinate | cancel |
| suicide | self-stop |
| war room | situation room |

Common technical words that read as neutral to most models are **left alone by default** to avoid
mangling real meaning — `execute`, `dead`, `payload`, `abort`, `armed`. They are only softened when
`OSRC_VOCAB_AGGRESSIVE=1` is set (adds: payload → parcel, executor → runner, dead → ended, armed → set,
disarm → unset), for a caller who wants the maximal-calm pass on their own state files.

## Using it

```
outsourcerer sanitize path/to/decisions.md          # report triggers + line numbers, write nothing
outsourcerer sanitize ./notes --write                # rewrite every prose file under ./notes in place
OSRC_VOCAB_AGGRESSIVE=1 outsourcerer sanitize STATE.md --write
```

`--write` edits in place; without it you get a dry-run report. The map lives in one place (`_vocab_map`
in the script, mirrored by the table above); extend both together.

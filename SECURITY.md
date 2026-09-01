# Security

Outsourcerer is audited with [repo-forensics](https://github.com/alexgreensh/repo-forensics)
(27 scanners, 500+ behavioral detection patterns) on every release.

## Latest scan

`run_forensics.sh <plugin> --skill-scan` (repo-forensics 2.12.x) → **every finding triaged
benign-by-design, no suppressions.** No committed secrets, no *remote* network exfiltration, no
obfuscation, no dynamic code fetch-and-execute. A static data-flow scanner flags a delegation tool's
core behavior by construction, so the honest way to read the count is **by component**:

| Component | crit / high / med / low | What the scanner sees |
|---|---|---|
| **Core delegation engine** — what runs by default | **0 / 36 / 0 / 2** | Background-job supervision (`nohup … >/dev/null 2>&1 &`), the self-locating shell idiom (`$(cd "$(dirname "$0")" && pwd)`), and the single scoped key read. All benign — **zero critical**. |
| **Local-inference shim** — experimental, opt-in | 5 / 0 / 5 / 6 | The shim forwards your prompt to *your own* model server (`OSRC_SHIM_UPSTREAM` defaults to `http://localhost:…`; it binds `127.0.0.1` only). A taint scanner flags any proxy's "input → network sink" — here the sink is your own machine. Runs only if you opt into agentic-local. |
| **Test harness** — dev-only, never runs for users | 2 / 21 / 2 / 18 | Fake-CLI `eval` var-lookup, self-locating `$()`, deliberately-fake `sk-…` fixtures that prove the secret scanner works, and one test copying the env to launch the shim as a subprocess. |

**In plain terms: the tool you install and run has zero critical findings.** Every "critical" flag is
either the opt-in local proxy talking to *your own machine* or a test — no remote exfiltration anywhere.
By behavior, the flags are: background-job output redirection (`nohup`), self-locating `$(cd …)`, one
scoped `OPENROUTER_API_KEY` read, `parity` symlink paths under `~/.claude`, `127.0.0.1`/`localhost`
references, and `eval`/fake-key patterns confined to the test harness (`eval` never appears in the shipped
`outsourcerer.sh`).

**Hardened over prior releases:** the vendor install one-liners were rewritten to
download-then-inspect-then-run (clearing an earlier batch of "curl \| bash" criticals); an image-generation
prompt and a documentation sentence were reworded to drop confirmation-bypass / silent-exec phrasings; and
transient local `.pyc` bytecode was cleared from the working tree (it is git-ignored and never shipped). The
counts above are the raw scanner output — nothing is suppressed via `.forensicsignore` or otherwise.

## Key handling (the important part)

- Provider keys are read **one variable at a time** from `~/.env` with a targeted `grep`
  (`_or_load_key`, `_gm_load_key`), the skill **never** `set -a; . ~/.env` (which would export
  every secret in that file to a third-party model). Only the single key the requested lane needs
  is loaded.
- Keys are **never** written into command-line arguments, tmux buffers, logs, job files, or config.
- The **primary** Gemini/Antigravity lane is **keyless**, it rides your existing Antigravity/Google
  app login via the `agy` CLI. An API key is only needed if you opt into the `gemini`-CLI fallback
  or image generation (`nano-banana`).

## Your repo & what leaves the machine

Outsourcerer routes coding tasks to other models — so the honest question is *what leaves your
machine, and when.* The answer is explicit and enforced:

- **Local lanes send nothing.** `-m ollama:<model>` / `-m local` / `--provider local` route to a
  model running on your own machine — no key is read, no network call is made, nothing leaves the
  building. If you never want a task to touch the cloud, this is the lane.
- **Cloud lanes are gated by a credential hard-block.** Before *any* cloud delegation, Outsourcerer
  refuses the route if a real credential file is in the working tree — `.env`, `.env.*` (templates
  like `.env.example` excepted), `credentials`, `id_rsa`, `id_ed25519`, `.aws/credentials` — at the
  **root or nested** anywhere below it. It names the offending file and stops. This scan runs on
  **every** cloud call (no acknowledgement can skip it) and **fails closed** if it cannot complete.
- **Full disclosure on every cloud dispatch.** You are told the destination lane, that this working
  directory's content leaves the machine over the network, and whether a `:free` route may train on
  your data — *before* it goes. Non-interactive cloud runs refuse unless you explicitly acknowledge
  (`--cloud-ack` / `OSRC_CLOUD_ACK=1`).
- **Secrets are counted, never printed.** Detected credential patterns in a prompt or an injected `--with skills=` file
  surface as a redacted count, never the value, so a warning can't itself leak the key.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository. Please do not file public issues for
security reports.

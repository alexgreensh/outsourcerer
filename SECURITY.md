# Security

Outsourcerer is audited with [repo-forensics](https://github.com/alexgreensh/repo-forensics)
(27 scanners, 500+ behavioral detection patterns) on every release.

## Latest scan

`run_forensics.sh <plugin> --skill-scan` (repo-forensics 2.12.x) → **7 critical, 57 high, 7 medium,
26 low — every finding triaged benign-by-design, no suppressions.** No committed secrets, no *remote*
network exfiltration, no obfuscation, no dynamic code fetch-and-execute. A tool that routes tasks to
other models and supervises background jobs will, by construction, trip a static data-flow scanner on
its own core behavior. Each bucket below **is** that behavior — the raw counts, nothing suppressed:

| Findings | Scanner finding | Why it fires | Verdict |
|---|---|---|---|
| **7× "critical"** (confidence 0.85) | "Tainted Data Reaches Sink" / "Potential Data Exfiltration" | The **local-inference shim** forwards your prompt to *your own* model server: `OSRC_SHIM_UPSTREAM` defaults to `http://localhost:…` and the shim **binds `127.0.0.1` only and refuses other binds**. A taint scanner flags any proxy's "input → network sink"; here the sink is your own machine (5 findings). The other 2 are the shim's **certification test** copying the environment to launch it as a subprocess. Neither is remote exfiltration. | benign, localhost-only |
| 27× HIGH | "Output/stderr suppression with background exec" | `nohup … >/dev/null 2>&1 &` for the background-job supervisor (`bg` / `status` / `watch`). | by-design, job supervision |
| 13× HIGH | "Nested Command Substitution" | `$(cd "$(dirname "$0")" && pwd)` — the script self-locates so it runs from any host. | benign, standard idiom |
| 7× HIGH | "Eval in Shell" | **Test-only**: fake-CLI dynamic-variable lookup and function extraction for isolated unit tests. There is **no `eval` in the shipped `outsourcerer.sh`**. | benign, test scaffolding |
| 5× HIGH | "Accessing Claude configuration" | References host skill dirs (`~/.claude/skills`, `~/.gemini/…`) that `parity` symlinks into. | by-design, documented install paths |
| 3× HIGH | "OpenAI API Key" | **Fake fixtures** in the secret-scan self-tests: deliberately unreal `sk-…` strings used to prove the scanner detects them. | benign, test fixtures |
| 2× HIGH | "Credential-path directive" | Reads the **one** scoped key (`OPENROUTER_API_KEY`) a lane needs — its entire purpose. | by-design, scoped auth |
| 7× MED · 26× LOW | "Environment variable access" / "Hardcoded IP" | Reads config from env (`OSRC_SHIM_UPSTREAM`, `PORT`, …) and references `127.0.0.1` / `localhost`. | benign, config + localhost |

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
- **Secrets are counted, never printed.** Detected credential patterns in a prompt or `--with` file
  surface as a redacted count, never the value, so a warning can't itself leak the key.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository. Please do not file public issues for
security reports.

# Security

Outsourcerer is audited with [repo-forensics](https://github.com/alexgreensh/repo-forensics)
(27 scanners, 500+ behavioral detection patterns) on every release.

## Latest scan

`run_forensics.sh <plugin> --skill-scan` → **0 critical, 18 high, 1 medium, all triaged
benign / by-design.** No committed secrets, no unexpected network exfiltration, no obfuscation,
no dynamic code fetch-and-execute. The findings fall into these expected buckets for a delegation
tool:

| # | Scanner finding | Why it fires | Verdict |
|---|---|---|---|
| ~~17× CRITICAL~~ → **fixed** | "Curl Pipe Bash" / "Pipe to Shell" | Install-guidance strings used to quote each vendor's `curl … \| bash` one-liner. **Hardened**: rewritten to a download-then-inspect-then-run form (`curl … -o install.sh`, inspect, `bash install.sh`), which is both safer advice and clears the pattern. Now **zero**. | resolved |
| HIGH (correlation) | "Credential Theft Pattern", sensitive read + network call in one file | The skill reads its **one** provider key from `~/.env` and calls that provider's API. That is its entire purpose. | by-design, scoped auth |
| HIGH | "Accessing Claude configuration" / "Credential-path directive" | Reads the single scoped key (`OPENROUTER_API_KEY` / `GEMINI_API_KEY`) and references host skill dirs (`~/.claude/skills`, `~/.gemini/antigravity/skills`) that `parity` symlinks into. | by-design, documented install paths |
| HIGH | "Output/stderr suppression with background exec" | `nohup … >/dev/null 2>&1 &` for the background-job watchdog (`bg`/`status`/`watch`). | by-design, job supervision |
| 2× HIGH | "Nested Command Substitution" | `$(cd "$(dirname "$0")" && pwd)`, the script self-locates so it runs from any host. | benign, standard idiom |
| 1× MEDIUM | "Claimable GitHub repo" | The repo 404s until first push; resolves once `alexgreensh/outsourcerer` exists. | transient, resolves on publish |

## Key handling (the important part)

- Provider keys are read **one variable at a time** from `~/.env` with a targeted `grep`
  (`_or_load_key`, `_gm_load_key`), the skill **never** `set -a; . ~/.env` (which would export
  every secret in that file to a third-party model). Only the single key the requested lane needs
  is loaded.
- Keys are **never** written into command-line arguments, tmux buffers, logs, job files, or config.
- The **primary** Gemini/Antigravity lane is **keyless**, it rides your existing Antigravity/Google
  app login via the `agy` CLI. An API key is only needed if you opt into the `gemini`-CLI fallback
  or image generation (`nano-banana`).

## Reporting a vulnerability

Open a private security advisory on the GitHub repository. Please do not file public issues for
security reports.

# The Tab (cost), tab / estimate / suggest / credits

The skill's whole promise is "cheaper than the archmage," so it keeps receipts. Every cc/codex/native
run appends to `~/.outsourcerer/ledger.jsonl`.

```
outsourcerer.sh tab            # cash billed + subscription plan-limit usage, by model
outsourcerer.sh estimate "…"   # quote table across the chain + the Opus counterfactual
outsourcerer.sh suggest        # live cheap & free models available per platform right now
```

**Proactively offer `suggest`** when the user asks "what's cheap/free right now", worries about
keeping up with new models, or is about to run a big offload. It reads each platform's live catalog
(OpenRouter API + Devin CLI), so it tracks the ecosystem as it churns; no hardcoded list to rot. It
ranks by price/availability only (no quality score yet), so pair a cheap pick with `second-opinion`.

The Tab reports **two different costs honestly, because they are not the same thing**:

- **Cash**, real money on OpenRouter/API lanes. Precise per-run cash is captured on the **`bg` path**
  by reading the **exact per-generation cost back from OpenRouter's `/generation` endpoint** (the
  harness's own `total_cost_usd` ran ~28x high on cheap lanes, so it is only a labeled fallback).
  Foreground runs show a **calibrated estimate** (~3.3 chars/token, the Token Optimizer constant, not
  the old char/4 undercount) labeled `est-only`. Run via `bg` to bank a measured number. `doctor`
  shows remaining OpenRouter credits.
- **Plan limits**, the ChatGPT/Claude/Antigravity subscription lanes cost **$0 cash but are not
  free**: they spend your finite 5-hour and weekly windows. For the **ChatGPT-sub (codex-native)**
  lane the Tab reads the real numbers Codex records (`~/.codex/sessions/**/rollout-*.jsonl` →
  `rate_limits.primary`/`secondary`) and prints current 5h/weekly usage + reset ETAs. Claude-sub and
  keyless-Antigravity lanes are counted as subscription runs (no cash) but those hosts don't expose a
  readable per-run quota, so they're reported as plan-metered, not with a fake dollar figure.

Never narrate a subscription run as "$0, free", say "no cash, used N% of your plan window." Token
counts here are estimates unless a provider reported real usage; label them as such.

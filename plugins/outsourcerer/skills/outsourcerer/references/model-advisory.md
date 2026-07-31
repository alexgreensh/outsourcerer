# Model Advisory (`advise`)

The `advise` subcommand answers "which model should I use for this task?" with **data, not
guesses**. It classifies the task, scores every known model against live benchmark data, and
recommends the best value model that meets the capability threshold.

## Usage

```
outsourcerer.sh advise [--refresh] [--json] [--effort LEVEL] "<task prompt>"
```

- `--refresh`: pull fresh benchmark data from the OpenRouter benchmarks API before scoring.
  Needs `OPENROUTER_API_KEY` in `~/.env`. Without this flag, uses cached benchmarks
  (`~/.outsourcerer/benchmarks.json`), or falls back to tier proxy scores if no cache exists.
- `--json`: emit machine-readable JSON instead of the human-readable table. Piped to `jq` for
  script integration.
- `--effort`: include `minimal|low|medium|high|xhigh|max|none` in selection. Hard tasks default
  to `high`; other tasks default to `medium`. `max` requests frontier selection.
- The task prompt is the work you want to do, in natural language. The classifier reads it to
  determine the task category.

## How it works

### 1. Task classification (keyword-based)

The prompt is lowercased and matched against pipe-separated keyword phrases for five categories.
The category with the most distinct keyword hits wins. Ties break: code > reasoning > agentic >
creative > simple. Default (no keyword hits): simple.

| Category | Keywords (sample) | Benchmark field | Threshold |
|---|---|---|---|
| code | function, class method, bug, fix, refactor, implement, compile, error, stack trace, debug, unit test, api endpoint, sql query, regex, algorithm, code review, pull request, merge conflict, lint, docker, kubernetes | `coding_index` | 60 |
| reasoning | analyze, compare, evaluate, assess, critique, reason, prove, derive, tradeoff, implication, consequence, strategy, architect, design system, decision, justify, deduce, infer, mathematical, proof, logical | `intelligence_index` | 45 |
| agentic | agent, tool use, tool call, multi-step, autonomous, execute command, run shell, file system, web search, browser, orchestrat, workflow, pipeline, subagent, delegate, parallel, fanout | `agentic_index` | 35 |
| creative | write a story, write a blog, write an article, essay, creative, generate content, copywriting, headline, tagline, brand voice, narrative, storytelling, poem, screenplay, dialogue | `intelligence_index` | 45 |
| simple | (no keyword hits) | `intelligence_index` | 0 (no floor) |

The threshold is the minimum benchmark score a model must have to be recommended. Models below
the threshold are listed but marked "below threshold" and excluded from the recommendation.

### 2. Scoring (value ratio)

For each model in the alias table (`OSRC_MODEL_TABLE`), the advisory:

1. Looks up the model in the benchmark data by resolved ID. Native subscription models
   (fable/opus/sonnet/haiku/sol/terra/luna/gpt-5.5/gemini-pro/gemini-flash/glm-5.2) are mapped
   to their OpenRouter benchmark permaslug prefix via `_NATIVE_BENCH_MAP`, because their
   resolved IDs don't appear directly in the OR catalog.
2. Extracts the relevant benchmark score (coding_index for code tasks, agentic_index for
   agentic tasks, intelligence_index for everything else) and pricing (prompt + completion
   per token).
3. Applies the task difficulty, requested effort, capability tier, and local outcome history to
   the benchmark score. Capable models receive a value preference; Kimi K3 receives a hard-work
   near-frontier adjustment; explicit frontier requirements outweigh those adjustments.
4. Calculates the **value ratio** = score / max(cost_per_m_input, 0.01). Free models (cost=0)
   are floored to $0.01/M so they rank high but don't dominate infinitely.
5. Subscription lanes (cx/cc/dv/gm) have their price set to $0 BEFORE the value ratio
   calculation, because the user pays plan limits, not per-token. This ensures subscription
   models rank by capability, not by their OpenRouter list price.

### 3. Recommendation

The recommendation is the capable-tier model with the best value ratio among models meeting the
threshold. A frontier is selected when effort is `max` or the task explicitly requires frontier
handling. If neither preferred cohort clears the threshold, selection falls back to the best
qualifying subscription or paid candidate, then the highest score overall.

### 4. Graceful degradation

| Tier | Data available | Behavior |
|---|---|---|
| 1 | OR benchmarks cache (`~/.outsourcerer/benchmarks.json`) | Real scores + real pricing. Most accurate. |
| 2 | OR models cache (`~/.outsourcerer/models.json`) only | Tier proxy scores + real pricing. Rough but usable. |
| 3 | No caches at all | Tier proxy scores only. Coarse but always works. |

Tier proxy scores: frontier=55, capable=50, mid=40, budget=30. These are rough capability
estimates based on the model's tier classification, not real benchmarks. Run `advise --refresh`
to get to tier 1.

## Data source

The OpenRouter benchmarks API (`/api/v1/benchmarks`), sourced from Artificial Analysis
(artificialanalysis.ai). Returns `intelligence_index`, `coding_index`, `agentic_index`, and
pricing for ~100 models. Updated daily. Needs `OPENROUTER_API_KEY` in `~/.env`.

No other data sources in v1. The OR benchmarks API covers all models in the alias table, is
fresh (daily), and requires no additional dependencies. LMArena Elo scores and CloudPrice
cross-referencing are deferred to v2.

## Output format

### Human-readable (default)

```
== outsourcerer advise ==
   task: refactor the authentication module to use JWT tokens
   category: code
   difficulty: normal
   effort: medium
   scoring by: coding_index (threshold: 60)
   benchmark data: live (OpenRouter, 2026-07-14T12:00:13.353Z)

--- recommendation ---
   model: glm-5.2 (glm-5.2)
   lane:  dv
   why:   best capable-tier value (meets code threshold 60, effort medium)

--- all candidates (sorted by value ratio, >> = recommended) ---
>> glm-5.2          glm-5.2                      lane=dv  score=76.8  $/M=plan limits    ratio=7680.00 OK
   sol              gpt-5.6-sol                  lane=cx  score=77.4  $/M=plan limits    ratio=7740.00 OK
   ...

Run with:  outsourcerer.sh run -m glm-5.2 --effort medium "refactor the authentication module to use JWT tokens"
Override:  outsourcerer.sh run -m <any-model> --effort medium "..."   (you know better, pick your own)
```

### JSON (`--json`)

```json
{
  "task": "refactor the authentication module to use JWT tokens",
  "category": "code",
  "difficulty": "normal",
  "effort": "medium",
  "score_field": "coding_index",
  "threshold": "60",
  "recommendation": {
    "alias": "glm-5.2",
    "model": "glm-5.2",
    "lane": "dv",
    "tier": "capable",
    "reason": "best capable-tier value (meets code threshold 60, effort medium)"
  },
  "benchmark_data_available": true
}
```

## Relationship to other subcommands

| Subcommand | Question it answers |
|---|---|
| `advise` | "Which model should I use for THIS task?" (data-backed, task-aware) |
| `suggest` | "What's cheap or free right now?" (price/availability only, no quality scoring) |
| `estimate` | "What will this cost across the chain?" (cost quote table) |
| `models` | "What's live on Devin right now?" (live catalog) |

Use `advise` when you want a recommendation with reasoning. Use `suggest` when you just want
the cheapest option. Use `estimate` when you already know the model and want a cost quote.

## Limitations (v1)

- **Keyword classification, not ML**: handles 90% of cases well but misses subtle distinctions
  (e.g. "write a test" is code not creative). Acceptable for v1, an ML classifier would add
  latency and cost for marginal gains.
- **No verify-then-escalate**: the advisory recommends a model but doesn't verify the output
  was good enough. Verification is a future feature.
- **Single data source**: OR benchmarks only. Multi-source (LMArena, CloudPrice) deferred to v2.
- **Subscription lane cost is qualitative**: subscription models (cx/cc/dv/gm) show "$0 (plan)"
  because the user pays plan limits, not per-token. The value ratio treats them as free, which
  is correct for the user's wallet but doesn't account for plan-limit exhaustion.

# Model advisory

Run `outsourcerer.sh advise [--json] [--refresh] [--effort LEVEL] "task"`.

Code and tool-use tasks use Artificial Analysis engineering scores. Older caches can
supply the corresponding coding or agentic index. Other tasks use intelligence.
A single OpenRouter intelligence benchmark refresh supplies all indices.

The bar is a share of the best score among models you can run now: 75% for light
tasks, 85% for normal tasks, 97% for hard or maximum-effort tasks (override with
OSRC_ADVISE_BAR_LIGHT, OSRC_ADVISE_BAR_NORMAL, OSRC_ADVISE_BAR_HARD). Measuring against
the best runnable model, not the whole catalog, keeps old weak models from lowering it.
Each measured model counts once across eligible lanes. Among qualifying models, the highest score per dollar wins.
Prices are dollars per million tokens, assuming equal input and output volumes.
Subscription models use the same list price as other models because usage consumes
plan limits. Cash dispatch retains its consent check.

Candidates come from CLI catalogs, the OpenRouter models cache and models.local.
The shortlist includes missing measurements and prices so coverage can be audited.

In JSON, `candidates` contains every eligible catalog row and the missing-source
details. `shortlist` contains only measured, priced rows that clear the bar, in
dispatch order. With no qualifying row, `recommendation` is null. A published
zero-price OpenRouter endpoint has unlimited value per dollar. Missing rates
stay unknown. For equal score and value on the same release, the router prefers
a plan lane, then OpenRouter, then an unknown-cost lane. Set
`OSRC_ADVISE_ROUTER=0` to retain discovery order for these ties.

Discovery reads cached CLI inventories. `OSRC_ADVISE_DYNAMIC_POOL=0` limits
discovery to models.local. `OSRC_ADVISE_DYNAMIC_MAX` caps OpenRouter discovery,
highest measured scores first. Explicit refresh updates the benchmark cache.
Without that flag, a stale cache or missing index triggers a refresh when a key
is available. Benchmark record prices take precedence, with OpenRouter's model
catalog supplying missing prices and the exact rate for free endpoints.

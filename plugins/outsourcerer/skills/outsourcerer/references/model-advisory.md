# Model advisory

Run `outsourcerer.sh advise [--json] [--refresh] [--effort LEVEL] "task"`.
Coding tasks use the OpenRouter coding index. Multi-step tool use uses the agentic index.
Reasoning, creative and simple tasks use the intelligence index.

The recommendation and fallback shortlist use the same ranking. Each score comes from
the cached benchmark for that model and category. Within `OSRC_ADVISE_TIE` points
(default 1.0) of the best remaining score, lane headroom and lower input cost can
break the tie. A lighter measured Devin sibling can break a tie at the same cost. Set the window to 0 for strict score order. Thresholds describe the
result. Effort sets the requested execution effort, including max.

The shortlist includes configured aliases and measured models from cached catalogs.
Configured models missing the requested score appear last, marked **unscored**.
JSON reports their score as null. Catalog-only entries missing that score are
counted in `unscored_catalog_count`. If no candidate has a measurement the reason says so.

Excluded models and lanes over their fresh usage limit are skipped. Selecting a paid
model preserves the normal dispatch consent checks. A cache older than seven days
is refreshed when an OpenRouter key is available, as is a cache missing the requested
index entirely. Coding and agentic refreshes use separate cache files. Use
`--refresh` to request an update.

Set `OSRC_ADVISE_DYNAMIC_POOL=0` to use only the configured table. An explicit
`OSRC_ADVISE_DYNAMIC_MAX` caps OpenRouter discovery, measured models first.
The default includes the whole catalog. Native discovery reads the agy model list,
the Codex model cache, and Devin catalog variants. It does not launch a model.

A coding recommendation reads
`picked X: highest coding score (78.8) among models you can run now`.
JSON includes the selected benchmark field, shortlist, coverage, stale-cache flag,
and the reason for skipping a model or lane. A measured zero counts as a score.

Use `suggest` to find inexpensive options, `estimate` for a cost quote, and
`models` to inspect the Devin catalog.

## Task classification and effort

The classifier counts distinct keyword matches. A prompt with a code signal and at
least two agentic signals uses the agentic index. For example, “fix the bug, run the
test suite, verify the fix” describes an edit-and-test workflow. Otherwise the most
matches win. A prompt with no matches is classified as simple.

The default threshold is 60 for coding, 35 for agentic tasks, 45 for reasoning or
creative work, and 0 for simple tasks. The shortlist's `meets` field reports whether a
measured score clears that threshold. Even below threshold, the best measured
candidate is eligible. Hard tasks default to high effort and other tasks to medium.

Set `OSRC_ADVISE_CONSERVE=0` to disable the headroom tiebreaker or
`OSRC_ADVISE_VARIANT_PREF=0` to disable lighter-sibling preference. When a model
runs on several lanes, the existing lane router can select a cheaper eligible lane
for the same model. `OSRC_ADVISE_ROUTER=0` keeps the ranked lane.

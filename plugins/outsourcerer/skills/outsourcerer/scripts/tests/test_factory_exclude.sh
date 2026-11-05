#!/usr/bin/env bash
# test_factory_exclude.sh — issue #45: a persistent model exclude list.
# `exclude add|rm|ls|clear|check`, robust family matching, refusal of an explicit -m on every verb,
# and every automatic choice skipping excluded models. Fake CLIs only: no real model is ever called.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-factory-exclude.XXXXXX")"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Fake model CLIs: each records that it was invoked. A refusal must leave this log empty.
FB="$TMP/fake-bin"; mkdir -p "$FB"; CALLS="$TMP/calls.log"
for c in claude codex devin agy gemini droid cursor-agent oz cline hermes; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\necho PONG\nexit 0\n' "$c" "$CALLS" > "$FB/$c"; chmod +x "$FB/$c"
done
export PATH="$FB:$PATH"
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
export OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_NO_ADVISE=1 OSRC_BRIEF_NO_HEAL=1 OSRC_DOCTOR_OFFLINE=1
unset OSRC_EXCLUDE_MODELS OSRC_MODEL_DENYLIST OSRC_SECOND_OPINION_MODELS OSRC_SECOND_OPINION_PREMIUM OSRC_ESCALATE_LADDER OR_OFFLOAD_CHAIN 2>/dev/null || true

run() { bash "$SRC" "$@"; }
# lib <snippet>: source the script (main suppressed) and run a snippet in that shell.
lib() { OSRC_SOURCED=1 bash -c 'src="$1"; code="$2"; set --; . "$src" >/dev/null 2>&1; eval "$code"' bash "$SRC" "$1"; }

# ---------------------------------------------------------------- CLI: add / ls / rm / clear
out="$(run exclude ls 2>&1)"
printf '%s' "$out" | grep -q 'no models excluded' && ok "exclude ls on an empty list says so" || bad "empty ls: $out"
out="$(run exclude add Fable 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qx 'fable' "$OSRC_HOME/exclude" && ok "exclude add stores the entry lowercased in \$OSRC_HOME/exclude" || bad "add: rc=$rc $out"
out="$(run exclude add fable 2>&1)"
[ "$(grep -c . "$OSRC_HOME/exclude")" = 1 ] && printf '%s' "$out" | grep -q 'already excluded' && ok "exclude add is idempotent" || bad "duplicate add: $out"
out="$(run exclude add '5' 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'no letters' && ok "an entry with no letters is refused (would exclude half the catalog)" || bad "digit entry accepted: $out"
out="$(run exclude add 'fa;ble' 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "an entry with shell metacharacters is refused" || bad "metachar entry accepted: $out"
out="$(OSRC_EXCLUDE_MODELS="glm, Haiku" run exclude ls 2>&1)"
printf '%s' "$out" | grep -q '^  fable$' && printf '%s' "$out" | grep -q 'haiku.*OSRC_EXCLUDE_MODELS' \
  && ok "exclude ls unions the saved list with OSRC_EXCLUDE_MODELS and labels the source" || bad "ls union: $out"
run exclude add opus >/dev/null 2>&1
out="$(run exclude rm OPUS 2>&1)"
grep -qx opus "$OSRC_HOME/exclude" && bad "rm left the entry: $out" || { grep -qx fable "$OSRC_HOME/exclude" && ok "exclude rm removes one entry (case-insensitive) and keeps the rest" || bad "rm dropped other entries"; }
out="$(OSRC_EXCLUDE_MODELS=sol run exclude rm sol 2>&1)"
printf '%s' "$out" | grep -q 'still excluded by the OSRC_EXCLUDE_MODELS' && ok "exclude rm warns when the env var still excludes it" || bad "rm env note: $out"
cp "$OSRC_HOME/exclude" "$TMP/exclude.bak"
out="$(run exclude clear 2>&1)"
[ ! -f "$OSRC_HOME/exclude" ] && ok "exclude clear removes the saved list" || bad "clear: $out"
cp "$TMP/exclude.bak" "$OSRC_HOME/exclude"
out="$(run exclude bogus 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'unknown action' && ok "unknown exclude action fails with the usage" || bad "bogus action: $out"

# ---------------------------------------------------------------- matcher
chk() { run exclude check "$1" >/dev/null 2>&1; }
allm=1
for m in fable FABLE Fable claude-fable-5 claude-fable-5-1 anthropic/claude-5-fable 'claude-fable-5-1[1m]'; do
  chk "$m" || { allm=0; bad "family 'fable' did not match $m"; }
done
[ "$allm" = 1 ] && ok "family entry 'fable' matches fable, claude-fable-5, claude-fable-5-1, anthropic/claude-5-fable, any case, [1m] suffix"
nonm=1
for m in opus sonnet haiku sol glm claude-opus-4-8 gpt-5.6-sol; do chk "$m" && { nonm=0; bad "fable entry wrongly matched $m"; }; done
[ "$nonm" = 1 ] && ok "family entry 'fable' leaves other models allowed"
OSRC_EXCLUDE_MODELS='gpt-5.6-*' bash "$SRC" exclude check sol >/dev/null 2>&1 && OSRC_EXCLUDE_MODELS='gpt-5.6-*' bash "$SRC" exclude check terra >/dev/null 2>&1 \
  && ! OSRC_EXCLUDE_MODELS='gpt-5.6-*' bash "$SRC" exclude check gpt-5.5 >/dev/null 2>&1 \
  && ok "a glob entry matches through alias resolution (sol -> gpt-5.6-sol) and stays precise" || bad "glob matching"
( export OSRC_HOME="$TMP/state2"; mkdir -p "$OSRC_HOME"
  ! OSRC_EXCLUDE_MODELS=claude-fable-5 bash "$SRC" exclude check claude-fable-5-1 >/dev/null 2>&1 \
    && OSRC_EXCLUDE_MODELS='claude-fable-5*' bash "$SRC" exclude check claude-fable-5-1 >/dev/null 2>&1 \
    && ! OSRC_EXCLUDE_MODELS=claude-fable-5 bash "$SRC" exclude check claude-opus-5 >/dev/null 2>&1 ) \
  && ok "an exact id entry leaves point releases and other families allowed (a glob covers point releases)" || bad "exact id matching"
( export OSRC_HOME="$TMP/state2"
  OSRC_EXCLUDE_MODELS=glm bash "$SRC" exclude check z-ai/glm-5.2 >/dev/null 2>&1 \
    && OSRC_EXCLUDE_MODELS=sol bash "$SRC" exclude check gpt-5.6-sol >/dev/null 2>&1 \
    && ! OSRC_EXCLUDE_MODELS=5 bash "$SRC" exclude check glm-5.2 >/dev/null 2>&1 ) \
  && ok "alias entries match their resolved ids; a letterless env entry is ignored" || bad "alias/letterless matching"
r="$(lib '_exclude_active && echo active || echo idle' 2>/dev/null)"
r2="$(OSRC_HOME="$TMP/empty-state" OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; _exclude_active && echo active || echo idle; _model_excluded fable && echo hit || echo miss' bash "$SRC" 2>/dev/null | tr '\n' ' ')"
[ "$r" = active ] && [ "$r2" = "idle miss " ] && ok "no list -> nothing excluded (default routing untouched)" || bad "active/idle: '$r' '$r2'"

# ---------------------------------------------------------------- explicit -m refused on every verb
refused() { # <label> <cmd...>
  local label="$1"; shift; : > "$CALLS"
  local o rc; o="$("$@" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && printf '%s' "$o" | grep -q "you excluded" && printf '%s' "$o" | grep -q 'exclude rm fable' && [ ! -s "$CALLS" ]; then
    ok "$label: refused with one plain line naming the fix; no model CLI ran"
  else
    bad "$label: rc=$rc calls=$(cat "$CALLS" 2>/dev/null | head -2) out=$(printf '%s' "$o" | tail -3)"
  fi
}
refused "run -m fable"                       run run -m fable "hello"
refused "research -m claude-fable-5"         run research -m claude-fable-5 "hello"
refused "edit -m Claude-Fable-5-1"           run edit -m Claude-Fable-5-1 "hello"
refused "yolo -m fable"                      run yolo -m fable "hello"
refused "explore --provider cc -m fable"     run explore --provider cc -m fable "hello"
refused "bg run -m fable"                    run bg run -m fable "hello"
refused "bg -m fable (verb implied)"         run bg -m fable "hello"
refused "fanout -m fable"                    run fanout -m fable -- "a" "b"
refused "fanout --route task*=fable"         run fanout --route 'task*=fable' -- "a"
refused "loop verify -m fable"               run loop verify -m fable --check true "task"
refused "loop escalate -m fable"             run loop escalate -m fable --check true "task"
refused "loop escalate --ladder haiku,fable" run loop escalate --ladder haiku,fable --check true "task"
refused "second-opinion -m glm,fable"        run second-opinion -m glm,fable "question"
refused "continue -m fable"                  run continue -m fable "next"
if command -v tmux >/dev/null 2>&1; then
  refused "session start -m fable"           run --provider cc session start -m fable
  refused "session model fable"              run session model fable
else
  ok "session start/model: tmux absent here, refusal path covered by parse_model (shared with continue)"
fi
( mkdir -p "$TMP/repo" && cd "$TMP/repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) >/dev/null 2>&1
refused "crew -m fable" bash -c 'cd "$1" && shift && bash "$@"' bash "$TMP/repo" "$SRC" crew -m fable --check true -- "task"
[ -z "$(cd "$TMP/repo" && git worktree list | sed -n 2p)" ] && ok "crew refusal happens before any worktree is created" || bad "crew created a worktree before refusing"
# env-only exclusion is enforced the same way
mv "$OSRC_HOME/exclude" "$TMP/exclude.hold"
: > "$CALLS"; o="$(OSRC_EXCLUDE_MODELS=fable run run -m fable "hi" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$o" | grep -q "you excluded 'fable'" && [ ! -s "$CALLS" ] && ok "OSRC_EXCLUDE_MODELS alone refuses -m too" || bad "env-only refusal: $o"
mv "$TMP/exclude.hold" "$OSRC_HOME/exclude"
# an allowed model still routes (exclusion is not a blanket block)
o="$(run run -m opus "hi" 2>&1)"
printf '%s' "$o" | grep -q "you excluded" && bad "opus was wrongly refused: $o" || ok "an allowed model is not refused"

# ---------------------------------------------------------------- provider defaults (automatic choice)
: > "$CALLS"; o="$(OSRC_EXCLUDE_MODELS=glm run --provider devin run "hi" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$o" | grep -q 'default model for --provider devin' && [ ! -s "$CALLS" ] \
  && ok "a provider's built-in default that is excluded is refused with the fix, never run" || bad "provider default: $o"

# ---------------------------------------------------------------- automatic choices skip excluded
r="$(OR_OFFLOAD_CHAIN='z-ai/glm-5.2,anthropic/claude-5-fable,deepseek/deepseek-v4-pro' lib 'MODEL_EXPLICIT=0; _or_chain auto' 2>/dev/null)"
[ "$r" = "z-ai/glm-5.2 deepseek/deepseek-v4-pro" ] && ok "OpenRouter chain drops excluded rungs" || bad "or chain: '$r'"
o="$(OR_OFFLOAD_CHAIN='anthropic/claude-5-fable' lib 'MODEL_EXPLICIT=0; _or_chain auto; echo survived' 2>&1)"
printf '%s' "$o" | grep -q 'every model in the OpenRouter chain' && ! printf '%s' "$o" | grep -q survived \
  && ok "an all-excluded OpenRouter chain stops with a clear message" || bad "all-excluded chain: $o"
r="$(lib '_fallback_lane_ready() { return 0; }; _fallback_pick "" "fable|fable|cc
opus|opus|cc"' 2>/dev/null)"
[ "$r" = "opus|opus|cc" ] && ok "fallback shortlist pick skips an excluded candidate" || bad "fallback pick: '$r'"
r="$(lib '_model_denied fable && echo denied; _model_denied claude-opus-4-8 && echo bad || echo allowed' 2>/dev/null | tr '\n' ' ')"
[ "$r" = "denied allowed " ] && ok "_model_denied (failover lane check + advise + route choke point) honors the exclude list" || bad "_model_denied: '$r'"
r="$(lib '_lane_down_active() { return 1; }; _fallback_lane_ready() { return 0; }; _lane_ready_probe() { return 0; }; _failover_lane_ok cc run fable && echo ok || echo refused' 2>/dev/null)"
[ "$r" = refused ] && ok "cross-harness failover refuses an excluded model on a ready lane" || bad "failover lane ok: '$r'"
o="$(lib '_escalate_ladder "" ""' 2>&1)"
printf '%s' "$o" | grep -q '^fable$' && bad "escalate ladder kept fable: $o" \
  || { printf '%s' "$o" | grep -q 'dropping ladder rung fable' && ok "escalate default ladder drops the excluded rung, out loud" || bad "ladder notice: $o"; }
: > "$OSRC_HOME/benchmarks.json"
r="$(OSRC_BENCH_JSON="$OSRC_HOME/benchmarks.json" run advise --json --effort max "architect a hard distributed consensus redesign with deep reasoning" 2>/dev/null)"
if printf '%s' "$r" | jq -e '.recommendation.alias' >/dev/null 2>&1; then
  printf '%s' "$r" | jq -r '.recommendation.alias, .recommendation.model, (.shortlist[] | .alias, .model)' | grep -qi fable \
    && bad "advise --json still lists a fable model" || ok "advise --json (recommendation + shortlist) never contains an excluded model"
else bad "advise --json produced no JSON: $(printf '%s' "$r" | head -c 300)"; fi
r="$(OSRC_BENCH_JSON="$OSRC_HOME/benchmarks.json" run advise --effort max "architect a hard distributed consensus redesign" 2>&1)"
printf '%s' "$r" | grep -qi fable && bad "advise text lists fable" || ok "advise text output never names an excluded model"

# second-opinion: default premium judge (fable) swaps to the next allowed premium and says so
SO='_so_run() { echo "$1" >> "$SOLOG"; echo "answer from $1 $RANDOM"; }; _so_agree() { return 1; }; record_ledger() { :; }
_autodetach_should() { return 1; }; _confident_fail() { return 1; }; _so_resolve() { printf "%s|cc|frontier\n" "$1"; }
second_opinion "is the sky blue"'
SOLOG="$TMP/so.log"; export SOLOG; : > "$SOLOG"
o="$(lib "$SO" 2>&1)"
printf '%s' "$o" | grep -q 'premium judge fable is on your exclude list' && grep -qx opus "$SOLOG" && ! grep -q fable "$SOLOG" \
  && ok "second-opinion premium falls back fable -> opus and says so" || bad "so premium: $(cat "$SOLOG" | tr '\n' ' ') $o"
: > "$SOLOG"
o="$(OSRC_EXCLUDE_MODELS=sol lib "$SO" 2>&1)"
printf '%s' "$o" | grep -q 'sol is on your exclude list' && ! grep -qx sol "$SOLOG" \
  && ok "second-opinion default pair swaps an excluded comparison model" || bad "so pair: $(cat "$SOLOG" | tr '\n' ' ') $o"
: > "$SOLOG"
o="$(OSRC_EXCLUDE_MODELS='opus terra gemini-pro sol' lib "$SO" 2>&1)"; rc=$?
printf '%s' "$o" | grep -q 'every fallback judge are on your exclude list' && ! grep -qE '^(fable|opus)$' "$SOLOG" \
  && ok "second-opinion stops clearly when every premium judge is excluded" || bad "so all excluded: $o"

# ---------------------------------------------------------------- suggest hides excluded models
printf '%s' '{"data":[{"id":"anthropic/claude-5-fable","created":9,"context_length":200000,"pricing":{"prompt":"0","completion":"0"}},{"id":"z-ai/glm-5.2","created":8,"context_length":200000,"pricing":{"prompt":"0","completion":"0"}},{"id":"anthropic/claude-fable-5-1","created":7,"context_length":1000,"pricing":{"prompt":"0.00001","completion":"0.00002"}}]}' > "$OSRC_HOME/models.json"
o="$(PATH="$FB:/usr/bin:/bin:$(dirname "$(command -v jq)")" run suggest 2>&1)"
printf '%s' "$o" | grep -q 'z-ai/glm-5.2' && ! printf '%s' "$o" | grep -qi 'fable' \
  && ok "suggest/deals hides excluded models (OpenRouter rows + subscription line)" || bad "suggest: $o"

# ---------------------------------------------------------------- brief + doctor show the list
o="$(run brief 2>&1)"
printf '%s' "$o" | grep -q '^excluded    : fable' && ok "brief prints the active exclusions (sticks across sessions)" || bad "brief: $(printf '%s' "$o" | head -20)"
o="$(run doctor 2>&1)"
printf '%s' "$o" | grep -q 'excluded    : fable' && ok "doctor prints the active exclusions" || bad "doctor: $(printf '%s' "$o" | grep -i exclu)"
o="$(OSRC_HOME="$TMP/empty-state" run doctor 2>&1)"
printf '%s' "$o" | grep -q 'excluded models: none' && ok "doctor says none when nothing is excluded" || bad "doctor none"

# ================================================================ REVIEW-2 findings (one block each)
# Every block below runs against its own state home so the saved list above never leaks in.
xh() { local d="$TMP/xh-$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
xc() { bash "$SRC" exclude check "$1" >/dev/null 2>&1; }   # rc0 = excluded

# ---- #45 exact scenario: `exclude add claude-fable-5`, the user has no Fable subscription
(
  export OSRC_HOME; OSRC_HOME="$(xh s45)"
  bash "$SRC" exclude add claude-fable-5 >/dev/null 2>&1
  r=0
  : > "$CALLS"; o="$(bash "$SRC" run -m fable "hi" 2>&1)"
  printf '%s' "$o" | grep -q "you excluded 'fable' (exclude list entry: claude-fable-5; fable runs claude-fable-5-1 today, a point release of claude-fable-5)" && [ ! -s "$CALLS" ] || { echo "  -m fable: $o"; r=1; }
  # -m claude passes the alias check, then Devin's live catalog resolves it to a Fable id: refused there.
  o="$(OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1
    _devin_with_prepare() { DEVIN_WITH_PRE=""; }; need_devin() { :; }; _catalog_validate() { :; }
    _devin_guard_before_delegation() { :; }; _devin_resolve_dynamic() { [ "$1" = claude ] && printf claude-fable-5-high; }
    devin() { echo "devin $*" >> "$2"; }
    delegate auto "" -m claude "hi"; echo survived' bash "$SRC" "$CALLS" 2>&1)"
  printf '%s' "$o" | grep -q "'claude' resolves to claude-fable-5-high, which you excluded" && ! printf '%s' "$o" | grep -q survived && [ ! -s "$CALLS" ] || { echo "  -m claude: $o"; r=1; }
  # second-opinion default premium judge is fable -> swapped, never run
  : > "$SOLOG"; o="$(lib "$SO" 2>&1)"
  printf '%s' "$o" | grep -q 'premium judge fable is on your exclude list (claude-fable-5)' && ! grep -qi fable "$SOLOG" || { echo "  so: $o"; r=1; }
  # claude-native session without -m: Claude Code's own default could be Fable -> refused
  o="$(env -u ANTHROPIC_MODEL OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; MODEL_EXPLICIT=0; _exclude_session_default_guard cc; echo survived' bash "$SRC" 2>&1)"
  printf '%s' "$o" | grep -q 'runs Claude Code.s own default model' && printf '%s' "$o" | grep -q 'covers fable' && ! printf '%s' "$o" | grep -q survived || { echo "  session: $o"; r=1; }
  exit "$r"
) && ok "#45: exclude add claude-fable-5 refuses -m fable, -m claude (Devin -> Fable id), the second-opinion fable judge and a no -m claude session" || bad "#45 exact scenario"

# ---- F1: canonical identity (alias <-> exact id <-> provider-prefixed id <-> family word)
(
  export OSRC_HOME; OSRC_HOME="$(xh f1)"
  OSRC_EXCLUDE_MODELS=claude-fable-5 xc anthropic/claude-5-fable && OSRC_EXCLUDE_MODELS=claude-fable-5 xc claude-fable-5-high \
  && OSRC_EXCLUDE_MODELS=anthropic/claude-5-fable xc fable && OSRC_EXCLUDE_MODELS=anthropic/claude-5-fable xc claude-fable-5 \
  && ! OSRC_EXCLUDE_MODELS=claude-opus-5 xc opus && OSRC_EXCLUDE_MODELS=claude-opus-5-5 xc opus \
  && OSRC_EXCLUDE_MODELS=claude xc fable && OSRC_EXCLUDE_MODELS=claude xc opus && OSRC_EXCLUDE_MODELS=claude xc sonnet && OSRC_EXCLUDE_MODELS=claude xc haiku \
  && ! OSRC_EXCLUDE_MODELS=claude xc claudex && ! OSRC_EXCLUDE_MODELS=claude xc gpt-5.5 \
  && OSRC_EXCLUDE_MODELS=z-ai/glm-5.2 xc glm-5.2 && OSRC_EXCLUDE_MODELS=z-ai/glm-5.2 xc glm-5-2 && OSRC_EXCLUDE_MODELS=z-ai/glm-5.2 xc glm \
  && ! OSRC_EXCLUDE_MODELS=z-ai/glm-5.2 xc glm-5.3 && ! OSRC_EXCLUDE_MODELS=claude-fable-5 xc opus
) && ok "F1: exact ids, provider-prefixed ids, bare family aliases and 'claude' all match their canonical model" || bad "F1 canonical identity"

# ---- F2: a malformed entry fails CLOSED with a warning; [1m] entries; add rejects unparsable entries
(
  export OSRC_HOME; OSRC_HOME="$(xh f2)"
  o="$(OSRC_EXCLUDE_MODELS='gpt-[,fable' bash "$SRC" exclude check opus 2>&1)"; rc=$?
  [ "$rc" = 0 ] && printf '%s' "$o" | grep -q "'gpt-\[' is not a valid model name" && printf '%s' "$o" | grep -q 'fail closed' || { echo "  bad entry: rc=$rc $o"; exit 1; }
  OSRC_EXCLUDE_MODELS='gpt-[,fable' xc fable || exit 1
  OSRC_EXCLUDE_MODELS='claude-fable-5[1m]' xc claude-fable-5 || exit 1
  ! OSRC_EXCLUDE_MODELS='claude-fable-5[1m]' xc opus || exit 1
  o="$(bash "$SRC" exclude add 'gpt-[' 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ ! -f "$OSRC_HOME/exclude" ] || { echo "  add gpt-[: $o"; exit 1; }
  bash "$SRC" exclude add 'Claude-Fable-5[1m]' >/dev/null 2>&1 && grep -qx 'claude-fable-5' "$OSRC_HOME/exclude" || { echo "  add [1m]: $(cat "$OSRC_HOME/exclude")"; exit 1; }
  # a hand-edited bad line in the saved file fails closed too, and ls flags it
  printf 'fable\nbad[entry\n' > "$OSRC_HOME/exclude"
  xc gpt-5.6-sol || exit 1
  bash "$SRC" exclude ls 2>&1 | grep -q 'bad\[entry.*NOT A VALID MODEL NAME' || exit 1
) && ok "F2: a malformed entry fails closed (warns, refuses every model), [1m] entries work, exclude add rejects unparsable entries" || bad "F2 malformed entries"

# ---- F3: the id an alias RESOLVES to is re-checked (Devin catalog, continue, agy family pick)
(
  export OSRC_HOME; OSRC_HOME="$(xh f3)"
  r=0
  o="$(OSRC_EXCLUDE_MODELS=kimi-k9 OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1
    _devin_with_prepare() { DEVIN_WITH_PRE=""; }; need_devin() { :; }; _catalog_validate() { :; }
    _devin_guard_before_delegation() { :; }; _devin_resolve_dynamic() { [ "$1" = kimi ] && printf kimi-k9; }
    devin() { echo ran; }
    delegate auto "" -m kimi "hi"; echo survived' bash "$SRC" 2>&1)"
  printf '%s' "$o" | grep -q "'kimi' resolves to kimi-k9, which you excluded" && ! printf '%s' "$o" | grep -qE 'survived|^ran' || { echo "  delegate: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=kimi-k9 OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1
    need_devin() { :; }; _devin_guard_before_delegation() { :; }; _devin_resolve_dynamic() { [ "$1" = kimi ] && printf kimi-k9; }
    devin() { echo ran; }
    continue_turn -m kimi "next"; echo survived' bash "$SRC" 2>&1)"
  printf '%s' "$o" | grep -q "continue: 'kimi' resolves to kimi-k9" && ! printf '%s' "$o" | grep -qE 'survived|^ran' || { echo "  continue: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=gemini-3.4-pro OSRC_AGY_PRO_DEFAULT=gemini-3.4-pro OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1
    _exclude_refuse_resolved gemini-pro "$(_agy_model_token gemini-pro)"; echo survived' bash "$SRC" 2>&1)"
  printf '%s' "$o" | grep -q "'gemini-pro' resolves to gemini-3.4-pro" && ! printf '%s' "$o" | grep -q survived || { echo "  agy: $o"; r=1; }
  # every resolver dispatch site carries the second gate
  for site in '_exclude_refuse_resolved "$id" "$atok"' '_exclude_refuse_resolved "$_gid_req" "$id"' '_exclude_refuse_resolved "$MODEL" "$_dvmodel"' '_exclude_refuse_resolved "$_lreq" "$id"' '_exclude_refuse_resolved "$_sreq" "$MODEL" "session start"'; do
    grep -qF -- "$site" "$SRC" || { echo "  missing gate: $site"; r=1; }
  done
  exit "$r"
) && ok "F3: Devin live-catalog, continue and agy family resolution re-check the final id (kimi -> kimi-k9, gemini-pro -> dated id)" || bad "F3 resolved-id gate"

# ---- F4: version-prefix over-match (a sibling release is never wrongly blocked)
(
  export OSRC_HOME; OSRC_HOME="$(xh f4)"
  ! OSRC_EXCLUDE_MODELS=claude-sonnet-5 xc claude-sonnet-5-5 && OSRC_EXCLUDE_MODELS=claude-sonnet-5 xc claude-sonnet-5 \
  && ! OSRC_EXCLUDE_MODELS=claude-opus-5 xc claude-opus-5-5 && OSRC_EXCLUDE_MODELS=claude-opus-5 xc claude-opus-5-high \
  && ! OSRC_EXCLUDE_MODELS=gpt-5.5 xc gpt-5.5-mini && OSRC_EXCLUDE_MODELS=gpt-5.5 xc openai/gpt-5.5 \
  && OSRC_EXCLUDE_MODELS=claude-haiku-4-5 xc claude-haiku-4-5-20251001 \
  && ! OSRC_EXCLUDE_MODELS=gemini-flash xc gemini-flash-lite && OSRC_EXCLUDE_MODELS=gemini-flash xc gemini-3.5-flash \
  && OSRC_EXCLUDE_MODELS='gpt-5.6' xc sol && ! OSRC_EXCLUDE_MODELS='gpt-5.6' xc gpt-5.6-mini \
  && OSRC_EXCLUDE_MODELS=sonnet xc claude-sonnet-5-5
) && ok "F4: claude-sonnet-5 leaves claude-sonnet-5-5 allowed (and opus-5/5-5, gpt-5.5/-mini, gemini-flash/-lite); dates and effort suffixes still match" || bad "F4 version-prefix over-match"

# ---- F5: continue without -m while a list is active is refused (the conversation's model is unseen)
(
  export OSRC_HOME; OSRC_HOME="$(xh f5)"
  : > "$CALLS"; o="$(OSRC_EXCLUDE_MODELS=fable bash "$SRC" continue "next" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && printf '%s' "$o" | grep -q 'continue: without -m the conversation keeps its original model' && [ ! -s "$CALLS" ] || { echo "  $o"; exit 1; }
  # with no list, continue without -m is unchanged (reaches devin)
  o="$(OSRC_HOME="$(xh f5b)" OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; need_devin() { :; }; _devin_guard_before_delegation() { :; }; devin() { echo "RAN $*"; }; continue_turn "next"' bash "$SRC" 2>&1)"
  printf '%s' "$o" | grep -q '^RAN -c' || { echo "  idle: $o"; exit 1; }
) && ok "F5: continue without -m is refused while a list is active, unchanged when nothing is excluded" || bad "F5 continue without -m"

# ---- F6: sessions (no-m default, relaunch onto an excluded model, drift restore)
(
  export OSRC_HOME; OSRC_HOME="$(xh f6)"; r=0
  sx() { OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; eval "$2"' bash "$SRC" "$1" 2>&1; }
  mkdir -p "$TMP/f6home/.claude"; printf '{"model":"opus"}' > "$TMP/f6home/.claude/settings.json"
  o="$(unset ANTHROPIC_MODEL; HOME="$TMP/f6home" OSRC_EXCLUDE_MODELS=fable sx 'MODEL_EXPLICIT=0; _exclude_session_default_guard cc; echo survived')"
  printf '%s' "$o" | grep -q survived || { echo "  configured opus: $o"; r=1; }
  o="$(ANTHROPIC_MODEL=claude-fable-5 OSRC_EXCLUDE_MODELS=fable sx 'MODEL_EXPLICIT=0; _exclude_session_default_guard cc; echo survived')"
  printf '%s' "$o" | grep -q 'runs your configured default claude-fable-5, which you excluded' && ! printf '%s' "$o" | grep -q survived || { echo "  configured fable: $o"; r=1; }
  o="$(unset ANTHROPIC_MODEL; HOME="$TMP/nohome" OSRC_EXCLUDE_MODELS=glm sx 'MODEL_EXPLICIT=0; _exclude_session_default_guard cc; echo survived')"
  printf '%s' "$o" | grep -q survived || { echo "  unrelated list: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=fable sx 'tmux() { echo "TMUX $*"; }; _session_control_relaunch pane cc claude-fable-5 ""; echo "rc=$?"')"
  printf '%s' "$o" | grep -q 'relaunch refused: this session was started on claude-fable-5' && printf '%s' "$o" | grep -q 'rc=1' && ! printf '%s' "$o" | grep -q TMUX || { echo "  relaunch: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=fable sx '_wake_append() { :; }; _session_model_matches() { return 1; }; _model_pin_restore_allowed() { return 0; }
    _session_model_restore() { echo RESTORED >&2; return 0; }; _model_pin_append() { return 0; }; _mkdir_claim() { return 0; }
    _model_pin_enforce_item "{\"session_id\":\"s1\",\"owner\":\"managed\",\"state\":\"working\",\"lane\":\"cc\",\"endpoint\":\"p\",\"requested_model\":\"fable\",\"observed_model\":\"opus\"}" 7')"
  printf '%s' "$o" | grep -q '"result":"restore-skipped-excluded"' && ! printf '%s' "$o" | grep -q RESTORED || { echo "  pin restore: $o"; r=1; }
  grep -c '_exclude_session_default_guard "$PROVIDER"' "$SRC" | grep -qx 2 || { echo "  session start guard not wired on both session paths"; r=1; }
  exit "$r"
) && ok "F6: no -m session refuses an excluded/unknown default, relaunch and drift-restore never return to an excluded model" || bad "F6 sessions"

# ---- F7: performance (inactive = zero forks; active = one load per process, one awk per batch)
(
  export OSRC_HOME; OSRC_HOME="$(xh f7)"; CNT="$TMP/awk.count"; : > "$CNT"
  o="$(CNT="$CNT" OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1
    awk() { echo x >> "$CNT"; command awk "$@"; }
    for i in 1 2 3 4 5 6 7 8 9 10; do _model_excluded fable; _exclude_refuse opus; done
    _exclude_filter sol terra luna fable opus >/dev/null
    printf "idle=%s\n" "$(wc -l < "$CNT" | tr -d " ")"
    export OSRC_EXCLUDE_MODELS=fable
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do _model_excluded fable; _model_excluded opus; _model_excluded sol; done
    printf "single=%s\n" "$(wc -l < "$CNT" | tr -d " ")"
    : > "$CNT"; _exclude_filter sol terra luna fable opus sonnet haiku glm deepseek kimi swe gpt-5.5 gemini-pro gemini-flash z-ai/glm-5.2 >/dev/null
    printf "batch=%s\n" "$(wc -l < "$CNT" | tr -d " ")"' bash "$SRC" 2>&1)"
  printf '%s' "$o" | grep -qx 'idle=0' && printf '%s' "$o" | grep -qx 'single=4' && printf '%s' "$o" | grep -qx 'batch=1' || { echo "  counts: $o"; exit 1; }
  # wall-clock bound: 200 checks over 40 names on an active list (memoized) stays well under 5s
  s0=$(date +%s)
  OSRC_EXCLUDE_MODELS='fable,gpt-5.6-*' OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1
    for r in 1 2 3 4 5; do for m in fable opus sonnet haiku sol terra luna gpt-5.5 glm deepseek kimi swe gemini-pro gemini-flash z-ai/glm-5.2 claude-fable-5 claude-opus-5 claude-sonnet-5 glm-5.3 swe-1.7 \
      kimi-k3 hy3 gemini-flash-lite claude-opus-4-8 claude-fable-5-1 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna glm-5-2 glm-5-3 deepseek/deepseek-v4-pro tencent/hy3:free anthropic/claude-5-fable openai/gpt-5.5 x-a x-b x-c x-d x-e x-f; do _model_excluded "$m"; done; done' bash "$SRC" >/dev/null 2>&1
  s1=$(date +%s); [ $((s1 - s0)) -lt 5 ] || { echo "  slow: $((s1 - s0))s"; exit 1; }
) && ok "F7: no list = zero awk forks; active list = one load + one awk per distinct name (memoized), one awk per batch filter, 200 checks < 5s" || bad "F7 performance"

# ---- F8: second-opinion swaps compare RESOLVED ids (glm and z-ai/glm-5.2 are one model)
(
  export OSRC_HOME; OSRC_HOME="$(xh f8)"; : > "$SOLOG"
  SO8='_so_run() { echo "$1" >> "$SOLOG"; echo "answer from $1 $RANDOM"; }; _so_agree() { return 1; }; record_ledger() { :; }
_autodetach_should() { return 1; }; _confident_fail() { return 1; }
_so_resolve() { case "$1" in glm|z-ai/glm-5.2) echo "z-ai/glm-5.2|ccor|capable" ;; *) printf "%s|cc|frontier\n" "$1" ;; esac; }
second_opinion "is the sky blue"'
  o="$(OSRC_SECOND_OPINION_MODELS=glm,fable OSRC_EXCLUDE_MODELS=fable lib "$SO8" 2>&1)"
  printf '%s' "$o" | grep -q 'fable is on your exclude list (fable); using sol instead' && ! grep -qx 'z-ai/glm-5.2' "$SOLOG" && grep -qx sol "$SOLOG" || { echo "  $o / $(tr '\n' ' ' < "$SOLOG")"; exit 1; }
) && ok "F8: second-opinion never swaps in a model that resolves to the other comparison model" || bad "F8 second-opinion resolved compare"

# ---- F9: exclude add shows which known models an entry covers
(
  export OSRC_HOME; OSRC_HOME="$(xh f9)"
  o="$(bash "$SRC" exclude add pro 2>&1)"
  printf '%s' "$o" | grep -q '^  covers: .*deepseek' && printf '%s' "$o" | grep -q 'gemini-pro' || { echo "  pro: $o"; exit 1; }
  o="$(bash "$SRC" exclude add claude-sonnet-5 2>&1)"
  printf '%s' "$o" | grep -q 'covers: .*claude-sonnet-5' && ! printf '%s' "$o" | grep -q 'covers: .*claude-sonnet-5-5' && printf '%s' "$o" | grep -q 'does not cover its point releases' || { echo "  sonnet-5: $o"; exit 1; }
  o="$(bash "$SRC" exclude add zzz-nothing 2>&1)"
  printf '%s' "$o" | grep -q 'covers no model outsourcerer knows today' || { echo "  none: $o"; exit 1; }
) && ok "F9: exclude add prints the known models an entry covers (pro -> deepseek-v4-pro surprise is visible) and the point-release note" || bad "F9 coverage print"

# ---- F10: doctor never pings an excluded agy / gemini-cli model
(
  export OSRC_HOME; OSRC_HOME="$(xh f10)"; : > "$CALLS"
  o="$(OSRC_EXCLUDE_MODELS=gemini-flash,gemini-flash-lite OSRC_DOCTOR_PING=1 OSRC_DOCTOR_PING_TIMEOUT=2 OSRC_AGY_FLASH_DEFAULT=gemini-3.5-flash OSRC_GEMINI_FLASH_LITE_API_ID=gemini-3.5-flash-lite bash "$SRC" doctor 2>&1)"
  printf '%s' "$o" | grep -q 'antigravity-agy: ping skipped' && printf '%s' "$o" | grep -q 'gemini-cli: ping skipped' \
    && ! grep -q '^agy -p' "$CALLS" && ! grep -q '^gemini -p' "$CALLS" || { echo "  $(printf '%s' "$o" | grep -iE 'agy|gemini-cli' | head -5) calls=$(grep -E '^(agy|gemini) ' "$CALLS" | head -3)"; exit 1; }
) && ok "F10: doctor skips the agy and gemini-cli pings when their model is excluded" || bad "F10 doctor agy ping"

# ---- F11: Devin health/plan probes skip excluded probe models
(
  export OSRC_HOME; OSRC_HOME="$(xh f11)"
  r="$(OSRC_EXCLUDE_MODELS=glm lib '_devin_probe_pick glm-5-2; echo; OSRC_DEVIN_PROBE_MODEL_ALT=swe-2 _devin_plan_probe_model kimi-k3; echo; _devin_probe_pick glm-5-2 >/dev/null; echo rc=$?' 2>/dev/null | tr '\n' ' ')"
  [ "$r" = "swe-2-flash-high swe-2-flash-high rc=0 " ] || { echo "  pick: '$r'"; exit 1; }
  r="$(OSRC_EXCLUDE_MODELS='glm swe kimi' lib '_devin_probe_pick glm-5-2; echo "rc=$?"; _lane_free_probe dv' 2>/dev/null | tr '\n' ' ')"
  [ "$r" = "rc=1 unreachable" ] || { echo "  all excluded: '$r'"; exit 1; }
) && ok "F11: Devin probes pick the next allowed model and never request an excluded one" || bad "F11 devin probes"

# ---- F12: task add -m <excluded> is refused at add time
(
  export OSRC_HOME; OSRC_HOME="$(xh f12)"
  mkdir -p "$TMP/f12repo" && (cd "$TMP/f12repo" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init) >/dev/null 2>&1
  (cd "$TMP/f12repo" && bash "$SRC" plan new p12 --goal g >/dev/null 2>&1)
  o="$(cd "$TMP/f12repo" && OSRC_EXCLUDE_MODELS=fable bash "$SRC" task add "x" -m fable 2>&1)"; rc=$?
  [ "$rc" != 0 ] && printf '%s' "$o" | grep -q "task add: you excluded 'fable'" && [ -z "$(ls "$OSRC_HOME/plans/p12/tasks" 2>/dev/null | grep json)" ] || { echo "  $o"; exit 1; }
  o="$(cd "$TMP/f12repo" && OSRC_EXCLUDE_MODELS=fable bash "$SRC" task add "y" -m opus 2>&1)" || { echo "  opus refused: $o"; exit 1; }
) && ok "F12: task add -m fable is refused when it is added, an allowed model is saved" || bad "F12 task add"

# ---- F13: exclude clear takes the state lock
(
  export OSRC_HOME; OSRC_HOME="$(xh f13)"; printf 'fable\n' > "$OSRC_HOME/exclude"
  o="$(lib '_state_lock_acquire() { return 1; }; cmd_exclude clear' 2>&1)"
  printf '%s' "$o" | grep -q 'the list is busy' && [ -f "$OSRC_HOME/exclude" ] || { echo "  $o"; exit 1; }
  bash "$SRC" exclude clear >/dev/null 2>&1 && [ ! -f "$OSRC_HOME/exclude" ] || exit 1
) && ok "F13: exclude clear waits for the list's lock (a busy lock leaves the list intact)" || bad "F13 clear lock"

# ---- F14: a comments-only file is inactive
(
  export OSRC_HOME; OSRC_HOME="$(xh f14)"; printf '# my exclusions\n\n   # none yet\n' > "$OSRC_HOME/exclude"
  r="$(lib '_exclude_active && echo active || echo idle' 2>/dev/null)"
  [ "$r" = idle ] && bash "$SRC" exclude ls 2>&1 | grep -q 'no models excluded' || { echo "  $r"; exit 1; }
) && ok "F14: a comments-only exclude file counts as no list" || bad "F14 comments-only file"

# ---- F15: engine lanes running their own default say the list cannot see that model
(
  export OSRC_HOME; OSRC_HOME="$(xh f15)"
  o="$(OSRC_EXCLUDE_MODELS=fable OSRC_PREFLIGHT=1 bash "$SRC" --provider droid run "hi" 2>&1)"
  printf '%s' "$o" | grep -q 'the droid lane runs the model it is configured with' || { echo "  $(printf '%s' "$o" | tail -3)"; exit 1; }
) && ok "F15: an engine lane with no -m (droid/cursor/hermes default) prints that the exclude list cannot see its model" || bad "F15 engine default notice"

# ---- F16: fanout without -m whose provider default is excluded is refused before anything starts
(
  export OSRC_HOME; OSRC_HOME="$(xh f16)"; : > "$CALLS"
  o="$(OSRC_EXCLUDE_MODELS=glm bash "$SRC" fanout -- "a" "b" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && printf '%s' "$o" | grep -q 'nothing was started.*--provider devin default glm-5.2' && [ ! -s "$CALLS" ] \
    && [ -z "$(ls "$OSRC_HOME/jobs" 2>/dev/null)" ] || { echo "  rc=$rc $o"; exit 1; }
) && ok "F16: fanout with an excluded provider default is refused up front, no member launched" || bad "F16 fanout default"

# ---- F17: loop escalate names the exclude list when it shrinks the default ladder to one rung
(
  export OSRC_HOME; OSRC_HOME="$(xh f17)"
  o="$(OSRC_EXCLUDE_MODELS='haiku glm' bash "$SRC" loop escalate --check true "task" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && printf '%s' "$o" | grep -q 'your exclude list removed haiku, glm-5.2 from the default ladder' || { echo "  $o"; exit 1; }
) && ok "F17: loop escalate says the exclude list shrank the ladder, not a generic rung-count error" || bad "F17 loop escalate"

# ---- F18: a bg child whose -m was excluded after launch fails WITH its reason (never silently)
(
  export OSRC_HOME; OSRC_HOME="$(xh f18)"
  OSRC_EXCLUDE_MODELS=fable lib 'run_job j18 devin run -m fable "x"; echo "rc=$?"' > "$TMP/f18.out" 2>&1
  jd="$OSRC_HOME/jobs/j18"
  grep -q 'rc=1' "$TMP/f18.out" && [ "$(cat "$jd/status" 2>/dev/null)" = failed ] && grep -q 'excluded-model:fable' "$jd/reason" \
    && grep -q "did not start: you excluded 'fable'" "$jd/out.log" || { echo "  $(cat "$TMP/f18.out") status=$(cat "$jd/status" 2>/dev/null)"; exit 1; }
) && ok "F18: run_job marks a child failed with reason excluded-model when the list changed after launch" || bad "F18 run_job"

# ---- bare alias decided by the id it runs TODAY (orchestrator refinement)
(
  export OSRC_HOME; OSRC_HOME="$(xh cur)"; r=0
  ! OSRC_EXCLUDE_MODELS=claude-opus-4-8 xc opus || { echo "  old opus blocked -m opus"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=claude-opus-4-8 bash "$SRC" run -m opus "hi" 2>&1)"; printf '%s' "$o" | grep -q "you excluded" && { echo "  run -m opus refused: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=claude-opus-5-5 bash "$SRC" run -m opus "hi" 2>&1)"
  printf '%s' "$o" | grep -q "you excluded 'opus' (exclude list entry: claude-opus-5-5; opus runs claude-opus-5-5 today)" || { echo "  opus-5-5: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=claude-fable-5 bash "$SRC" run -m fable "hi" 2>&1)"
  printf '%s' "$o" | grep -q "you excluded 'fable' (exclude list entry: claude-fable-5; fable runs claude-fable-5-1 today, a point release of claude-fable-5)" || { echo "  fable: $o"; r=1; }
  OSRC_EXCLUDE_MODELS=opus xc opus && ! OSRC_EXCLUDE_MODELS='claude-opus-4*' xc opus && OSRC_EXCLUDE_MODELS='claude-opus-5*' xc opus || { echo "  family word / globs"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=gemini-3.5-pro bash "$SRC" exclude check gemini-pro 2>&1)"
  printf '%s' "$o" | grep -q 'picks its model id live.*fail closed' || { echo "  gemini: $o"; r=1; }
  ! OSRC_EXCLUDE_MODELS=claude-sonnet-5 xc sonnet && OSRC_EXCLUDE_MODELS=claude-sonnet-5 xc claude-sonnet-5 || { echo "  sonnet-5 vs sonnet"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=claude-sonnet-5 bash "$SRC" run -m sonnet "hi" 2>&1)"; printf '%s' "$o" | grep -q "you excluded" && { echo "  run -m sonnet refused: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=claude-sonnet-5 bash "$SRC" run -m claude-sonnet-5 "hi" 2>&1)"; printf '%s' "$o" | grep -q "you excluded 'claude-sonnet-5'" || { echo "  run -m claude-sonnet-5 allowed: $o"; r=1; }
  o="$(OSRC_EXCLUDE_MODELS=claude-opus-5 bash "$SRC" run -m opus "hi" 2>&1)"; printf '%s' "$o" | grep -q "you excluded" && { echo "  opus-5 blocked -m opus: $o"; r=1; }
  grep -q '^OSRC_CLAUDE_POINT_RELEASES="claude-fable-5-1:claude-fable-5"' "$SRC" || { echo "  point-release list missing"; r=1; }
  grep -q '^OSRC_CLAUDE_CURRENT_IDS="fable|claude-fable-5-1 opus|claude-opus-5-5 sonnet|claude-sonnet-5-5 haiku|claude-haiku-5-5"' "$SRC" || { echo "  current-id map missing"; r=1; }
  exit "$r"
) && ok "bare alias: claude-opus-4-8/claude-opus-5/claude-sonnet-5 leave -m opus/-m sonnet allowed (-m claude-sonnet-5 still refused), claude-opus-5-5 and claude-fable-5 (listed point release) refuse opus/fable with the reason, a live-picked Gemini alias fails closed and says why" || bad "bare alias current-id rule"

echo "---"
echo "test_factory_exclude: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

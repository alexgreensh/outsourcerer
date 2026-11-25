# =============================================================================
# lib/devin-free.sh — Devin "is it Free?" proof and the dv launch-id gate
#
# Free is decided ONLY by the live catalog's exact structured field cost_tier=="Free"
# (never cost_summary text: Fusion rows end in "Sidekick: Free" while the main model
# bills High cost). Moved out of outsourcerer.sh for the engine-size ratchet; the
# catalog helpers (_devin_catalog_raw, _deepseek_effort_suffix, have) stay engine-side
# and resolve at call time.
# =============================================================================

# ---- dv launch id: resolve ONCE, gate exactly that id, launch exactly that id ------------
# route_delegate used to gate RESOLVED_ID (the alias table's target, e.g. swe -> swe-1.7) while
# delegate() re-parsed ORIG and resolved the raw -m token (swe) through the live catalog. The two
# lookups could pick different variants, so a Free id was gated and a paid one launched.
# _OSRC_DV_LAUNCH_FOR keys the id to the -m token it was resolved for: delegate() honours it only
# for that same token, and consumes it (one gated id = one launch), so a later delegate() in the
# same shell with a different -m (a retry, a sibling task) is resolved and gated afresh.
_OSRC_DV_LAUNCH_ID=""; _OSRC_DV_LAUNCH_FOR=""

# _osrc_dv_launch_token -> the -m token delegate()'s parse_model will read from ORIG (parsed in
# a subshell with the SAME parser, so the prediction cannot drift), else route_delegate's MODEL
# (a bare run's runtime default, which delegate() inherits).
_osrc_dv_launch_token() {
  local t
  t="$( parse_model ${ORIG[@]+"${ORIG[@]}"} >/dev/null 2>&1; printf '%s' "${MODEL:-}" )"
  printf '%s' "${t:-${MODEL:-}}"
}

# _osrc_dv_launch_prepare -> sets _OSRC_DV_LAUNCH_ID to the exact id the dv lane will launch for
# this route: a bg pin launches verbatim, everything else through _devin_resolve_model. Called by
# route_delegate right before the spend gate; delegate() launches this id without re-resolving.
_osrc_dv_launch_prepare() {
  local tok; tok="$(_osrc_dv_launch_token)"; _OSRC_DV_LAUNCH_FOR="$tok"
  if [ "${_OSRC_PIN_DISP:-}" = devin ]; then _OSRC_DV_LAUNCH_ID="$tok"
  else _OSRC_DV_LAUNCH_ID="$(_devin_resolve_model "$tok" 2>/dev/null)"; fi
}

# _osrc_dv_launch_id <token> -> sets _OSRC_DV_ID for delegate(): the route's gated id when
# route_delegate prepared one; otherwise (a launch that never went through route_delegate's
# gate, e.g. the cc -> Devin self-heal) resolve now and spend-gate THAT exact id before launch.
_osrc_dv_launch_id() {
  _OSRC_DV_ID=""
  [ -n "$_OSRC_DV_LAUNCH_ID" ] && [ "${1:-}" = "$_OSRC_DV_LAUNCH_FOR" ] && _OSRC_DV_ID="$_OSRC_DV_LAUNCH_ID"
  _OSRC_DV_LAUNCH_ID=""; _OSRC_DV_LAUNCH_FOR=""
  [ -n "$_OSRC_DV_ID" ] && return 0
  if [ "${_OSRC_PIN_DISP:-}" = devin ]; then _OSRC_DV_ID="${1:-}"
  else _OSRC_DV_ID="$(_devin_resolve_model "${1:-}")"; fi
  _exclude_refuse_resolved "${1:-}" "$_OSRC_DV_ID"   # an excluded id is refused before any spend prompt
  _osrc_spend_gate dv "$_OSRC_DV_ID" devin "Devin launch outside the routed gate"
}


# _devin_catalog_free_set -> sets _OSRC_CAT_FREE_SET (space-padded, normalized: lowercase, vendor/
# and date stamp stripped, dots folded) in the CALLER's shell. Built from _devin_catalog_free_ids,
# the spend gate's own extractor, so both share ONE freshness rule (only a fresh catalog proves
# Free) and one mtime-keyed parse. Call it directly, never through $( ): the memo lives in the
# caller. Offline or OSRC_FREE_CATALOG_CHECK=0 -> " " (fail closed: nothing catalog-Free).
_OSRC_CAT_FREE_SET=" "; _OSRC_CAT_FREE_SRC=""; _OSRC_CAT_FREE_SET_MEMO=" "
_devin_catalog_free_set() {
  _OSRC_CAT_FREE_SET=" "
  _devin_free_ids_get || return 0
  [ -n "$_OSRC_CAT_FREE_SRC" ] && [ "$_OSRC_CAT_FREE_SRC" = "x$_OSRC_DV_FREE_IDS" ] && { _OSRC_CAT_FREE_SET="$_OSRC_CAT_FREE_SET_MEMO"; return 0; }
  _OSRC_CAT_FREE_SET=" $(printf '%s' "$_OSRC_DV_FREE_IDS" | tr ' ' '\n' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#^[^/]*/##; s/-[0-9]{6,}$//; s/\./-/g' | tr '\n' ' ') "
  _OSRC_CAT_FREE_SRC="x$_OSRC_DV_FREE_IDS"; _OSRC_CAT_FREE_SET_MEMO="$_OSRC_CAT_FREE_SET"
}

# A launchable id for a truly-Free model (exact cost_tier=Free, no daily quota) discovered
# from the catalog — the right escape-hatch to probe when the shared plan bucket is spent.
# Budget lanes partition first, then newest mainline Free -high variant, then the
# strongest/newest Free id. Empty when unavailable.
_devin_first_catalog_free_model() {
  [ "${OSRC_FREE_CATALOG_CHECK:-1}" = "1" ] || { printf ''; return; }
  local raw; raw="$(_devin_catalog_raw 2>/dev/null)" || raw=""
  [ -n "$raw" ] || { printf ''; return; }
  jq -r '
    def isfree(o): (((o.cost_tier | strings) // "") | ascii_downcase) == "free";
    def uidok(s): ((s|type) == "string") and (s|test("^[A-Za-z0-9._/-]+$"));
    def vernums: [ scan("[0-9]+") | tonumber ];
    def tiernum: if (.model_uid|endswith("-max")) then 5
      elif (.model_uid|endswith("-xhigh")) then 4
      elif (.model_uid|endswith("-high")) then 3
      elif (.model_uid|endswith("-medium")) then 2
      elif (.model_uid|endswith("-low")) then 1 else 0 end;
    def nonbudget: (.model_uid|ascii_downcase|test("flash|fast|lightning")|not);
    def best:
      ( (map(select(nonbudget))) as $nb | (if ($nb|length)>0 then $nb else . end)
        | sort_by([(.model_uid|vernums), tiernum]) | reverse | .[0].model_uid );
    # Budget lanes partition FIRST (flash/fast/lightning never outrank mainline), then
    # newest mainline -high, then strongest remaining. No family-id preference: a bare
    # family id is no more launchable than a variant id, and preferring it inverted the
    # documented version order whenever an old all-free family coexisted with a newer
    # mixed one (Neon + GLM review findings).
    ([ .families[]?.variants[]? | select(isfree(.) and uidok(.model_uid)) ]) as $free
    | ([ $free[] | select(nonbudget) ]) as $nb
    | (if ($nb | length) > 0 then $nb else $free end) as $pool
    | (([$pool[] | select(.model_uid|endswith("-high"))] | best) // ($pool | best) // empty)
  ' 2>/dev/null <<<"$raw"
}


# _devin_resolve_dynamic <token> -> a launchable Devin variant resolved from the LIVE catalog, or
# empty if unresolvable/offline. This is what lets a NEW or renamed Devin model work with no
# hand-edited table: an exact variant id passes through; a family id or short alias (glm/deepseek/
# kimi/swe...) resolves to the effort-appropriate variant, COST-AWARE (prefers Free/plan-included,
# skips paid *-lightning/*-fast and *-max unless the run's effort asks) and VERSION-AWARE (newest
# family wins for an ambiguous alias). Effort folds via _deepseek_effort_suffix (low|high|max).
#
# Deliberately matches on family_uid ONLY, never on the catalog's `aliases`. Devin's own aliases are
# not cost-safe: live, `swe` is an alias of the PAID swe-1.7-lightning family ($2.5/$12.5 MTok)
# while the free swe-1.7 family carries no alias at all. Resolving by family prefix + cost rank
# picks the free rung; honoring the alias would silently bill.
_devin_resolve_dynamic() {
  local tok="${1:-}" eff cat
  [ -n "$tok" ] || return 1
  have jq || return 1
  [ "${OSRC_DEVIN_DYNAMIC_RESOLVE:-1}" = "0" ] && return 1    # escape hatch -> static path only
  [ "${OSRC_CATALOG_VALIDATE:-1}" = "0" ] && return 1         # same knob that skips the live catalog gate
  eff="$(_deepseek_effort_suffix)"
  cat="$(_devin_catalog_raw)"; [ -n "$cat" ] || return 1
  # costrank reads ONLY exact cost_tier=Free. cost_summary is not a cost authority: Fusion rows
  # end with "Sidekick: Free" while the main model is still High cost, so matching that text would
  # rank a paid Fusion id as free.
  printf '%s' "$cat" | jq -r --arg tok "$tok" --arg eff "$eff" '
    def vernums: [ scan("[0-9]+") | tonumber ];
    def costrank: if (((.cost_tier | strings) // "") | ascii_downcase) == "free" then 0 else 1 end;
    # Exact-match normalization must mirror the spend gate (lowercase, dots folded) and
    # return the catalog exact uid — a case/dot variation that bypassed the gate check
    # but resolved to a DIFFERENT paid variant was the end-to-end spend bypass (Neon,
    # verified end-to-end).
    def keyify(s): (s | ascii_downcase | gsub("\\.";"-"));
    ( [ .families[]?.variants[]?.model_uid ] ) as $allvars
    | ( $allvars | map(keyify(.)) | index(keyify($tok)) ) as $exactidx
    | if $exactidx != null then $allvars[$exactidx]
      else
        ( [ .families[]?
            | select( keyify(.family_uid) == keyify($tok)
                      or (keyify(.family_uid) | startswith(keyify($tok)+"-")) ) ] ) as $fams
        | if ($fams|length)==0 then ""
          else
            ( ($fams | map(select(.family_uid | test("flash|fast|lightning";"i")|not))) as $nf
              | (if ($nf|length)>0 then $nf else $fams end) ) as $cand
            # An unversioned family alias prefers a family that still HAS a Free variant:
            # when a promo ends on the newest generation, `swe` must resolve to the Free
            # older generation rather than silently landing on the paid newest one (Neon).
            # Explicit paid pins are unaffected — they hit the exact-match branch above.
            | ( ($cand | map(select([(.variants // [])[]? | select(costrank == 0)] | length > 0))) as $cfam
                | (if ($cfam|length)>0 then $cfam else $cand end) ) as $pool
            | ( $pool | sort_by(.family_uid|vernums) | reverse | .[0] ) as $fam
            | ( ($fam.variants // []) | map(select(.model_uid | test("-(1m|none)$";"i")|not)) ) as $vars
            | if ($vars|length)==0 then ""
              else
                # Cost outranks effort: the effort-suffix filter running FIRST let a paid -high
                # win over a free -max in the same family (eff defaults to high), so a bare alias
                # resolved onto a paid variant although a free one existed. Effort is only a
                # tiebreak within the same cost class (advisory on the Devin lane anyway).
                ( $vars | sort_by([ costrank,
                                    (if (.model_uid | endswith("-"+$eff)) then 0 else 1 end),
                                    (.model_uid|length) ]) | .[0].model_uid )
              end
          end
      end' 2>/dev/null
}

# _devin_is_free_model <devin-id> -> rc0 if it runs on Devin's plan-INCLUDED (free) tier, so a
# "0% remaining" paid-ACU figure must not be read as blocking it. A LABEL for the dispatch banner,
# the failure classifier and the plan meter; it gates no spend (that is _osrc_devin_free_for_spend).
# Static set = exact plan-included ids the catalog rates at their pay-as-you-go price, plus the two
# offline-proven Free ids. Exact literals only: a bare alias (swe, glm, kimi, swe-2) resolves inside
# Devin, possibly to a paid variant, and a glob matched paid -lightning/-fast/-max siblings.
_devin_is_free_model() {
  local t norm; t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    glm-5.2|glm-5-2|z-ai/glm-5.2|swe-1.7|swe-1-7|deepseek-v4-pro|deepseek/deepseek-v4-pro|swe-2-high|swe-2-flash-high) return 0 ;;
  esac
  # Live catalog cost_tier="Free" (exact variant, or an all-Free family id); never tier-stripped.
  norm="$(printf '%s' "$t" | sed -E 's#^[^/]*/##; s/-[0-9]{6,}$//; s/\./-/g')"
  _devin_catalog_free_set
  case "$_OSRC_CAT_FREE_SET" in *" $norm "*) return 0 ;; esac
  return 1
}

# _devin_probe_pick <preferred...> -> the first health-probe model that is NOT excluded (#45) and is
# PROVEN free to request: a probe asks no consent, so it needs the spend gate's own proof
# (_osrc_devin_free_for_spend: exact id, catalog Free, offline only swe-2-high / swe-2-flash-high)
# or the exact plan-included literal glm-5-2 (daily plan quota, no cash; Devin refuses, not bills,
# when it is spent). A caller-passed or overridden id without that proof is skipped, never pinged.
_devin_probe_pick() {
  local c skip="${OSRC_DEVIN_PROBE_SKIP:-}"
  for c in "$@" glm-5-2 swe-2-high; do
    [ -n "$c" ] || continue
    [ -n "$skip" ] && [ "$(printf '%s' "$c" | tr '[:upper:]._' '[:lower:]--')" = "$skip" ] && continue
    _model_excluded "$c" && continue
    [ "$c" = glm-5-2 ] || _osrc_devin_free_for_spend "$c" || continue
    printf '%s' "$c"; return 0
  done
  return 1
}
_OSRC_LIBEND_DEVINFREE=1   # last line: the loader proves this lib loaded whole (_osrc_spend_libs_ok)

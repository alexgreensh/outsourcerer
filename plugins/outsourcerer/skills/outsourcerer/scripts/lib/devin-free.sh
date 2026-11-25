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
_OSRC_DV_LAUNCH_ID=""

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
  local tok; tok="$(_osrc_dv_launch_token)"
  if [ "${_OSRC_PIN_DISP:-}" = devin ]; then _OSRC_DV_LAUNCH_ID="$tok"
  else _OSRC_DV_LAUNCH_ID="$(_devin_resolve_model "$tok" 2>/dev/null)"; fi
}

# _osrc_dv_launch_id <token> -> sets _OSRC_DV_ID for delegate(): the route's gated id when
# route_delegate prepared one; otherwise (a launch that never went through route_delegate's
# gate, e.g. the cc -> Devin self-heal) resolve now and spend-gate THAT exact id before launch.
_osrc_dv_launch_id() {
  _OSRC_DV_ID="${_OSRC_DV_LAUNCH_ID:-}"
  [ -n "$_OSRC_DV_ID" ] && return 0
  if [ "${_OSRC_PIN_DISP:-}" = devin ]; then _OSRC_DV_ID="${1:-}"
  else _OSRC_DV_ID="$(_devin_resolve_model "${1:-}")"; fi
  _exclude_refuse_resolved "${1:-}" "$_OSRC_DV_ID"   # an excluded id is refused before any spend prompt
  _osrc_spend_gate dv "$_OSRC_DV_ID" devin "Devin launch outside the routed gate"
}


# The set of Devin models Devin's OWN live catalog marks cost_tier="Free" (canon-keyed, space-padded),
# so the free tier self-heals as Devin adds/renames Free models instead of drifting behind a hardcoded
# list. COST-SAFE: a bare family id counts only when EVERY variant in it is Free (a mixed family lists
# just its Free variants), so a paid variant never rides in on a family match. Memoized in-process (the
# catalog walk is ~100ms; every later lookup is a string match), and skippable via OSRC_FREE_CATALOG_CHECK=0.
_OSRC_CAT_FREE_MEMO_SET=""; _OSRC_CAT_FREE_MEMO_DONE=""
_devin_catalog_free_set() {
  [ "${OSRC_FREE_CATALOG_CHECK:-1}" = "1" ] || { printf ' '; return; }
  [ -n "$_OSRC_CAT_FREE_MEMO_DONE" ] && { printf '%s' "$_OSRC_CAT_FREE_MEMO_SET"; return; }
  _OSRC_CAT_FREE_MEMO_DONE=1
  local raw set=""
  raw="$(_devin_catalog_raw 2>/dev/null)" || raw=""
  if [ -n "$raw" ]; then
    set="$(jq -r '
      def norm(s): (s|ascii_downcase|sub("^[^/]*/";"")|sub("-[0-9]{6,}$";"")|gsub("\\.";"-"));
      def isfree(o): (((o.cost_tier | strings) // "") | ascii_downcase) == "free";
      def uidok(s): ((s|type) == "string") and (s|test("^[A-Za-z0-9._/-]+$"));
      # v: tokens are exact free variants (no tier-stripping — a paid -max sibling must
      # never ride in on its free -high sibling). f: tokens are all-free family ids/slugs,
      # the only ids a bare family-shaped probe may match. uids are shape-filtered: the
      # live catalog carries spaced display labels, and one spaced uid would otherwise
      # split into bogus free tokens (Neon review, verified).
      [ .families[]?
        | ( select((.variants|type) == "array" and (.variants|length) > 0 and all(.variants[]?; isfree(.)))
            | ( (select(uidok(.family_uid)) | "f:"+norm(.family_uid)),
                (select(((.slug // "") != "") and uidok(.slug)) | "f:"+norm(.slug)) ) ),
          ( .variants[]? | select(isfree(.) and uidok(.model_uid)) | "v:"+norm(.model_uid) ) ]
      | unique | .[]
    ' 2>/dev/null <<<"$raw" | tr "\n" " ")"
  fi
  _OSRC_CAT_FREE_MEMO_SET=" $set"
  printf '%s' "$_OSRC_CAT_FREE_MEMO_SET"
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
            | select( (.family_uid|ascii_downcase) == ($tok|ascii_downcase)
                      or (.family_uid|ascii_downcase | startswith(($tok|ascii_downcase)+"-"))
                      or (.family_uid|ascii_downcase | startswith(($tok|ascii_downcase)+".")) ) ] ) as $fams
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
                ( $vars | map(select(.model_uid | endswith("-"+$eff))) ) as $esfx
                | if ($esfx|length)>0 then ($esfx | sort_by(costrank,(.model_uid|length)) | .[0].model_uid)
                  else ($vars | sort_by(costrank,(.model_uid|length)) | .[0].model_uid) end
              end
          end
      end' 2>/dev/null
}

# _devin_is_free_model <alias-or-devin-id> -> rc0 if it runs on Devin's plan-INCLUDED (free) tier.
# These do NOT draw on the separate paid ACU balance, so a "0% remaining" figure in Devin's own output
# (which reports that paid balance) must never be read as blocking them. This is the bug-1 anchor:
# free-tier models must run regardless of the paid-quota display.
# swe-2 is added because Devin's live catalog marks it cost_tier="Free" (its own separate tier, outside
# the shared glm/swe-1.7/kimi daily plan bucket). It was previously unrecognized, so a swe-2 dispatch —
# the escape when the shared bucket is spent — was treated as a paid model.
_devin_is_free_model() {
  local t; t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  # Static set = the plan-INCLUDED models Devin's catalog does NOT tag "Free" (it rates them by their
  # non-plan pay-as-you-go price), so they can't be discovered from cost_tier and must be named here.
  # Also the offline fallback for the catalog-Free models (so swe-2 is still recognized with no network).
  case "$t" in
    glm|glm-5.2|glm-5-2|z-ai/glm-5.2|glm-5.3*|glm-5-3*|z-ai/glm-5.3*|swe-2|swe-2-high|swe-2-medium|swe-2-max|swe-2-flash|swe-2-flash-*|swe|swe-1.7|swe-1-7|swe-1.7-lightning|deepseek|deepseek-v4-pro|deepseek/deepseek-v4-pro|kimi|kimi-k3) return 0 ;;
  esac
  # Catalog-driven union: any model the LIVE catalog marks cost_tier="Free" is free, so a newly added
  # or renamed Free model is recognized with no code change — this is what stops the list from drifting.
  # Exact-token match only: v: for the probe's own exact id, f: when the probe IS a bare
  # all-free family id. Never strip the probe's tier suffix — a paid -max sibling canonizing
  # onto its free -high sibling was the paid-billing hole (Neon/GLM review finding).
  local norm set; norm="$(printf '%s' "$t" | sed -E 's#^[^/]*/##; s/-[0-9]{6,}$//; s/\./-/g')"
  set="$(_devin_catalog_free_set)"
  case "$set" in *" v:$norm "*|*" f:$norm "*) return 0 ;; esac
  return 1
}

# _devin_probe_pick <preferred...> -> the first health-probe model that is NOT on the user's
# exclude list (#45: a probe is still a request to that model) and does NOT draw the paid ACU
# balance. A probe sends a request with no consent prompt, so a caller-passed or overridden
# paid id (OSRC_DEVIN_PROBE_MODEL, a refused model) is skipped, never pinged. The built-in
# fallbacks are plan-included (daily quota, no cash). rc1 when nothing qualifies.
_devin_probe_pick() {
  local c skip="${OSRC_DEVIN_PROBE_SKIP:-}"
  for c in "$@" glm-5-2 swe-2-high swe-1-7 kimi-k3; do
    [ -n "$c" ] || continue
    [ -n "$skip" ] && [ "$(printf '%s' "$c" | tr '[:upper:]._' '[:lower:]--')" = "$skip" ] && continue
    _model_excluded "$c" && continue
    _devin_is_free_model "$c" || continue
    printf '%s' "$c"; return 0
  done
  return 1
}

# shellcheck shell=bash
# lib/hub-safe.sh: Mission Control never drops a project without saying so (release review F46). Sourced by
# outsourcerer.sh (and by hub.sh for suites that source it alone); function definitions only.

# _osrc_hub_stub_project <slug> <now-epoch> <updated-stamp> <why> -> a minimal project doc for a project
# whose build failed (a card the export cannot read, a jq error): it stays listed with exportError, so
# the page says the data is missing instead of the project vanishing.
_osrc_hub_stub_project() {
  local name=""
  [ -f "$OSRC_HOME/hub/projects/$1.json" ] && name="$(jq -r '.name // "" | strings' "$OSRC_HOME/hub/projects/$1.json" 2>/dev/null)"
  [ -n "$name" ] || ! type _osrc_hub_derived_name >/dev/null 2>&1 || name="$(_osrc_hub_derived_name "$1" 2>/dev/null)"
  jq -cn --arg id "$1" --arg name "${name:-$1}" --argjson now "$2" --arg upd "$3" --arg why "$4" \
    '{id:$id, name:$name, order:99, updated:$upd, exported_at:$now, lanes:[], decisions:[], liveLanes:0, exportError:$why}'
}

# _osrc_hub_truth_safe <project-json> <now-epoch> -> _osrc_hub_truth's doc, else the project as built,
# marked exportError: one bad pass must not empty the projects list for everyone.
_osrc_hub_truth_safe() {
  local out; out="$(_osrc_hub_truth "$1" "$2" 2>/dev/null)"
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then printf '%s\n' "$out"
  else jq -c '. + {exportError: "Mission Control could not check this project against its lanes in this export; showing it as built"}' <<<"$1"; fi
}

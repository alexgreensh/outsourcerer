# Derive an identifiable project name without reading credential material.
_osrc_hub_derived_name() {
  local sid="$1" f id dir repo remote name='' common='' conflict=0 prompt
  for f in "$OSRC_HOME/owners/$sid"/*; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    dir="$(jq -r '.worktree // .cwd // .path // ""' "$OSRC_JOBS/$id/meta.json" 2>/dev/null)"
    [ -n "$dir" ] || dir="$(jq -r '.cwd // .worktree // ""' "$OSRC_HOME/remote/$id.json" 2>/dev/null)"
    [ -n "$dir" ] || dir="$(jq -r --arg id "$id" 'select(.session_id == $id) | .cwd // empty' "${OSRC_SESSION_REGISTRY:-/dev/null}" 2>/dev/null | tail -1)"
    [ -n "$dir" ] || continue
    if [ -z "$common" ]; then common="${dir%/}"; elif [ "${common##*/}" != "${dir%/}" ] && [ "${common##*/}" != "$(basename "$dir")" ]; then conflict=1; fi
    repo="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || repo=''
    [ -n "$repo" ] || continue
    remote="$(git -C "$dir" config --get remote.origin.url 2>/dev/null)"
    case "$remote" in *github.com[:/]*) name="${remote##*github.com[:/]}"; name="${name%.git}" ;; *) name="${repo##*/}" ;; esac
    [ -n "$name" ] && { printf '%s (%s)' "$name" "${sid:0:8}"; return; }
  done
  if [ -n "$common" ] && [ "$conflict" = 0 ]; then printf '%s (%s)' "${common##*/}" "${sid:0:8}"; return; fi
  for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    [ -f "$f" ] || continue
    prompt="$(jq -r 'select((.customTitle // "") != "") | .customTitle' "$f" 2>/dev/null | tail -1)"
    [ -n "$prompt" ] || prompt="$(jq -r 'select(.type == "user") | .message.content | if type == "string" then . elif type == "array" then ([.[] | select(.type == "text") | .text] | join(" ")) else empty end' "$f" 2>/dev/null | head -1)"
    prompt="$(printf %s "$prompt" | tr '\n\r' '  ' | cut -c1-48)"
    [ -n "$prompt" ] && { printf '%s' "$prompt"; return; }
  done
  printf 'Session %.8s' "$sid"
}

_osrc_hub_daily_hint() {
  local d="$OSRC_HOME/hub" today
  today="$(date +%Y-%m-%d)"
  mkdir -p "$d" 2>/dev/null || return 0
  ( set -C; printf '%s\n' "$today" > "$d/hint-$today" ) 2>/dev/null || return 0
  printf 'Mission Control: outsourcerer mc\n' >&2
}

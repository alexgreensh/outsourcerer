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
  prompt="$(_osrc_hub_prompt_name "$sid")"
  [ -n "$prompt" ] && { printf '%s' "$prompt"; return; }
  printf 'Session %.8s' "$sid"
}

# jq: a first prompt as a readable name (MC2 r2 #3). Chat noise goes ("[Image #1]", "[Pasted text #2 +40
# lines]", <pasted_content>/<command-*> wrappers, leading slash commands), whitespace collapses, and a long
# prompt is cut at a word boundary with an ellipsis.
_OSRC_HUB_NAME_JQ='def clean: gsub("<command-(name|message)>[^<]*</command-(name|message)>"; " ") | gsub("<[^>]*>"; " ")
  | gsub("\\[(Image|Pasted text)[^\\]]*\\]"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub("^(/[A-Za-z0-9:_.-]+ ?)+"; "") | sub(" $"; "");
def short($n): if length <= $n then . else .[0:$n] as $c | ($c | sub(" [^ ]*$"; "")) as $w
  | (if ($w | length) >= ($n / 2) then $w else $c end) | sub("[ ,;:.-]+$"; "") + "…" end;'

# _osrc_hub_prompt_name <sid> -> cleaned custom title or first real prompt of the Claude transcript, or "".
# Transcripts run to 100+ MB, so it never parses one whole: grep pulls the few lines it needs, and the
# result is cached per session id in $OSRC_HOME/hub/names/<sid> ("<size> <name>"). Transcripts only grow,
# so an unchanged size means an unchanged transcript (MC2 r2 #4).
_osrc_hub_prompt_name() {
  local sid="$1" f c name='' t sz line
  case "$sid" in ''|.*|*/*) return 0 ;; esac
  c="$OSRC_HOME/hub/names/$sid"
  for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    [ -f "$f" ] || continue
    sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null)"
    if [ -n "$sz" ] && [ -f "$c" ] && [ ! -L "$c" ]; then
      IFS= read -r line < "$c" 2>/dev/null || true
      [ "${line%% *}" = "$sz" ] && [ -n "${line#* }" ] && { printf '%s' "${line#* }"; return 0; }
    fi
    t="$(grep -F '"customTitle"' "$f" 2>/dev/null | tail -1)"
    [ -z "$t" ] || name="$(jq -r "$_OSRC_HUB_NAME_JQ"' (.customTitle // "") | clean | short(48)' <<<"$t" 2>/dev/null)"
    [ -n "$name" ] || name="$(grep -m 40 -E '"type": ?"user"' "$f" 2>/dev/null | jq -rn "$_OSRC_HUB_NAME_JQ"'
      first(inputs | select(.type == "user" and ((.isMeta // false) | not)) | .message.content
        | (if type == "string" then . elif type == "array" then ([.[] | select(.type == "text") | .text] | join(" ")) else "" end)
        | clean | select(length > 0 and (startswith("Caveat:") | not)) | short(48)) // empty' 2>/dev/null)"
    if [ -n "$name" ]; then
      mkdir -p "$OSRC_HOME/hub/names" 2>/dev/null && [ ! -L "$c" ] && printf '%s %s\n' "$sz" "$name" > "$c.$$" 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null
      printf '%s' "$name"; return 0
    fi
  done
  return 0
}

_osrc_hub_daily_hint() {
  local d="$OSRC_HOME/hub" today
  today="$(date +%Y-%m-%d)"
  mkdir -p "$d" 2>/dev/null || return 0
  ( set -C; printf '%s\n' "$today" > "$d/hint-$today" ) 2>/dev/null || return 0
  printf 'Mission Control: outsourcerer mc\n' >&2
}

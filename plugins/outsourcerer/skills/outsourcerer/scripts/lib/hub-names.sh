# Mission Control names (MC2 r3): what a person would call the project. Never an owner/repo path, a URL,
# a session id or hex. Read without touching credential material.

# _osrc_hub_humanize <raw> -> "alexgreensh/total-recall-core.git" -> "Total Recall Core".
_osrc_hub_humanize() {
  local n="${1%/}"
  n="${n##*/}"; n="${n%.git}"
  printf '%s' "$n" | tr '_-' '  ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }'
}

# _osrc_hub_derived_name <sid> -> the humanized project the session's owned lanes work in (git remote
# repo name, else the repo folder, else their one shared folder), or "" when that is unknown. The export
# adds what each session is doing when two shown sessions share a project (_osrc_hub_name_finish).
_osrc_hub_derived_name() {
  local sid="$1" f id dir repo remote common='' conflict=0
  for f in "$OSRC_HOME/owners/$sid"/*; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    dir="$(jq -r '.worktree // .cwd // .path // ""' "$OSRC_JOBS/$id/meta.json" 2>/dev/null)"
    [ -n "$dir" ] || dir="$(jq -r '.cwd // .worktree // ""' "$OSRC_HOME/remote/$id.json" 2>/dev/null)"
    [ -n "$dir" ] || dir="$(jq -r --arg id "$id" 'select(.session_id == $id) | .cwd // empty' "${OSRC_SESSION_REGISTRY:-/dev/null}" 2>/dev/null | tail -1)"
    [ -n "$dir" ] || continue
    if [ -z "$common" ]; then common="${dir%/}"; elif [ "${common##*/}" != "$(basename "$dir")" ]; then conflict=1; fi
    repo="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || repo=''
    [ -n "$repo" ] || continue
    remote="$(git -C "$dir" config --get remote.origin.url 2>/dev/null)"
    case "$remote" in *github.com[:/]*) remote="${remote##*github.com[:/]}" ;; ''|*://*|*@*) remote="" ;; esac
    _osrc_hub_humanize "${remote:-$repo}"; return 0
  done
  [ -n "$common" ] && [ "$conflict" = 0 ] && { _osrc_hub_humanize "$common"; return 0; }
  return 0
}

# jq helpers. clean: drop chat noise ("[Image #1]", "[Pasted text #2 +40 lines]", <pasted_content> and
# <command-*> wrappers, slash commands), URLs, file paths (any token with a "/"), uuids and hex ids;
# collapse whitespace. short($n): cut at a word boundary with an ellipsis.
_OSRC_HUB_NAME_JQ='def clean: gsub("<command-(name|message)>[^<]*</command-(name|message)>"; " ") | gsub("<[^>]*>"; " ")
  | gsub("\\[(Image|Pasted text)[^\\]]*\\]"; " ") | gsub("[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s]*"; " ")
  | gsub("(^|\\s)[^\\s]*/[^\\s]*"; " ") | gsub("\\b[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\b"; " ")
  | gsub("\\b(?=[0-9a-fA-F]*[0-9])(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{6,}\\b"; " ")
  | gsub("\\s+"; " ") | sub("^[ ,;:.-]+"; "") | sub("[ ,;:-]+$"; "");
def short($n): if length <= $n then . else .[0:$n] as $c | ($c | sub(" [^ ]*$"; "")) as $w
  | (if ($w | length) >= ($n / 2) then $w else $c end) | sub("[ ,;:.-]+$"; "") + "…" end;'

# _osrc_hub_session_detail <sid> -> what the Claude session is about, from its /rename title, else its
# summary line, else its first real prompt, cleaned and shortened; "" when nothing usable. Transcripts run to
# 100+ MB, so grep pulls the few lines needed; the result is cached in $OSRC_HOME/hub/titles/<sid> as
# "<size> <text>" (transcripts only grow, so an unchanged size means an unchanged transcript).
_osrc_hub_session_detail() {
  local sid="$1" f c out='' t sz line n="${OSRC_HUB_DETAIL_LEN:-32}"
  case "$sid" in ''|.*|*/*) return 0 ;; esac
  c="$OSRC_HOME/hub/titles/$sid"
  for f in "$HOME"/.claude/projects/*/"$sid".jsonl; do
    [ -f "$f" ] || continue
    sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null)"
    if [ -n "$sz" ] && [ -f "$c" ] && [ ! -L "$c" ]; then
      IFS= read -r line < "$c" 2>/dev/null || true
      [ "${line%% *}" = "$sz" ] && { [ "$line" = "$sz" ] || printf '%s' "${line#* }"; return 0; }
    fi
    t="$(grep -F '"customTitle"' "$f" 2>/dev/null | tail -1)"
    [ -z "$t" ] || out="$(jq -r "$_OSRC_HUB_NAME_JQ"' (.customTitle // "") | clean | short('"$n"')' <<<"$t" 2>/dev/null)"
    if [ -z "$out" ]; then
      t="$(grep -E '"type": ?"summary"' "$f" 2>/dev/null | tail -1)"
      [ -z "$t" ] || out="$(jq -r "$_OSRC_HUB_NAME_JQ"' (.summary // "") | clean | short('"$n"')' <<<"$t" 2>/dev/null)"
    fi
    [ -n "$out" ] || out="$(grep -m 40 -E '"type": ?"user"' "$f" 2>/dev/null | jq -rn "$_OSRC_HUB_NAME_JQ"'
      first(inputs | select(.type == "user" and ((.isMeta // false) | not)) | .message.content
        | (if type == "string" then . elif type == "array" then ([.[] | select(.type == "text") | .text] | join(" ")) else "" end)
        | select(startswith("Caveat:") | not) | clean | select(length > 0) | short('"$n"')) // empty' 2>/dev/null)"
    if [ -n "$sz" ] && mkdir -p "$OSRC_HOME/hub/titles" 2>/dev/null && [ ! -L "$c" ]; then
      { if [ -n "$out" ]; then printf '%s %s\n' "$sz" "$out"; else printf '%s\n' "$sz"; fi; } > "$c.$$" 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null
      rm -f "$c.$$" 2>/dev/null
    fi
    printf '%s' "$out"; return 0
  done
  return 0
}

# _osrc_hub_name_finish <export-json> -> the export with final names. A project card's own name wins
# (_named). Otherwise the name is the project (_base); when several shown sessions share it, each gets
# " · <what it is doing>" (_detail), or " · session N" when that is missing or not unique. With no
# project, the detail alone names it. Never an id.
_osrc_hub_name_finish() {
  jq -c '
    def plabel: if (._base // "") != "" then ._base elif (._detail // "") != "" then ._detail else "Orchestrator session" end;
    .projects |= (. as $ps | [range(0; length)] | map(. as $i | $ps[$i] as $p
      | if ($p | has("_base")) then
          ($p | plabel) as $l
          | [$ps[] | select(has("_base") and plabel == $l)] as $grp
          | ([$ps[0:$i][] | select(has("_base") and plabel == $l)] | length + 1) as $n
          | ($p._detail // "") as $d
          | if ($grp | length) < 2 then $p + {name: $l}
            elif ($p._base // "") != "" and $d != "" and ([$grp[] | select((._detail // "") == $d)] | length) == 1 then $p + {name: ($l + " · " + $d)}
            else $p + {name: ($l + " · session \($n)")} end
        else $p end)
      | map(del(._base, ._detail)))'
}

_osrc_hub_daily_hint() {
  local d="$OSRC_HOME/hub" today
  today="$(date +%Y-%m-%d)"
  mkdir -p "$d" 2>/dev/null || return 0
  ( set -C; printf '%s\n' "$today" > "$d/hint-$today" ) 2>/dev/null || return 0
  printf 'Mission Control: outsourcerer mc\n' >&2
}

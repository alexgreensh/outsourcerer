# Mission Control names (MC2 r3): what a person would call the project. Never an owner/repo path, a URL,
# a session id or hex. Read without touching credential material.

# _osrc_hub_humanize <raw> -> "alexgreensh/total-recall-core.git" -> "Total Recall Core".
_osrc_hub_humanize() {
  local n="${1%/}"
  n="${n##*/}"; n="${n%.git}"
  printf '%s' "$n" | tr '_-' '  ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2); print }'
}

# _osrc_hub_repo_label <dir> -> the humanized git project of a folder (origin repo name, else the repo
# folder), or "" outside git. Shared by orchestrator names and the "Also running" rows (MC3).
_osrc_hub_repo_label() {
  local repo remote
  repo="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || repo=''
  [ -n "$repo" ] || return 0
  remote="$(git -C "$1" config --get remote.origin.url 2>/dev/null)"
  case "$remote" in *github.com[:/]*) remote="${remote##*github.com[:/]}" ;; ''|*://*|*@*) remote="" ;; esac
  _osrc_hub_humanize "${remote:-$repo}"
}

# _osrc_hub_derived_name <sid> -> the humanized project the session's owned lanes work in (git remote
# repo name, else the repo folder, else their one shared folder), or "" when that is unknown. The export
# adds what each session is doing when two shown sessions share a project (_osrc_hub_name_finish).
_osrc_hub_derived_name() {
  local sid="$1" f id dir repo common='' conflict=0
  for f in "$OSRC_HOME/owners/$sid"/* "$OSRC_HOME/hub/seen/$sid"/*; do   # seen: lanes that already ended (MC3)
    [ -f "$f" ] || continue
    id="${f##*/}"
    dir="$(jq -r '.worktree // .cwd // .path // ""' "$OSRC_JOBS/$id/meta.json" 2>/dev/null)"
    [ -n "$dir" ] || dir="$(jq -r '.cwd // .worktree // ""' "$OSRC_HOME/remote/$id.json" 2>/dev/null)"
    [ -n "$dir" ] || dir="$(jq -r --arg id "$id" 'select(.session_id == $id) | .cwd // empty' "${OSRC_SESSION_REGISTRY:-/dev/null}" 2>/dev/null | tail -1)"
    [ -n "$dir" ] || continue
    if [ -z "$common" ]; then common="${dir%/}"; elif [ "${common##*/}" != "$(basename "$dir")" ]; then conflict=1; fi
    repo="$(_osrc_hub_repo_label "$dir")"
    [ -n "$repo" ] || continue
    printf '%s' "$repo"; return 0
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

# agentclean: "[cloud] alexgreensh/total-recall-core 0163xupZjM" -> "Total Recall Core" (no tags, no owner/,
# no trailing id token). words($n): the first $n words, with an ellipsis when cut.
_OSRC_HUB_TITLE_JQ='def agentclean: gsub("\\[[^\\]]*\\]"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | split(" ") | (if length > 1 and (.[-1] | test("^(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{6,}$")) then .[:-1] else . end)
  | map(if test("/") then (split("/") | map(select(length > 0)) | last // "") else . end) | join(" ")
  | gsub("[-_]+"; " ") | split(" ") | map(select(length > 0) | (.[0:1] | ascii_upcase) + .[1:]) | join(" ");
def words($n): split(" ") | if length > $n then .[0:$n] | join(" ") | sub("[ ,;:.-]+$"; "") + "…" else join(" ") end;'

# _osrc_hub_session_detail <sid> -> the session's title (MC3 "Titles"): the LAST custom-title (/rename,
# wins unless it is a slug like "total-recall-85" or "osrc-orch2", MC4 idlike), else the last ai-title (Claude's own task title), else the last agent-name cleaned of
# tags/owner/ids, else the first real prompt cut to ~6 words; "" when nothing usable. Titles are appended,
# so only the transcript's tail is read (OSRC_HUB_TITLE_TAIL bytes, 4 MB); the first prompt comes from
# the first matching lines only. An old-format "summary" line is a last fallback after all four. Cached in $OSRC_HOME/hub/titles-v3/<sid> (v3: MC4 slug rule) as "<size> <text>"
# (transcripts only grow, so an unchanged size means an unchanged transcript).
_osrc_hub_session_detail() {
  local sid="$1" f c out='' t sz line n="${OSRC_HUB_DETAIL_LEN:-48}" tail_b="${OSRC_HUB_TITLE_TAIL:-4194304}" tl
  case "$sid" in ''|.*|*/*) return 0 ;; esac
  case "$tail_b" in ''|*[!0-9]*) tail_b=4194304 ;; esac
  c="$OSRC_HOME/hub/titles-v3/$sid"
  for f in "${OSRC_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"/*/"$sid".jsonl; do
    [ -f "$f" ] || continue
    sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null)"
    if [ -n "$sz" ] && [ -f "$c" ] && [ ! -L "$c" ]; then
      IFS= read -r line < "$c" 2>/dev/null || true
      [ "${line%% *}" = "$sz" ] && { [ "$line" = "$sz" ] || printf '%s' "${line#* }"; return 0; }
    fi
    tl="$(tail -c "$tail_b" "$f" 2>/dev/null | grep -E '"type": ?"(custom-title|ai-title|agent-name)"')"
    t="$(printf '%s\n' "$tl" | grep -E '"type": ?"custom-title"' | tail -1)"
    [ -z "$t" ] || out="$(jq -r "$_OSRC_HUB_NAME_JQ ${_OSRC_HUB_IDLIKE_JQ:-def idlike: false;}"' (.customTitle // "") | if idlike then "" else clean | short('"$n"') end' <<<"$t" 2>/dev/null)"
    if [ -z "$out" ]; then
      t="$(printf '%s\n' "$tl" | grep -E '"type": ?"ai-title"' | tail -1)"
      [ -z "$t" ] || out="$(jq -r "$_OSRC_HUB_NAME_JQ"' (.aiTitle // "") | clean | short('"$n"')' <<<"$t" 2>/dev/null)"
    fi
    if [ -z "$out" ]; then
      t="$(printf '%s\n' "$tl" | grep -E '"type": ?"agent-name"' | tail -1)"
      [ -z "$t" ] || out="$(jq -r "$_OSRC_HUB_NAME_JQ $_OSRC_HUB_TITLE_JQ ${_OSRC_HUB_IDLIKE_JQ:-def idlike: false;}"' (.agentName // "") | if idlike then "" else agentclean | clean | short('"$n"') end' <<<"$t" 2>/dev/null)"
    fi
    [ -n "$out" ] || out="$(grep -m 40 -E '"type": ?"user"' "$f" 2>/dev/null | jq -rn "$_OSRC_HUB_NAME_JQ $_OSRC_HUB_TITLE_JQ"'
      first(inputs | select(.type == "user" and ((.isMeta // false) | not)) | .message.content
        | (if type == "string" then . elif type == "array" then ([.[] | select(.type == "text") | .text] | join(" ")) else "" end)
        | select(startswith("Caveat:") | not) | clean | select(length > 0) | words(6)) // empty' 2>/dev/null)"
    if [ -z "$out" ]; then   # after all four sources: an old-format "summary" line, never above them
      t="$(tail -c "$tail_b" "$f" 2>/dev/null | grep -E '"type": ?"summary"' | tail -1)"
      [ -z "$t" ] || out="$(jq -r "$_OSRC_HUB_NAME_JQ"' (.summary // "") | clean | short('"$n"')' <<<"$t" 2>/dev/null)"
    fi
    if [ -n "$sz" ] && mkdir -p "$OSRC_HOME/hub/titles-v3" 2>/dev/null && [ ! -L "$c" ]; then
      { if [ -n "$out" ]; then printf '%s %s\n' "$sz" "$out"; else printf '%s\n' "$sz"; fi; } > "$c.$$" 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null
      rm -f "$c.$$" 2>/dev/null
    fi
    printf '%s' "$out"; return 0
  done
  return 0
}

# ptitle: "<Project> · <title>" (MC3 Titles). A title that already starts with the project name stands alone
# ("Outsourcerer 0.16.2", not "Outsourcerer · Outsourcerer 0.16.2"); either part alone when the other is empty.
_OSRC_HUB_PTITLE_JQ='def ptitle($b; $d): if $b != "" and $d != "" then (if ($d | ascii_downcase | startswith($b | ascii_downcase)) then $d else $b + " · " + $d end)
  elif $b != "" then $b elif $d != "" then $d else "" end;'

# _osrc_hub_join_title <project> <title> -> the same rule for a shell caller (the "Also running" rows).
_osrc_hub_join_title() { jq -rn --arg b "${1:-}" --arg d "${2:-}" "$_OSRC_HUB_PTITLE_JQ"' ptitle($b; $d)' 2>/dev/null; }

# _osrc_hub_name_finish <export-json> -> the export with final names. A project card's own name wins
# (hub report --name; such a project has no _base). Otherwise "<Project> · <title>" from _base (the repo or
# folder) and _detail (the session title, _osrc_hub_session_detail); when two shown sessions still read the
# same, each gets " · session N". Never an id.
_osrc_hub_name_finish() {
  jq -c "$_OSRC_HUB_PTITLE_JQ"'
    def plabel: ptitle(._base // ""; ._detail // "") | if . == "" then "Orchestrator session" else . end;
    .projects |= (. as $ps | [range(0; length)] | map(. as $i | $ps[$i] as $p
      | if ($p | has("_base")) then
          ($p | plabel) as $l
          | [$ps[] | select(has("_base") and plabel == $l)] as $grp
          | ([$ps[0:$i][] | select(has("_base") and plabel == $l)] | length + 1) as $n
          | if ($grp | length) < 2 then $p + {name: $l} else $p + {name: ($l + " · session \($n)")} end
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

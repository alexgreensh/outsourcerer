# lib/where.sh — cloud-first routing: should this brief run on a hosted session or on the Mac?
#
#   osrc_where <brief>  -> prints `cloud` or `local` on line 1, a one-line reason on line 2.
#
# Policy (L10): cloud by default — hosted sessions keep work off the user's machine (swap, load,
# tmux crashes). LOCAL only when the brief genuinely needs this machine: files outside the repo,
# local-only services/apps (WhatsApp bridge, browser, Mac GUI, local DBs), unpushed local commits,
# or the user said local. A brief that needs a local-only service stays local even when it also
# installs packages or runs heavy tests: the cloud box cannot reach localhost.
#
# Sourced by outsourcerer.sh; defines functions only, runs nothing at load time. Bash 3.2.

# _osrc_where_brief_text <arg...> -> the brief text. A lone argument that names a readable file
# (or @file) is read; anything else is treated as inline text.
_osrc_where_brief_text() {
  local arg="${1:-}" rest=""
  [ "$#" -gt 1 ] && { shift; rest=" $*"; }
  if [ -n "$rest" ]; then printf '%s%s' "$arg" "$rest"; return 0; fi
  case "$arg" in
    @*) arg="${arg#@}" ;;
  esac
  if [ -n "$arg" ] && [ -f "$arg" ]; then cat "$arg" 2>/dev/null; return 0; fi
  printf '%s' "$arg"
}

# _osrc_where_unpushed_count -> commits on HEAD not reachable from any remote ref (0 outside a
# repo or when git cannot answer). These are commits a hosted clone will never see.
_osrc_where_unpushed_count() {
  git rev-parse --git-dir >/dev/null 2>&1 || { printf '0'; return 0; }
  git rev-list --count HEAD --not --remotes 2>/dev/null || printf '0'
}

# osrc_where <brief-text-or-file> -> `cloud`|`local` + reason. Never fails; an empty brief routes
# local (there is nothing to send to a cloud box).
osrc_where() {
  local text lc reason="" decision="cloud"
  text="$(_osrc_where_brief_text "$@")"
  lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  if [ -z "${lc//[[:space:]]/}" ]; then
    printf 'local\nreason: empty brief — nothing to send to a hosted session\n'
    return 0
  fi
  # NOTE: match against $lc via herestrings, never `printf | grep -q` — grep -q exits early,
  # SIGPIPEs a large brief, and an inherited `set -o pipefail` (SHELLOPTS) would misread it.
  # --- LOCAL: the user said local ---------------------------------------------------------
  local action='(open|read|inspect|query|restart|connect to|access|use|run|launch|capture|summarize|pull|check|click|edit|update|write to|copy|probe|test|fetch|curl|ping|attach to)'
  local qualifier='((the|my|this|our|existing|latest|local|running|attached|physical|usb|on|at|from|to|in) +)*'
  local service='(whatsapp|browser|mac gui|gui app|applescript|appleevents|postgres(ql)?|mysql|mariadb|redis|mongodb|sqlite3?|tmux|iterm|screen session|database|db|webcam|camera|microphone|keychain)'
  local endpoint='((https?://)?(localhost|127[.]0[.]0[.]1|0[.]0[.]0[.]0))'
  local state='(/users/|/home/|~/|my (downloads|desktop|documents|pictures)|uncommitted changes|working tree|unpushed|local commits|files? outside (the )?(repo|repository))'
  if grep -qE 'keep (it|this|that|the work|everything|things) local|run( it| this)? locally|(run|execute|test|verify|install)( [[:alnum:]_-]+){0,4} on (my|this|the user.s) (mac|machine|computer|laptop)|do not use cloud|don.t use cloud|no cloud|not in the cloud|stay local|keep (it|this) on (my|the) (mac|machine)|offline only' <<<"$lc"; then
    decision="local"; reason="the brief says keep it local"
  elif grep -qE "(^|[^[:alnum:]_])${action} +${qualifier}(${service}([^[:alnum:]_]|$)|${endpoint}([^[:alnum:]_]|$)|${state})" <<<"$lc"; then
    decision="local"; reason="the requested operation needs a service, device or file on this machine"
  # --- LOCAL: unpushed commits the brief builds on -------------------------------------------
  elif [ "$( _osrc_where_unpushed_count )" != "0" ] \
    && grep -qE 'current branch|my (local )?(changes|commits|branch|work)|this checkout|working (dir|directory)|head of|tip of' <<<"$lc"; then
    decision="local"; reason="the brief builds on unpushed local commits a cloud clone cannot see"
  fi
  if [ "$decision" = "local" ]; then
    printf 'local\nreason: %s\n' "$reason"
    return 0
  fi
  # --- CLOUD (default): self-contained repo work belongs off the Mac -------------------------
  if grep -qE 'untrusted|third.party|external (repo|code|package)|install|npm ci|brew |curl |wget |heavy|full test suite|test suite|conformance|cargo (test|build)|npm (test|run build|ci)|pnpm |docker build|xcodebuild|gradle|pytest|vitest|jest|make test|hyperfine|benchmark|build from scratch|security audit' <<<"$lc"; then
    reason="hostile/heavy/install work always belongs on a hosted box, off the Mac"
  else
    reason="self-contained repo work — hosted session keeps it off this machine"
  fi
  printf 'cloud\nreason: %s\n' "$reason"
  return 0
}

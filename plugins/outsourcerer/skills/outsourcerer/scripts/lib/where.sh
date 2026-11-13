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
  # --- LOCAL: the user said local ---------------------------------------------------------
  if printf '%s' "$lc" | grep -qE 'keep (it|this|that|the work|everything|things) local|run( it| this)? locally|on my (mac|machine|laptop|computer)|this mac|my machine|do not use cloud|don.t use cloud|no cloud|not in the cloud|stay local|keep (it|this) on (my|the) (mac|machine)|offline only'; then
    decision="local"; reason="the brief says keep it local"
  # --- LOCAL: local-only services / apps the cloud box cannot reach ------------------------
  elif printf '%s' "$lc" | grep -qE 'whatsapp|\bbrowser\b|mac gui|\bgui app|apple(script|events)|\blocalhost\b|127\.0\.0\.1|0\.0\.0\.0|local (host )?(db|database)|postgres|postgresql|mysql|mariadb|redis|mongodb|\bsqlite3?\b|\btmux\b|\biterm\b|screen session'; then
    decision="local"; reason="the brief needs a local-only service or app (cloud boxes cannot reach this machine)"
  # --- LOCAL: files/state that only exist here ----------------------------------------------
  elif printf '%s' "$lc" | grep -qE '/users/|/home/|~/|files? (outside|outside of) (the )?(repo|repository)|outside (the )?(repo|repository)|outside the codebase|my (downloads|desktop|documents|pictures)|uncommitted changes|working tree|not pushed|unpushed|local commits'; then
    decision="local"; reason="the brief touches files or state that only exist on this machine"
  # --- LOCAL: unpushed commits the brief builds on -------------------------------------------
  elif [ "$( _osrc_where_unpushed_count )" != "0" ] \
    && printf '%s' "$lc" | grep -qE 'current branch|my (local )?(changes|commits|branch|work)|this checkout|working (dir|directory)|head of|tip of'; then
    decision="local"; reason="the brief builds on unpushed local commits a cloud clone cannot see"
  fi
  if [ "$decision" = "local" ]; then
    printf 'local\nreason: %s\n' "$reason"
    return 0
  fi
  # --- CLOUD (default): self-contained repo work belongs off the Mac -------------------------
  if printf '%s' "$lc" | grep -qE 'untrusted|third.party|external (repo|code|package)|install|npm ci|brew |curl |wget |heavy|full test suite|test suite|conformance|cargo (test|build)|npm (test|run build|ci)|pnpm |docker build|xcodebuild|gradle|pytest|vitest|jest|make test|hyperfine|benchmark|build from scratch|security audit'; then
    reason="hostile/heavy/install work always belongs on a hosted box, off the Mac"
  else
    reason="self-contained repo work — hosted session keeps it off this machine"
  fi
  printf 'cloud\nreason: %s\n' "$reason"
  return 0
}

#!/usr/bin/env bash
# Claude account helpers. Credential files are never opened by these functions.

_osrc_account_name_valid() {
  case "${1:-}" in ''|.|..|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}
_osrc_accounts() {
  local name dir extra seen=$'\ndefault\n' line
  printf 'default\t%s/.claude\n' "$HOME"
  while IFS=$'\t' read -r name dir extra; do
    _osrc_account_name_valid "$name" || continue
    case "$dir" in /*) ;; *) continue ;; esac
    [ -z "$extra" ] || continue
    case "$seen" in *$'\n'"$name"$'\n'*) continue ;; esac
    seen="$seen$name"$'\n'; printf '%s\t%s\n' "$name" "$dir"
  done 2>/dev/null < "${OSRC_HOME}/claude-accounts" || true
  if have hats; then
    # --paths avoids Hats' account and Keychain probes and prints explicit directories.
    while IFS=$'\t' read -r name dir extra; do
      _osrc_account_name_valid "$name" || continue
      case "$dir" in /*) ;; *) continue ;; esac
      [ -z "$extra" ] || continue
      case "$seen" in *$'\n'"$name"$'\n'*) continue ;; esac
      seen="$seen$name"$'\n'; printf '%s\t%s\n' "$name" "$dir"
    done <<EOF
$(hats ls --paths 2>/dev/null | awk -F '  +' 'NR > 1 && NF == 3 { n=$1; d=$3; sub(/ \([^)]*\)$/, "", n); sub(/^ +/, "", n); sub(/ +$/, "", n); sub(/^ +/, "", d); sub(/ +$/, "", d); print n "\t" d }')
EOF
  fi
}

_osrc_account_dir() {
  local name dir
  while IFS=$'\t' read -r name dir; do
    [ "$name" = "$1" ] && { printf '%s\n' "$dir"; return 0; }
  done <<EOF
$(_osrc_accounts)
EOF
  return 1
}

# These are account identities, transient sessions, caches, or possible secrets.
_osrc_account_shareable() {
  case "$1" in
    settings.json) return 0 ;; # Shared user configuration, not an account cache.
    .credentials.json|.claude.json|.env|.env.*|*.pem|*.key) return 1 ;; # Login, identity, and secret files.
    statsig|todos|shell-snapshots|ide|session-env) return 1 ;; # Per-account live state.
    *[Cc]redential*|*[Tt]oken*|*[Ss]ecret*|*[Aa]uth*|*[Kk]ey*) return 1 ;; # Possible credentials.
    *[Cc]ache*|*.lock|*.lock.*|*.json|*.jsonl) return 1 ;; # Cache, locks, and account-specific JSON.
    *) return 0 ;;
  esac
}

_osrc_account_links_add() {
  local name="$1" dir="$2" source="$HOME/.claude" path item manifest="$OSRC_HOME/claude-account-links/$1"
  [ -d "$source" ] || return 0
  mkdir -p "$OSRC_HOME/claude-account-links" || return 1
  [ ! -e "$manifest" ] && [ ! -L "$manifest" ] || return 1
  (umask 077; : > "$manifest") || return 1
  while IFS= read -r path; do
    item="${path##*/}"; _osrc_account_shareable "$item" || continue
    [ ! -e "$dir/$item" ] && [ ! -L "$dir/$item" ] || continue
    ln -s "$path" "$dir/$item" || return 1
    printf '%s\n' "$item" >> "$manifest" || return 1
  done <<EOF
$(find "$source" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
EOF
}

_osrc_account_links_check() {
  local name="$1" dir="$2" source="$HOME/.claude" path item actual drift=0
  [ -d "$source" ] || return 0
  while IFS= read -r path; do
    item="${path##*/}"; _osrc_account_shareable "$item" || continue
    actual="$(readlink "$dir/$item" 2>/dev/null)" || actual=""
    if [ "$actual" != "$path" ]; then printf 'drift: %s\n' "$item"; drift=1; fi
  done <<EOF
$(find "$source" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
EOF
  [ "$drift" = 0 ]
}

_osrc_account_links_remove() {
  local name="$1" dir="$2" item target manifest="$OSRC_HOME/claude-account-links/$1"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 0
  while IFS= read -r item; do
    case "$item" in ''|.|..|*/*) continue ;; esac
    target="$(readlink "$dir/$item" 2>/dev/null)" || continue
    [ "$target" = "$HOME/.claude/$item" ] && rm -f "$dir/$item"
  done < "$manifest"
  rm -f "$manifest"
}

cmd_accounts() {
  local action="${1:-list}" name dir usage c5 c7 tmp existing file="$OSRC_HOME/claude-accounts"
  case "$action" in
    list|ls)
      [ "$#" -le 1 ] || die "usage: accounts [list]"
      printf 'ACCOUNT\tWEEKLY LEFT\t5H LEFT\tBILLING\tCONFIG DIR\n'
      while IFS=$'\t' read -r name dir; do
        usage="$(_osrc_account_usage "$dir")" || usage='|'
        c5="${usage%%|*}"; c7="${usage#*|}"
        [ -z "$c5" ] || c5="$(awk -v n="$c5" 'BEGIN { printf "%g%%",100-n }')"
        [ -z "$c7" ] || c7="$(awk -v n="$c7" 'BEGIN { printf "%g%%",100-n }')"
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${c7:-unknown}" "${c5:-unknown}" "$(_osrc_account_billing "$dir")" "$dir"
      done <<EOF
$(_osrc_accounts)
EOF
      ;;
    check)
      [ "$#" -eq 2 ] || die "usage: accounts check <name>"
      dir="$(_osrc_account_dir "$2")" || die "accounts: unknown name"
      [ "$2" != default ] || die "accounts: default is the source"
      _osrc_account_links_check "$2" "$dir" || return 1
      printf 'accounts: %s links are current\n' "$2"
      ;;
    add|rm)
      name="${2:-}"; _osrc_account_name_valid "$name" && [ "$name" != default ] || die "accounts: invalid or reserved name"
      if [ "$action" = add ]; then
        [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || die "usage: accounts add <name> [absolute-dir]"
        [ ! -f "$file" ] || ! awk -F '\t' -v n="$name" '$1==n { found=1 } END { exit !found }' "$file" || die "accounts: name already exists"
        existing="$(_osrc_account_dir "$name" 2>/dev/null)" || existing=""
        dir="${3:-${existing:-$HOME/.claude-accounts/$name}}"; case "$dir" in /*) ;; *) die "accounts: directory must be an absolute path" ;; esac
        [ -z "$existing" ] || [ "$existing" = "$dir" ] || die "accounts: name belongs to a different Hats directory"
        case "$dir" in *$'\n'*|*$'\t'*|*$'\r'*) die "accounts: invalid directory" ;; esac
        [ "$dir" != "$HOME/.claude" ] || die "accounts: cannot register the default directory"
        mkdir -p "$dir" || die "accounts: cannot create directory"
        [ "$(cd "$dir" && pwd -P)" != "$(cd "$HOME/.claude" 2>/dev/null && pwd -P)" ] || die "accounts: cannot share into the default directory"
        _osrc_account_links_add "$name" "$dir" || die "accounts: cannot share configuration"
      else
        [ "$#" -eq 2 ] || die "usage: accounts rm <name>"
        [ -f "$file" ] && awk -F '\t' -v n="$name" '$1==n { found=1 } END { exit !found }' "$file" || die "accounts: name is not in registry"
        dir="$(_osrc_account_dir "$name")" || die "accounts: cannot resolve name"
      fi
      _mkdir_private "$OSRC_HOME" || die "accounts: cannot create state directory"
      [ ! -L "$file" ] || die "accounts: registry is a symlink"
      tmp="$OSRC_HOME/.claude-accounts.$$"
      ( umask 077; [ ! -f "$file" ] || awk -F '\t' -v n="$name" '$1!=n' "$file"; [ "$action" != add ] || printf '%s\t%s\n' "$name" "$dir" ) > "$tmp" || die "accounts: cannot update registry"
      mv -f "$tmp" "$file" || die "accounts: cannot update registry"
      if [ "$action" = rm ]; then _osrc_account_links_remove "$name" "$dir"; fi
      printf 'accounts: %s %s\n' "$action" "$name"
      [ "$action" != add ] || printf 'Run CLAUDE_CONFIG_DIR=%q claude once and use /login yourself.\n' "$dir"
      ;;
    *) die "usage: accounts [list|add <name> [absolute-dir]|check <name>|rm <name>]" ;;
  esac
}

_osrc_account_select() {
  local name="${OSRC_ACCOUNT:-}" dir specs
  if [ -z "$name" ]; then
    name="$(_osrc_accounts | _osrc_account_choose)" || die "no Claude account has known weekly headroom under the configured caps; use --account to select explicitly"
  fi
  dir="$(_osrc_account_dir "$name")" || die "unknown Claude account: $name"
  [ -d "$dir" ] || die "Claude account directory does not exist: $dir"
  specs="$(_osrc_cap_specs_for cc)"
  if [ -n "$specs" ]; then
    printf '%s\t%s\n' "$name" "$dir" | _osrc_account_choose >/dev/null || die "Claude account $name has unknown usage or is at a configured cap"
  fi
  OSRC_ACCOUNT="$name"; OSRC_ACCOUNT_DIR="$dir"; export OSRC_ACCOUNT
}

_session_launch_cc() {
  have claude || die "claude not on PATH (needed for a claude session)"
  [ "$MODEL_EXPLICIT" = "1" ] && _session_assert_model_pinnable cc claude --help
  SESSION_LAUNCH=("env" "-u" "CLAUDECODE" "-u" "CLAUDE_CODE_ENTRYPOINT" "-u" "CLAUDE_CODE_SESSION_ID" "-u" "CLAUDE_CODE_CHILD_SESSION" "-u" "CLAUDE_CODE_EXECPATH")
  [ -n "${OSRC_ACCOUNT_DIR:-}" ] && SESSION_LAUNCH+=("CLAUDE_CONFIG_DIR=$OSRC_ACCOUNT_DIR")
  [ -n "$EFFORT" ] && SESSION_LAUNCH+=("MAX_THINKING_TOKENS=$(_effort_thinking_tokens "$EFFORT")")
  SESSION_LAUNCH+=("claude")
  [ "$MODEL_EXPLICIT" = "1" ] && SESSION_LAUNCH+=("--model" "$MODEL")
  local _ccflag; _ccflag="$(_cc_effort_flag "${EFFORT:-}")"
  if [ -n "$_ccflag" ] && _session_cc_effort_supported; then SESSION_LAUNCH+=("--effort" "$_ccflag"); fi
}

_osrc_account_usage() {
  local dir="$1" file="$1/token-optimizer/rate-limits.json" raw c5 r5 c7 r7 ts now
  [ -f "$file" ] && have jq || return 1
  raw="$(jq -r '[(.five_hour.used_percentage // ""),(.five_hour.resets_at // ""),(.seven_day.used_percentage // ""),(.seven_day.resets_at // ""),(.timestamp // "")] | join("|")' "$file" 2>/dev/null)" || return 1
  IFS='|' read -r c5 r5 c7 r7 ts <<EOF
$raw
EOF
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)" || return 1
  [ "$ts" -le $((now * 1000)) ] && [ $((now * 1000 - ts)) -le 600000 ] || return 1
  c5="$(_window_pct "$c5" "$r5" 2>/dev/null)" || c5=""
  c7="$(_window_pct "$c7" "$r7" 2>/dev/null)" || c7=""
  [ -n "$c5$c7" ] || return 1
  printf '%s|%s\n' "$c5" "$c7"
}

# The only authentication data inspected is the CLI's status JSON.
_osrc_account_billing() { OSRC_ACCOUNT_DIR="$1" osrc_lane_billing cc; }

_osrc_account_console() {
  local status
  have claude && have jq || return 1
  status="$(_osrc_envrun -u CLAUDECODE _timeout "${OSRC_BRIEF_TIMEOUT:-5}" claude auth status 2>/dev/null)" || return 1
  jq -e '.loggedIn == true and (.authMethod == "console" or .authMethod == "apiKey" or .authMethod == "api_key" or .apiKeySource != null or (.apiProvider != null and .apiProvider != "firstParty"))' >/dev/null 2>&1 <<<"$status"
}

# Choose the smallest weekly usage. Unknown windows cannot satisfy a bound cap.
_osrc_account_choose() {
  local name dir usage c5 c7 spec meter window value cap best="" bestpct=""
  while IFS=$'\t' read -r name dir; do
    _osrc_account_name_valid "$name" && [ -d "$dir" ] || continue
    usage="$(_osrc_account_usage "$dir")" || continue
    c5="${usage%%|*}"; c7="${usage#*|}"
    [ -n "$c7" ] || continue
    local allowed=1
    while IFS= read -r spec; do
      _osrc_cap_valid "$spec" || continue
      meter="${spec%%<=*}"; cap="${spec##*<=}"
      window="$(_osrc_cap_window cc "$meter" 2>/dev/null)" || continue
      case "$window" in claude5h) value="$c5" ;; claude7d) value="$c7" ;; *) continue ;; esac
      [ -n "$value" ] && awk -v a="$value" -v b="$cap" 'BEGIN { exit !(a+0 < b+0) }' || allowed=0
    done <<EOF
$(_osrc_cap_specs_for cc)
EOF
    [ "$allowed" = 1 ] || continue
    if [ -z "$best" ] || awk -v a="$c7" -v b="$bestpct" 'BEGIN { exit !(a+0 < b+0) }'; then
      best="$name"; bestpct="$c7"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

osrc_lane_summary() {
  local base rows name dir usage c5 c7 bill state left used
  base="$(_osrc_lane_summary_base --json)" || return 1
  have jq || { printf '%s\n' "$base"; return; }
  rows='[]'
  if have claude; then
    while IFS=$'\t' read -r name dir; do
      [ "$name" != default ] || continue
      bill="$(_osrc_account_billing "$dir")"
      usage="$(_osrc_account_usage "$dir")" || usage='|'
      c5="${usage%%|*}"; c7="${usage#*|}"; used="$c7"
      [ -n "$c5" ] && { [ -z "$used" ] || awk -v a="$c5" -v b="$used" 'BEGIN { exit !(a>b) }'; } && used="$c5"
      state=unknown; left='not checked yet'
      if [ -n "$used" ]; then
        left="$(awk -v p="$used" 'BEGIN { printf "%g%% left",100-p }')"; state=ok
        awk -v p="$used" -v t="${OSRC_CONSERVE_THRESHOLD:-50}" 'BEGIN { exit !(p>=t) }' && state=low
        awk -v p="$used" -v t="$(_osrc_limit_threshold)" 'BEGIN { exit !(p>=t) }' && state=out
      fi
      rows="$(jq -cn --argjson a "$rows" --arg n "$name" --arg b "$bill" --arg s "$state" --arg l "$left" --arg c5 "$c5" --arg c7 "$c7" --arg u "$used" '$a + [{id:("claude-"+$n), name:("Claude ("+$n+")"), lane:"cc", order:0, state:$s, left:$l, billing:$b, paid:($b != "subscription"), used:(if $u == "" then null else ($u|tonumber) end), windows:({} + (if $c5 == "" then {} else {claude5h:{used:($c5|tonumber),left:(100-($c5|tonumber))}} end) + (if $c7 == "" then {} else {claude7d:{used:($c7|tonumber),left:(100-($c7|tonumber))}} end)), source:"outsourcerer"}]')" || return 1
    done <<EOF
$(_osrc_accounts)
EOF
  fi
  if [ "${1:-}" = --json ]; then
    jq -cn --argjson b "$base" --argjson a "$rows" '$b + $a'
  else
    _osrc_lane_summary_base
    jq -r '.[] | [.id,.name,.state,.left,.billing] | @tsv' <<<"$rows"
  fi
}

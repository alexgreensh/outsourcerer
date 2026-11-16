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

# Only explicit shared configuration is linked; identity and session state stay local.
_osrc_account_shareable() {
  case "$1" in
    settings.json) return 0 ;; # Shared preferences and hooks.
    CLAUDE.md) return 0 ;; # Shared instructions.
    skills) return 0 ;; # Shared skills.
    agents) return 0 ;; # Shared agent definitions.
    commands) return 0 ;; # Shared commands.
    hooks) return 0 ;; # Shared hook definitions.
    plugins) return 0 ;; # Shared plugins.
    projects) return 0 ;; # Shared project memory.
    references) return 0 ;; # Shared reference material.
    token-optimizer) return 1 ;; # Usage belongs to each account.
    *) return 1 ;;
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
        local physical source; physical="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dir")" || die "accounts: cannot resolve directory"
        source="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HOME/.claude")" || die "accounts: cannot resolve default directory"
        case "$physical" in "$source"|"$source"/*) die "accounts: cannot share into the default directory or its descendants" ;; esac
        mkdir -p "$dir" || die "accounts: cannot create directory"
        _mkdir_private "$OSRC_HOME" || die "accounts: cannot create state directory"
        [ ! -L "$file" ] || die "accounts: registry is a symlink"
        [ ! -e "$OSRC_HOME/claude-account-links/$name" ] && [ ! -L "$OSRC_HOME/claude-account-links/$name" ] || die "accounts: link manifest already exists"
        _osrc_account_links_add "$name" "$dir" || { _osrc_account_links_remove "$name" "$dir"; die "accounts: cannot share configuration"; }
      else
        [ "$#" -eq 2 ] || die "usage: accounts rm <name>"
        [ -f "$file" ] && awk -F '\t' -v n="$name" '$1==n { found=1 } END { exit !found }' "$file" || die "accounts: name is not in registry"
        dir="$(_osrc_account_dir "$name")" || die "accounts: cannot resolve name"
      fi
      _mkdir_private "$OSRC_HOME" || die "accounts: cannot create state directory"
      [ ! -L "$file" ] || die "accounts: registry is a symlink"
      tmp="$OSRC_HOME/.claude-accounts.$$"
      ( umask 077; [ ! -f "$file" ] || awk -F '\t' -v n="$name" '$1!=n' "$file"; [ "$action" != add ] || printf '%s\t%s\n' "$name" "$dir" ) > "$tmp" || { [ "$action" != add ] || _osrc_account_links_remove "$name" "$dir"; die "accounts: cannot update registry"; }
      mv -f "$tmp" "$file" || { rm -f "$tmp"; [ "$action" != add ] || _osrc_account_links_remove "$name" "$dir"; die "accounts: cannot update registry"; }
      if [ "$action" = rm ]; then _osrc_account_links_remove "$name" "$dir"; fi
      printf 'accounts: %s %s\n' "$action" "$name"
      [ "$action" != add ] || printf 'Run CLAUDE_CONFIG_DIR=%q claude once and use /login yourself.\n' "$dir"
      ;;
    *) die "usage: accounts [list|add <name> [absolute-dir]|check <name>|rm <name>]" ;;
  esac
}

_osrc_account_select() {
  local name="${OSRC_ACCOUNT:-}" dir
  if [ -z "$name" ]; then
    name="$(_osrc_accounts | _osrc_account_choose)" || { _osrc_account_has_caps && die "no Claude account has known usage under the configured caps"; name=default; }
  fi
  dir="$(_osrc_account_dir "$name")" || die "unknown Claude account: $name"
  [ "$name" = default ] || [ -d "$dir" ] || die "Claude account directory does not exist: $dir"
  if _osrc_account_has_caps; then
    printf '%s\t%s\n' "$name" "$dir" | _osrc_account_choose allow-metered >/dev/null || die "Claude account $name has unknown usage or is at a configured cap"
  fi
  OSRC_ACCOUNT="$name"; OSRC_ACCOUNT_DIR="$dir"
  [ "$name" != default ] || OSRC_ACCOUNT_DIR=""
}

_osrc_account_has_caps() {
  local spec
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" && _osrc_cap_window cc "${spec%%<=*}" >/dev/null 2>&1 && return 0
  done <<EOF
$(_osrc_cap_specs_for cc)
EOF
  return 1
}

# _session_launch_cc lives in lib/leanlaunch.sh; it adds CLAUDE_CONFIG_DIR when OSRC_ACCOUNT_DIR is set.

_osrc_account_usage() {
  local dir="$1" file raw c5 r5 c7 r7 ts now
  local files=("$dir/token-optimizer/rate-limits.json")
  if [ "$dir" = "$HOME/.claude" ] && [ -n "${OSRC_CC_PRESSURE:-}" ]; then
    c5="$(_pct_normalize "$OSRC_CC_PRESSURE")"; [ -n "$c5" ] || return 1
    printf '%s|\n' "$c5"; return 0
  fi
  [ "$dir" != "$HOME/.claude" ] || files=("$OSRC_HOME/rate-limits.json" "${files[@]}")
  have jq || return 1
  for file in "${files[@]}"; do
  [ -f "$file" ] || continue
  raw="$(jq -r '[(.five_hour.used_percentage // ""),(.five_hour.resets_at // ""),(.seven_day.used_percentage // ""),(.seven_day.resets_at // ""),(.timestamp // "")] | join("|")' "$file" 2>/dev/null)" || continue
  IFS='|' read -r c5 r5 c7 r7 ts <<EOF
$raw
EOF
  case "$ts" in ''|*[!0-9]*) continue ;; esac
  now="$(date +%s)" || return 1
  [ "$ts" -le $((now * 1000)) ] && [ $((now * 1000 - ts)) -le 600000 ] || continue
  c5="$(_window_pct "$c5" "$r5" 2>/dev/null)" || c5=""
  c7="$(_window_pct "$c7" "$r7" 2>/dev/null)" || c7=""
  [ -n "$c5$c7" ] || continue
  printf '%s|%s\n' "$c5" "$c7"; return 0
  done
  return 1
}

# Use the existing billing gate, with the selected account scoped to the probe.
_osrc_account_billing() {
  if [ "$1" = "$HOME/.claude" ]; then OSRC_ACCOUNT_DIR= osrc_lane_billing cc
  else OSRC_ACCOUNT_DIR="$1" osrc_lane_billing cc; fi
}

_osrc_account_console() {
  local status
  have claude && have jq || return 1
  status="$(_osrc_envrun -u CLAUDECODE _timeout "${OSRC_BRIEF_TIMEOUT:-5}" claude auth status 2>/dev/null)" || return 1
  jq -e '.loggedIn == true and (.authMethod == "console" or .authMethod == "apiKey" or .authMethod == "api_key" or .apiKeySource != null or (.apiProvider != null and .apiProvider != "firstParty"))' >/dev/null 2>&1 <<<"$status"
}

# Prefer usable plan accounts, then approved paid accounts; spent accounts are last.
_osrc_account_choose() {
  local name dir usage c5 c7 spec meter window value cap best="" bestpct="" bill threshold spent rank best_rank=99 pct
  threshold="$(_osrc_limit_threshold)"
  while IFS=$'\t' read -r name dir; do
    _osrc_account_name_valid "$name" || continue
    [ "$name" = default ] || [ -d "$dir" ] || continue
    bill="$(_osrc_account_billing "$dir")"
    if [ "$bill" != subscription ] && [ "${OSRC_SPEND_OK:-0}" != 1 ] && [ "${1:-}" != allow-metered ]; then continue; fi
    usage="$(_osrc_account_usage "$dir")" || usage='|'
    c5="${usage%%|*}"; c7="${usage#*|}"
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
    spent=0
    for pct in "$c5" "$c7"; do
      [ -z "$pct" ] || ! awk -v p="$pct" -v t="$threshold" 'BEGIN { exit !(p+0 >= t+0) }' || spent=1
    done
    rank=0; [ "$bill" = subscription ] || rank=1
    [ "$spent" = 0 ] || rank=$((rank + 2))
    if [ "$rank" -lt "$best_rank" ] || { [ "$rank" -eq "$best_rank" ] && [ -n "$c7" ] && { [ -z "$bestpct" ] || awk -v a="$c7" -v b="$bestpct" 'BEGIN { exit !(a+0 < b+0) }'; }; }; then
      best="$name"; bestpct="$c7"; best_rank="$rank"
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
      state=unknown; left='No reading'   # PL: never "not checked yet"; the note says why
      if [ -n "$used" ]; then
        left="$(awk -v p="$used" 'BEGIN { printf "%g%% left",100-p }')"; state=ok
        awk -v p="$used" -v t="${OSRC_CONSERVE_THRESHOLD:-50}" 'BEGIN { exit !(p>=t) }' && state=low
        awk -v p="$used" -v t="$(_osrc_limit_threshold)" 'BEGIN { exit !(p>=t) }' && state=out
      fi
      rows="$(jq -cn --argjson a "$rows" --arg n "$name" --arg b "$bill" --arg s "$state" --arg l "$left" --arg c5 "$c5" --arg c7 "$c7" --arg u "$used" '$a + [{id:("claude-"+$n), name:("Claude ("+$n+")"), lane:"cc", order:0, state:$s, left:$l, updated:(now|todate), note:(if $u == "" then "No statusline reading for this account in the last 10 minutes; Claude Code reports one on its next turn under this account." else null end), billing:$b, paid:($b != "subscription"), used:(if $u == "" then null else ($u|tonumber) end), windows:({} + (if $c5 == "" then {} else {claude5h:{used:($c5|tonumber),left:(100-($c5|tonumber))}} end) + (if $c7 == "" then {} else {claude7d:{used:($c7|tonumber),left:(100-($c7|tonumber))}} end)), source:"outsourcerer"}]')" || return 1
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

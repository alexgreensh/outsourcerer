# Shared plan display helpers.

_lane_plan_limit_re() {
  case "$(_lane_plan_key "${1:-}")" in
    cx)     printf '%s' "$_CX_PLAN_LIMIT_RE" ;;
    cc)     printf '%s' "$_CC_PLAN_LIMIT_RE" ;;
    cursor) printf '%s' "$_CURSOR_PLAN_LIMIT_RE" ;;
    warp)   printf '%s' "$_WARP_PLAN_LIMIT_RE" ;;
    droid)  printf '%s' "$_DROID_PLAN_LIMIT_RE" ;;
    cline)  printf '%s' "$_CLINE_PLAN_LIMIT_RE" ;;
    opencode) printf '%s' "$_OPENCODE_PLAN_LIMIT_RE" ;;
    *)      printf '' ;;
  esac
}

_lane_plan_display() {
  case "$(_lane_plan_key "${1:-}")" in
    dv) printf 'Devin' ;; cx) printf 'Codex (ChatGPT plan)' ;; cc) printf 'Claude Code (Claude plan)' ;;
    warp) printf 'Warp (Oz)' ;; droid) printf 'Droid (Factory)' ;; cursor) printf 'Cursor' ;;
    cline) printf 'Cline' ;; pi) printf 'Pi' ;; gm) printf 'Gemini CLI' ;; or) printf 'OpenRouter (cash)' ;;
    tokenrouter) printf 'TokenRouter (cash)' ;; grokbot) printf 'Grok Bot' ;; claudex) printf 'Claudex proxy' ;; local) printf 'local' ;;
    opencode) printf 'OpenCode Go' ;;
    *) printf '%s' "${1:-?}" ;;
  esac
}

_lane_plan_usage_hint() {
  case "$(_lane_plan_key "${1:-}")" in
    cx)     printf 'Live figure: /status or /usage inside codex.' ;;
    cc)     printf 'Live figure: /usage inside Claude Code.' ;;
    warp)   printf 'Live figure: Warp Settings > AI usage.' ;;
    droid)  printf 'Live figure: /limits inside droid (toggle Droid Core / Extra Usage there), or Settings > Usage.' ;;
    cursor) printf 'Live figure: the Cursor dashboard (Settings > Usage).' ;;
    cline)  printf 'Live figure: your Cline account / provider dashboard.' ;;
    pi)     printf 'Live figure: the dashboard of whatever Pi is signed in to.' ;;
    grokbot) printf 'Live figure: Grok Bot settings > Usage (weekly allowance).' ;;
    opencode) printf 'Live figure: OpenCode Console (per-model monthly + 5h/weekly windows).' ;;
    *)      printf '' ;;
  esac
}

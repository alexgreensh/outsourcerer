# lib/cloudrun.sh — hosted-session ("cloud") delegation: the agent runs on someone else's
# machine (Claude cloud, Devin cloud, Codex cloud) and returns a branch. This is NOT the
# _cloud_* gate, which means "repo content sent to a remote model API"; hosted sessions clone
# the repo on a vendor VM. The existing secret scan + consent are reused unchanged.
#
#   cloud start <id> --repo <owner/name|git-url|path> --base <branch> --brief <file>
#                 [--vehicle claude|devin|codex|auto] [--where auto|cloud|local]
#                 [--done-when check:"CMD"] [--env <codex-env-id>] [--claude-env <ccpool-id>]
#                 [--model <m>]
#   cloud where <brief-text-or-file>   -> the osrc_where routing decision, explained
#   cloud ls                            -> registered remote lanes (vehicle + state)
#
# Done contract: the pack orders the agent to push branch cloud/<id> and commit <id>.READY at
# the tip. The lane is registered with L2's `lane add` when present (contract: $OSRC_HOME/
# remote/<id>.json + _owner_record), else a compatible json is written directly. The done
# contract is registered with L6's osrc_done_set when present (a generated check: that clones
# the branch and verifies <id>.READY at the tip). Both degrade to a printed note when absent.
#
# Sourced by outsourcerer.sh; defines functions only, runs nothing at load time. Bash 3.2.

# _cloudrun_id_ok <id> -> lane ids become path components, ref names and file names.
_cloudrun_id_ok() {
  case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# _cloudrun_now -> epoch seconds (OSRC_NOW override, same convention as lib/remote.sh).
_cloudrun_now() { if [ -n "${OSRC_NOW:-}" ]; then printf '%s' "$OSRC_NOW"; else date +%s; fi; }

# _cloudrun_rdir / _cloudrun_cdir -> remote-lane state dir (shared with L2) / cloud state dir.
_cloudrun_rdir() { printf '%s/remote' "$OSRC_HOME"; }
_cloudrun_cdir() { printf '%s/cloud' "$OSRC_HOME"; }

# ---- repo resolution -------------------------------------------------------------------------
# _cloudrun_repo_parse <repo-arg> -> "<transport>\t<fetch-url>\t<display>"
# transport gh = GitHub owner/name (fetch via https URL); git = any git URL or local path.
_cloudrun_repo_parse() {
  local r="${1:-}" url cu
  case "$r" in ''|*[[:space:]]*) return 1 ;; esac
  case "$r" in
    *://*|git@*|/*|.*|*//*)
      if [ -d "$r" ]; then
        # A local path is only the launch cwd; the cloud box clones the ORIGIN url, so that is
        # what the pack must name (a local path would also trip the private-path check).
        if [ "$(git -C "$r" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
          url="$(cd "$r" && pwd)"; printf 'git\t%s\t%s' "$url" "$url"; return 0
        fi
        url="$(git -C "$r" remote get-url origin 2>/dev/null)" || url="$r"
        cu="$(_osrc_url_clean "$url")"; printf 'git\t%s\t%s' "$cu" "$cu"; return 0
      fi
      case "$r" in *://*|git@*) cu="$(_osrc_url_clean "$r")"; printf 'git\t%s\t%s' "$cu" "$cu"; return 0 ;; esac
      return 1 ;;
  esac
  case "$r" in
    */*/*|*..*) return 1 ;;   # deeper paths and dot segments are not guessed
    */*) printf 'gh\thttps://github.com/%s.git\t%s' "$r" "$r"; return 0 ;;
  esac
  return 1
}

# _cloudrun_repo_match <repo-arg> <toplevel> -> rc0 when the cwd repo IS the --repo target.
# Hosted vehicles clone the repo of the directory they run in, so a mismatch means the session
# would work on the wrong code.
_cloudrun_repo_match() {
  local arg="$1" top="$2" origin norm_arg norm_origin at
  origin="$(_osrc_url_clean "$(git -C "$top" remote get-url origin 2>/dev/null)")" || return 1
  norm_origin="$(printf '%s' "$origin" | sed -E 's#^(https?://|git@[^:]*:|ssh://[^/]*/)##; s#\.git$##; s#/$##')"
  case "$arg" in
    /*|./*|../*|.*)
      # local path (absolute or relative): it must BE this checkout — compare toplevels so
      # `.`, `..` and subdir spellings all resolve correctly.
      [ -d "$arg" ] || return 1
      at="$(git -C "$arg" rev-parse --show-toplevel 2>/dev/null)" || return 1
      [ "$(cd "$at" 2>/dev/null && pwd -P)" = "$(cd "$top" 2>/dev/null && pwd -P)" ] && return 0
      return 1 ;;
    *://*|git@*)
      norm_arg="$(_osrc_url_clean "$arg" | sed -E 's#^(https?://|git@[^:]*:|ssh://[^/]*/)##; s#\.git$##; s#/$##')" ;;
    */*/*|*..*) return 1 ;;
    */*) norm_arg="$arg" ;;
    *) return 1 ;;
  esac
  [ "$norm_origin" = "$norm_arg" ] && return 0
  case "$norm_origin" in *"/$norm_arg") return 0 ;; esac
  return 1
}

# _cloudrun_fetch_url <transport> <url> -> URL git can ls-remote/clone.
# The parser already hands back a full URL for owner/name; wrapping it again built
# https://github.com/https://github.com/o/n.git.git (seen 2026-11-19), so only a bare owner/name is wrapped.
_cloudrun_fetch_url() {
  case "$2" in *://*|git@*) printf '%s' "$2"; return 0 ;; esac
  if [ "$1" = gh ]; then printf 'https://github.com/%s.git' "$2"; else printf '%s' "$2"; fi
}

# ---- preflight --------------------------------------------------------------------------------
# _cloudrun_preflight <fetch-url> <base> <toplevel> -> rc0 when the hosted clone can do the work.
_cloudrun_preflight() {
  local url="$1" base="$2" top="$3" out n dirty
  have git || die "cloud start needs git"
  out="$(git ls-remote "$url" "refs/heads/$base" 2>&1)" || die "cloud preflight: cannot reach $url (git ls-remote failed): $(printf '%s' "$out" | tail -1)"
  [ -n "$out" ] || die "cloud preflight: base branch '$base' does not exist on the remote — pick a pushed base; this tool never pushes for you"
  _CLOUDRUN_BASE_TIP="$(printf '%s\n' "$out" | awk 'NR==1{print $1}')"   # the HEAD guard reuses it
  # Work the cloud box cannot see: commits on HEAD reachable from no remote ref.
  n="$(git -C "$top" rev-list --count HEAD --not --remotes 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" != "0" ]; then
    printf 'cloud preflight: %s commit(s) on HEAD are not on ANY remote ref — a hosted clone cannot see them:\n' "$n" >&2
    git -C "$top" log --format='%h %s' HEAD --not --remotes 2>/dev/null | head -10 | sed 's/^/  /' >&2
    die "push them yourself first (this tool never pushes), or run the work locally"
  fi
  # Dirty tree is a warning, not a refusal: the pack is self-contained and the clone is remote.
  dirty="$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  [ "${dirty:-0}" != "0" ] && printf '>>> [cloud] note: %s uncommitted file(s) in this checkout will NOT reach the hosted session\n' "$dirty" >&2
  return 0
}

# ---- context pack ------------------------------------------------------------------------------
# _cloudrun_pack <id> <repo-display> <base> <branch> <brief-file> <done-when> -> writes the
# self-contained brief the cloud box receives (it has no access to this machine) and prints path.
_cloudrun_pack() {
  local id="$1" repo="$2" base="$3" branch="$4" brief="$5" donewhen="${6:-}" pin="${7:-}" dir f task sha
  dir="$(_cloudrun_cdir)"; _mkdir_private "$dir" 2>/dev/null || die "cloud: cannot create $dir"
  f="$dir/$id.pack.md"
  task="$(cat "$brief" 2>/dev/null)"
  [ -n "$task" ] || die "cloud: brief file is empty: $brief"
  # Pin the exact commit the delegator is looking at (--sha carries an offer's pinned sha
  # through so it cannot drift to a newer HEAD); the RESULT must echo it back so a verdict
  # can never silently describe different code than the one on this machine.
  sha="${pin:-$(git rev-parse HEAD 2>/dev/null)}"; sha="${sha:-unknown}"
  {
    printf '# Hosted-session task: %s\n\n' "$id"
    printf 'repo: %s\nbase branch: %s\nwork branch: %s\npinned commit: %s\n\n' "$repo" "$base" "$branch" "$sha"
    printf '## Task\n\n%s\n\n' "$task"
    printf '## Contract\n\n'
    printf -- '- Clone %s and base your work on branch `%s` (it contains commit `%s`).\n' "$repo" "$base" "$sha"
    printf -- '- Do ALL work on a new branch `%s` and push it when done.\n' "$branch"
    printf -- '- Your final commit MUST add a file `%s.READY` at the repository root containing exactly one line: `READY %s`.\n' "$id" "$id"
    printf -- '- Also write `%s.RESULT` at the repository root: first line `sha=%s` (this pinned commit, not your own head), second line `rc=0` only if your work is complete AND every check you ran passed, else the failing exit code (a red check is never rc=0, even if you believe it predates you), then a short summary naming your own head commit.\n' "$id" "$sha"
    printf -- '- If your environment can open pull requests, open one from `%s` to `%s`. Do NOT merge it.\n' "$branch" "$base"
    [ -n "$donewhen" ] && printf -- '- Additional done check requested by the delegator: `%s`\n' "$donewhen"
    printf -- '- Testing discipline: run only the unit tests relevant to your change, one at a time, niced; leave full/heavy suites to CI — heavy suites run in dedicated cloud lanes.\n'
    printf -- "- You have NO access to the delegator's machine, files, or credentials. Everything you need is in this message.\n"
    printf -- '- Do not ask questions back; make reasonable choices and record them.\n\n'
    printf '## Report\n\nEnd your run with: files changed, the branch you pushed, the PR link if any, and anything you could not do.\n'
  } > "$f" 2>/dev/null || die "cloud: cannot write pack $f"
  chmod 600 "$f" 2>/dev/null || true
  printf '%s' "$f"
}

# _cloudrun_private_check <pack-file> -> rc0 clean; rc1 + printed hits when the pack leaks
# machine-local paths or denylisted private names. The "private-name check" from the brief:
# no pre-existing implementation was found in the repo, so this checks (a) absolute home paths
# the cloud box cannot resolve and (b) names listed in $OSRC_HOME/cloud-private-names.txt
# (one per line, # comments, case-insensitive substring match).
# _cloudrun_path_generic <token> -> rc0 when a home path ("~/..", "/Users/..", "/home/..", or a
# Windows "C:\Users\..") is a template, not a real path: every user-specific segment is a
# <placeholder>. User-specific = the user name and the first folder under home, unless that folder
# is an app folder (a dot-folder, AppData, Library). At least one segment must be a placeholder.
# `~/notes.md`, `/Users/bob/x`, `~/clients/acme/<file>` and `C:\Users\bob\x` stay blocked.
_cloudrun_path_generic() {
  local t="${1//\\//}" rest seg first ph=0
  case "$t" in
    '~/'*) rest="${t#'~/'}" ;;
    /Users/*|/home/*|[A-Za-z]:/[Uu][Ss][Ee][Rr][Ss]/*) rest="${t#*/*/}"; seg="${rest%%/*}"; rest="${rest#*/}"
      case "$seg" in \<*\>) ph=1 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "/$rest/" in */../*) return 1 ;; esac
  first="${rest%%/*}"
  case "$first" in ''|\<*\>|.?*|AppData|Library) ;; *) return 1 ;; esac
  local IFS=/
  for seg in $rest; do
    case "$seg" in \<[A-Za-z0-9_.-]*\>) ph=1 ;; esac
  done
  [ "$ph" = 1 ]
}

_cloudrun_private_check() {
  local f="$1" pf="$OSRC_HOME/cloud-private-names.txt" line pat hits=0 tok bad
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bad=0
    if [ -n "$HOME" ] && grep -qF -- "$HOME" <<<"$line"; then bad=1
    elif grep -qE '/Users/|/home/|~/|[A-Za-z]:[\\/][Uu][Ss][Ee][Rr][Ss][\\/]' <<<"$line"; then
      while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        _cloudrun_path_generic "$tok" || bad=1
      done < <(grep -oE '([A-Za-z]:[\\/][Uu][Ss][Ee][Rr][Ss][\\/]|/Users/|/home/|~/)[^[:space:]`"'"'"'),;]*' <<<"$line")
    fi
    if [ "$bad" = 1 ]; then
      printf 'PRIVATE PATH: pack contains a machine-local path the cloud box cannot see: %s\n' "$(printf '%s' "$line" | cut -c1-160)" >&2
      hits=1
    fi
  done < "$f"
  if [ -f "$pf" ] && [ ! -L "$pf" ]; then
    while IFS= read -r pat; do
      case "$pat" in ''|\#*) continue ;; esac
      if grep -qiF -- "$pat" "$f" 2>/dev/null; then
        printf 'PRIVATE NAME: pack contains denylisted name (from %s): %s\n' "$pf" "$pat" >&2
        hits=1
      fi
    done < "$pf"
  fi
  return "$hits"
}

# ---- consent: hosted sessions get their OWN key ---------------------------------------------
# The model-API consent file ($OSRC_HOME/cloud-consent) and OSRC_CLOUD_ACK/--cloud-ack do NOT apply
# here: they consent to "code sent to a remote model API", a different disclosure than "a hosted
# agent runs on a vendor VM". Session consent lives in $OSRC_HOME/cloud-session-consent, granted
# interactively or via `cloud consent grant`; no env var can imply it.
_cloudrun_consent_file() { printf '%s/cloud-session-consent' "$OSRC_HOME"; }

_cloudrun_consent_ok() {
  local f; f="$(_cloudrun_consent_file)"
  [ -L "$f" ] && return 1
  [ -f "$f" ]
}

_cloudrun_consent_grant() {
  local f tmp; f="$(_cloudrun_consent_file)"; _mkdir_private "$OSRC_HOME" 2>/dev/null || return 1
  [ -L "$f" ] && rm -f "$f" 2>/dev/null
  tmp="$f.tmp.$$"
  printf 'granted: %s hosted-session disclosure (repo content + pushed branch leave this machine for a vendor VM)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

_cloudrun_consent() { # <vehicle> <quota-desc>
  local f; f="$(_cloudrun_consent_file)"
  if _cloudrun_consent_ok; then
    printf '>>>   consent     : remembered hosted-session grant in %s (revoke: %s cloud consent revoke)\n' "${f/#$HOME/~}" "$0" >&2
    return 0
  fi
  if [ -t 0 ] && [ -t 2 ]; then
    printf '>>> [outsourcerer] CLOUD SESSION: the brief + repo go to a hosted %s VM (spends: %s). Acknowledge? (remembered) [y/N] ' "$1" "$2" >&2
    local ans=""; IFS= read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) _cloudrun_consent_grant && return 0 ;; esac
    die "cloud: disclosure declined — refusing hosted session. Re-run interactively, or: $0 cloud consent grant"
  fi
  die "cloud: hosted session needs a ONE-TIME consent under its own key (repo content leaves this machine for a vendor VM; the model-API consent does not cover this). Fix once:
    $0 cloud consent grant    # remember consent for hosted sessions
  or run interactively and answer y."
}

# ---- vehicle probes (flags verified against live --help/docs, 2026-11-13; see L10-REPORT) ----------
# claude : claude --cloud "<description>" [--environment <ccpool-id>] [--model <m>]
#          description must come FIRST after --cloud; session URL prints to stdout.
# devin  : devin --cloud -p --prompt-file <file> [--model <m>]
#          session persists after -p exits; repo chosen by /repo or org default.
# codex  : codex cloud exec --env <ENV_ID> [--branch <br>] "<query>"   (EXPERIMENTAL; --env required)
_cloudrun_vehicle_quota() { # <vehicle> -> which plan the launch spends
  case "$1" in
    claude) printf 'Claude subscription (plan limits)' ;;
    devin)  printf 'Devin plan' ;;
    codex)  printf 'Codex plan (ChatGPT)' ;;
  esac
}

_cloudrun_claude_path() {
  local path
  path="$(type -P claude)" || return 1
  case "$path" in /*) printf '%s' "$path" ;; *) printf '%s/%s' "$PWD" "$path" ;; esac
}

# _cloudrun_vehicle_ok <vehicle> [codex-env-id] -> rc0 when usable; reason on stderr otherwise.
# Probe output is CAPTURED before grepping: `cli | grep -q` lets grep -q exit early, SIGPIPE the
# CLI, and an inherited `set -o pipefail` (SHELLOPTS) then reports a false "flag missing".
_cloudrun_vehicle_ok() {
  local v="$1" env="${2:-}" out
  case "$v" in
    claude)
      have claude || { echo "claude CLI not on PATH" >&2; return 1; }
      local cli="${3-$(_cloudrun_claude_path)}"
      out="$("$cli" --help 2>/dev/null)"; grep -q -- '--cloud' <<<"$out" \
        || { echo "claude has no --cloud flag" >&2; return 1; }
      if have jq; then
        [ "$("$cli" auth status 2>/dev/null | jq -r '.loggedIn // false' 2>/dev/null)" = "true" ] \
          || { echo "claude not signed in (claude auth login)" >&2; return 1; }
      else
        out="$("$cli" auth status 2>/dev/null)"; grep -q '"loggedIn": *true' <<<"$out" \
          || { echo "claude not signed in (claude auth login)" >&2; return 1; }
      fi ;;
    devin)
      have devin || { echo "devin CLI not on PATH" >&2; return 1; }
      out="$(devin --help 2>/dev/null)"; grep -q -- '--cloud' <<<"$out" \
        || { echo "devin has no --cloud flag" >&2; return 1; }
      out="$(devin auth status 2>/dev/null)"; grep -qi 'Logged in' <<<"$out" \
        || { echo "devin not signed in (devin auth login)" >&2; return 1; } ;;
    codex)
      have codex || { echo "codex CLI not on PATH" >&2; return 1; }
      out="$(codex cloud exec --help 2>/dev/null)"; grep -q -- '--env' <<<"$out" \
        || { echo "codex cloud exec has no --env (EXPERIMENTAL surface changed)" >&2; return 1; }
      [ -n "$env" ] || { echo "codex cloud needs an environment id (--env or OSRC_CODEX_CLOUD_ENV; see 'codex cloud')" >&2; return 1; }
      out="$(codex login status 2>/dev/null)"; grep -qi 'logged in' <<<"$out" \
        || { echo "codex not signed in (codex login)" >&2; return 1; } ;;
    *) echo "unknown vehicle '$v' (claude|devin|codex)" >&2; return 1 ;;
  esac
  return 0
}

# _cloudrun_claude_conserve -> rc0 when Claude is in conserve mode, so `auto` prefers Devin cloud.
# Two signals, same spirit as _conserve_reco: (a) the binding window (MORE-spent of claude5h/
# claude7d from _session_limits) at/over OSRC_CONSERVE_THRESHOLD; (b) a lane-posture marker under
# $OSRC_HOME/lane-posture saying the claude-native lane (key `cc`) is down or quota-capped.
_cloudrun_claude_conserve() {
  local limits tok c5="" c7="" v lp
  # (b) lane-posture first: cheap file reads, no probing.
  if type _posture_get >/dev/null 2>&1; then
    for lp in cc claude; do
      [ -n "$(_posture_get "$lp" down 2>/dev/null)" ] && return 0
      # quota-<slug> markers are per-model; a capped claude model means conserve too.
      local qf pdir="${OSRC_POSTURE_DIR:-$OSRC_HOME/lane-posture}"
      for qf in "$pdir/$lp".quota-*; do [ -f "$qf" ] && [ ! -L "$qf" ] && return 0; done
    done
  fi
  # (a) session-limit windows.
  limits="$(_session_limits 2>/dev/null)" || return 1
  for tok in $limits; do case "$tok" in
    claude5h=*) c5="${tok#*=}" ;; claude7d=*) c7="${tok#*=}" ;;
  esac; done
  [ -n "$c5$c7" ] || return 1
  for v in "$c5" "$c7"; do
    case "$v" in ''|*[!0-9]*) continue ;; esac
    [ "$v" -ge "${OSRC_CONSERVE_THRESHOLD:-50}" ] 2>/dev/null && return 0
  done
  return 1
}

# _cloudrun_pick_vehicle <requested> <codex-env> -> prints vehicle; rc1 + reasons when none usable.
_cloudrun_pick_vehicle() {
  local req="${1:-auto}" env="${2:-}" order v reason skipped=""
  local cli="${3-$(_cloudrun_claude_path)}"
  if [ "$req" != "auto" ]; then
    reason="$(_cloudrun_vehicle_ok "$req" "$env" "$cli" 2>&1)" && { printf '%s' "$req"; return 0; }
    printf '>>> [cloud] vehicle %s unusable: %s\n' "$req" "$reason" >&2; return 1
  fi
  # Subscription vehicles before metered devin: devin bills ACU and cloud start refuses it
  # without --spend-ok, so trying it early kills the launch instead of falling through to a
  # subscription lane. Conserve still drops claude last, but codex outranks devin either way.
  if _cloudrun_claude_conserve; then order="codex devin claude"; else order="claude codex devin"; fi
  for v in $order; do
    reason="$(_cloudrun_vehicle_ok "$v" "$env" "$cli" 2>&1)" && {
      [ -n "$skipped" ] && printf '%s\n' "$skipped" | sed 's/^/>>> [cloud] vehicle skipped: /' >&2
      printf '%s' "$v"; return 0; }
    skipped="$skipped$v: $reason | "
  done
  printf '>>> [cloud] no usable vehicle —%s\n' "$skipped" >&2
  return 1
}

# ---- launch failure diagnosis ------------------------------------------------------------------
# _cloudrun_trust_prompt <log> -> rc0 when claude is waiting on the folder-trust screen.
_cloudrun_log_tail() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -20; }
_cloudrun_trust_prompt() {
  grep -qiE 'project you created or one you trust|do you trust the files in this folder' <<<"$(_cloudrun_log_tail "$1")"
}

# _cloudrun_classify_failure <vehicle> <log> -> prints "<kind>\t<next step>" (kind: trust|quota|billing|
# ratelimit|other). Quota, billing and rate limits are NEVER a refusal of the request: the vehicle
# is out of capacity, so the next step is another vehicle or local work.
_cloudrun_classify_failure() {
  local v="$1" log="$2" alt tail
  tail="$(_cloudrun_log_tail "$log")"   # only the end of the log: an echoed prompt or old line must not classify
  case "$v" in claude) alt="--vehicle devin or codex" ;; devin) alt="--vehicle claude or codex" ;; *) alt="--vehicle claude or devin" ;; esac
  if _cloudrun_trust_prompt "$log"; then
    printf 'trust\tClaude Code does not trust this folder yet. Trust it once (run `claude` here and accept the prompt) or launch from an already trusted checkout; this tool never accepts trust for you.'
  elif grep -qiE 'out_of_quota|quota (exceeded|exhausted|reached)|exceeded (your )?(usage )?quota|usage limit|limit reached' <<<"$tail"; then
    printf 'quota\t%s is out of quota, not refusing the task. Retry with %s, or run the work locally.' "$v" "$alt"
  elif grep -qiE 'billing|payment required|insufficient[ _](credit|fund|balance)|out of (credits|acus)|credit balance|HTTP 402|\b402\b' <<<"$tail"; then
    printf 'billing\t%s reports a billing problem (not a refusal). Fix billing for that plan, retry with %s, or run the work locally.' "$v" "$alt"
  elif grep -qiE 'rate.?limit|too many requests|HTTP 429|\b429\b|overloaded' <<<"$tail"; then
    printf 'ratelimit\t%s is rate limited (not a refusal). Wait and retry, use %s, or run the work locally.' "$v" "$alt"
  else
    printf 'other\t'
  fi
}

# ---- launch -------------------------------------------------------------------------------------
# _cloudrun_extract_ref <log> -> first session URL or id pattern the vehicle printed.
_cloudrun_extract_ref() {
  local log="$1" v="$2" u url id
  case "$v" in
    claude) url='claude[.]ai/code/'; id='session_[A-Za-z0-9_-]{6,}' ;;
    devin) url='app[.]devin[.]ai/sessions/'; id='(devin-)?[0-9a-f]{16,}' ;;
    codex) url='chatgpt[.]com/codex/tasks/'; id='(task_|cse_)[A-Za-z0-9_-]{6,}' ;;
    *) return 1 ;;
  esac
  u="$(grep -oE "https://${url}${id}" "$log" 2>/dev/null | head -1)"
  [ -n "$u" ] && { printf 'url:%s' "$u"; return 0; }
  [ "$v" != devin ] || id='devin-[0-9a-f]{16,}'
  u="$(grep -Eo "(^|[[:space:]])${id}([[:space:]]|$)" "$log" 2>/dev/null | head -1 | tr -d '[:space:]')"
  [ -n "$u" ] && { printf 'id:%s' "$u"; return 0; }
  return 1
}

# _cloudrun_launch <vehicle> <packfile> <packtext> <logfile> <pidfile> <repo-root> <base>
#                 <codex-env> <claude-env> <model>
# Spawns the vehicle CLI detached (the hosted session outlives this process by design), then waits
# up to OSRC_CLOUD_LAUNCH_WAIT secs for a session URL/id to appear in the log. Prints "pid\nref".
_cloudrun_launch() {
  local v="$1" packfile="$2" packtext="$3" log="$4" pidfile="$5" root="$6" base="$7"
  local cxenv="${8:-}" claudeenv="${9:-}" model="${10:-}"
  local -a cmd=()
  case "$v" in
    claude)
      cmd=("${11-$(_cloudrun_claude_path)}" --cloud "$packtext")
      [ -n "$claudeenv" ] && cmd+=(--environment "$claudeenv")
      [ -n "$model" ] && cmd+=(--model "$model") ;;
    devin)
      cmd=(devin --cloud -p --prompt-file "$packfile")
      [ -n "$model" ] && cmd=(devin --cloud --model "$model" -p --prompt-file "$packfile") ;;
    codex)
      cmd=(codex cloud exec --env "$cxenv" --branch "$base" "$packtext") ;;
  esac
  local pid="" sess="" attempt
  if [ "$v" = claude ] && have tmux; then
    # `claude --cloud` refuses to run without a terminal ("--cloud requires an interactive terminal"),
    # so a nohup launch died at once (2026-11-19). It runs in its own tmux pane instead; the pane is
    # piped to the log, and the launcher waits for the pipe so no early line is lost.
    local fifo name writer i
    attempt="$(mktemp -d "$log.XXXXXX")" || return 1
    sess="osrc-cloud-${attempt##*.}"; fifo="$attempt/start"
    mkfifo "$fifo" || { rmdir "$attempt"; return 1; }
    # Bash reads its program from a private pipe. Its stdin stays connected to the pane.
    pid="$(tmux new-session -d -P -F '#{pane_pid}' -s "$sess" /usr/bin/env -i /bin/bash "$fifo")" || {
      rm -rf "$attempt"; return 1
    }
    if [ -z "$pid" ] || ! tmux pipe-pane -t "$sess" "/bin/cat >> $(printf '%q' "$log")"; then
      tmux kill-session -t "$sess"; rm -rf "$attempt"; return 1
    fi
    # Only send the checked caller's environment once capture is attached. Credentials
    # travel through the pipe, never through tmux's server environment or a saved script.
    {
      while IFS= read -r name; do
        case "$name" in ''|*[!a-zA-Z0-9_]*|BASHOPTS|SHELLOPTS|PWD|OLDPWD|SHLVL|_) continue ;; esac
        printf 'export %s=%q\n' "$name" "${!name}"
      done < <(compgen -e)
      printf 'cd %q || exit 1\n' "$root"
      printf '%q ' "${cmd[@]}"
      printf '\nprintf "%%s" "$?" > %q\n' "$attempt/exit"
    } > "$fifo" &
    writer=$!
    for ((i=0; i<100; i++)); do kill -0 "$writer" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$writer" 2>/dev/null; then kill "$writer" 2>/dev/null; fi
    if ! wait "$writer"; then
      tmux kill-session -t "$sess"; rm -rf "$attempt"; return 1
    fi
    rm -f "$fifo"
  else
    attempt="$(mktemp -d "$log.XXXXXX")" || return 1
    # The wrapper subshell's pid is not the vehicle's: record the vehicle pid (cpid) so a failed
    # launch can stop the real CLI, not just the wrapper.
    ( cd "$root" || { printf 1 > "$attempt/exit"; exit 1; }
      nohup "${cmd[@]}" & cp=$!
      printf '%s' "$cp" > "$attempt/cpid"
      wait "$cp"; printf '%s' "$?" > "$attempt/exit" ) >"$log" 2>&1 &
    pid="$!"
  fi
  printf '%s' "$pid" > "$pidfile"
  local i=0 max="${OSRC_CLOUD_LAUNCH_WAIT:-30}" ref=""
  case "$max" in ''|*[!0-9]*) max=30 ;; esac
  while [ "$i" -lt "$max" ]; do
    ref="$(_cloudrun_extract_ref "$log" "$v" 2>/dev/null)" && [ -n "$ref" ] && break
    _cloudrun_trust_prompt "$log" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1; i=$((i+1))
  done
  ref="$(_cloudrun_extract_ref "$log" "$v" 2>/dev/null)"
  if [ -s "$attempt/exit" ] && [ "$(cat "$attempt/exit")" != 0 ]; then return 1; fi
  if [ -z "$ref" ]; then
    # Started means a session URL/id was printed. Anything else is a failed launch: stop the
    # launcher so it cannot create an unregistered session later (and never answer a trust prompt).
    [ -z "$sess" ] || tmux kill-session -t "$sess" 2>/dev/null
    [ -s "$attempt/cpid" ] && kill "$(cat "$attempt/cpid")" 2>/dev/null
    kill "$pid" 2>/dev/null
    return 1
  fi
  printf '%s\n%s\n' "$pid" "$ref"
}

# ---- registration --------------------------------------------------------------------------------
# _cloudrun_register <id> <vehicle> <branch> <transport> <url> <repo-arg> <base> <brief>
#                    <donewhen> <pack> <ref>
# L2 path: `lane add` (writes remote/<id>.json + _owner_record + immediate poll). Fallback: write a
# schema-compatible remote/<id>.json ourselves so a later-merged L2 picks the lane up, plus
# _owner_record per CONTRACT.md.
_cloudrun_register() {
  local id="$1" vehicle="$2" branch="$3" transport="$4" url="$5" repo="$6" base="$7" brief="$8"
  local donewhen="${9:-}" pack="${10:-}" ref="${11:-}"
  local now; now="$(_cloudrun_now)"
  if type cmd_lane >/dev/null 2>&1; then
    local -a largs=(add "$id" --branch "$branch" --repo "$repo" --ready READY --base "$base" --brief "$brief")
    [ -n "$donewhen" ] && largs+=(--done-when "check:$donewhen")
    if ( cmd_lane "${largs[@]}" ) >/dev/null 2>"$(_cloudrun_cdir)/$id.lane.err"; then
      _cloudrun_json_extras "$id" "$vehicle" "$ref" "$pack"
      return 0
    fi
    die "cloud: lane add failed for '$id': $(tail -1 "$(_cloudrun_cdir)/$id.lane.err" 2>/dev/null)"
  fi
  local dir f tmp; dir="$(_cloudrun_rdir)"; _mkdir_private "$dir" 2>/dev/null || die "cloud: cannot create $dir"
  f="$dir/$id.json"; tmp="$f.tmp.$$"
  [ -e "$f" ] && die "cloud: lane '$id' already registered ($f)"
  if have jq; then
    jq -n --arg id "$id" --arg branch "$branch" --arg repo "$repo" --arg transport "$transport" \
      --arg url "$url" --arg base "$base" --arg brief "$brief" --arg dw "$donewhen" --arg vehicle "$vehicle" \
      --arg ref "$ref" --arg pack "$pack" --argjson now "$now" '{
        id:$id, branch:$branch, repo:$repo, transport:$transport, url:$url, ready_marker:"READY",
        base:$base, brief:$brief, done_when:$dw, created_ts:$now, last_poll_ts:0, last_ok_ts:0,
        err_count:0, err_kind:"", err_msg:"", seen_branch:false, branch_deleted:false,
        head:"", head_msg:"", head_ready:false, last_push_ts:$now, ready_head:"", ready_ts:0,
        check:null, vehicle:$vehicle, session_ref:$ref, pack:$pack}' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || { rm -f "$tmp"; die "cloud: could not write $f"; }
  else
    printf '{"id":"%s","branch":"%s","repo":"%s","transport":"%s","url":"%s","ready_marker":"READY","base":"%s","brief":"%s","done_when":"%s","created_ts":%s,"last_poll_ts":0,"last_ok_ts":0,"err_count":0,"err_kind":"","err_msg":"","seen_branch":false,"branch_deleted":false,"head":"","head_msg":"","head_ready":false,"last_push_ts":%s,"ready_head":"","ready_ts":0,"check":null,"vehicle":"%s","session_ref":"%s","pack":"%s"}\n' \
      "$id" "$branch" "$repo" "$transport" "$url" "$base" "$brief" "$donewhen" "$now" "$now" "$vehicle" "$ref" "$pack" > "$tmp" \
      && mv -f "$tmp" "$f" || { rm -f "$tmp"; die "cloud: could not write $f"; }
  fi
  _owner_record "$id" || { rm -f "$f"; die "cannot register owner for $id"; }
  return 0
}

# _cloudrun_json_extras <id> <vehicle> <ref> <pack> -> best-effort extra fields on the L2-written
# record (jq only; never fails the launch).
_cloudrun_json_extras() {
  local f="$(_cloudrun_rdir)/$1.json"
  [ -f "$f" ] && have jq || return 0
  jq --arg v "$2" --arg r "$3" --arg p "$4" '. + {vehicle:$v, session_ref:$r, pack:$p}' "$f" > "$f.tmp.$$" 2>/dev/null \
    && mv -f "$f.tmp.$$" "$f" || rm -f "$f.tmp.$$"
  return 0
}

# _cloudrun_done_contract <id> <fetch-url> <branch> <repo-root> -> L6 osrc_done_set when present.
# The spec is a generated check: clone the branch shallow and require <id>.READY at the tip.
_cloudrun_done_contract() {
  local id="$1" url="$2" branch="$3" root="$4" dir script
  type osrc_done_set >/dev/null 2>&1 || { printf '>>> [cloud] done contract: osrc_done_set not merged yet — skipped (lane READY detection still applies)\n' >&2; return 0; }
  dir="$(_cloudrun_cdir)"; _mkdir_private "$dir" 2>/dev/null || return 0
  script="$dir/$id.done.sh"
  {
    printf '#!/usr/bin/env bash\n# done check for cloud lane %s: exit 0 when the %s (or session branch) tip contains %s.READY\nset -u\n' "$id" "$branch" "$id"
    printf 'd="%s/%s.verify.git"\nrm -rf "$d" 2>/dev/null\n' "$dir" "$id"
    # READY may sit on the session's own claude/<id>-* branch: use the branch the lane poll follows
    printf 'b="$(jq -r '"'"'.poll_branch // empty'"'"' %q 2>/dev/null)"; [ -n "$b" ] || b=%q\n' "$OSRC_HOME/remote/$id.json" "$branch"
    # Only the file list is needed: no blobs, no checkout (about 120 KB instead of the ~70 MB repo),
    # and the scratch clone goes as soon as the answer is known.
    printf 'git clone -q --depth 1 --filter=blob:none --no-checkout --branch "$b" "%s" "$d" >/dev/null 2>&1 || { rm -rf "$d"; exit 1; }\n' "$url"
    printf 'git -C "$d" ls-tree --name-only HEAD -- %q 2>/dev/null | grep -qxF -- %q; r=$?\nrm -rf "$d" 2>/dev/null\nexit $r\n' "$id.READY" "$id.READY"
  } > "$script" 2>/dev/null && chmod 700 "$script" 2>/dev/null
  [ -x "$script" ] || { printf '>>> [cloud] done contract: could not write %s — skipped\n' "$script" >&2; return 0; }
  if osrc_done_set "$id" "check:bash $script" "$root" 2>/dev/null; then
    printf '>>> [cloud] done contract: osrc_done_set %s check:<clone %s + %s.READY>\n' "$id" "$branch" "$id" >&2
  else
    printf '>>> [cloud] done contract: osrc_done_set refused the spec — skipped\n' >&2
  fi
  return 0
}

# ---- cloud ls -------------------------------------------------------------------------------------
_cloudrun_ls() {
  local f id veh st any=0
  have jq || { for f in "$(_cloudrun_rdir)"/*.json; do [ -f "$f" ] && basename "$f" .json; done; return 0; }
  for f in "$(_cloudrun_rdir)"/*.json; do
    [ -f "$f" ] || continue; any=1; id="$(basename "$f" .json)"
    veh="$(jq -r '.vehicle // "-"' "$f" 2>/dev/null)"
    if type _osrc_lane_status >/dev/null 2>&1; then st="$(_osrc_lane_status "$id" 2>/dev/null)"; st="${st%%	*}"
    elif type osrc_remote_state >/dev/null 2>&1; then st="$(osrc_remote_state "$id" 2>/dev/null)"
    else st="$(jq -r 'if .head_ready then "ready" elif .head != "" then "live" else "pending" end' "$f" 2>/dev/null)"; fi
    printf '%-24s %-8s %-10s %s\n' "$id" "${veh:--}" "${st:-?}" "$(jq -r '.branch // "?"' "$f" 2>/dev/null)"
  done
  [ "$any" = 1 ] || echo "(no remote lanes; add one with: cloud start <id> --repo <owner/name> --base <branch> --brief <file>)"
}

# ---- cloud start ----------------------------------------------------------------------------------
_cloudrun_start() {
  local id="" vehicle="auto" repo="" base="" brief="" where="auto" donewhen="" env="" claudeenv="" model="" spendok=0 pinsha=""
  [ -n "${1:-}" ] || die "cloud start <id> --repo <owner/name> --base <branch> --brief <file> [--vehicle V] [--where W]"
  id="$1"; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vehicle)    vehicle="${2:-}"; shift 2 ;;
      --repo)       repo="${2:-}"; shift 2 ;;
      --base)       base="${2:-}"; shift 2 ;;
      --brief)      brief="${2:-}"; shift 2 ;;
      --where)      where="${2:-}"; shift 2 ;;
      --done-when)  donewhen="${2:-}"; shift 2 ;;
      --env)        env="${2:-}"; shift 2 ;;
      --claude-env) claudeenv="${2:-}"; shift 2 ;;
      --model)      model="${2:-}"; shift 2 ;;
      --spend-ok)   spendok=1; OSRC_SPEND_OK=1; export OSRC_SPEND_OK; shift ;;
      --sha)        pinsha="${2:-}"; shift 2 ;;
      *) die "cloud start: unknown option '$1'" ;;
    esac
  done
  [ -n "${OSRC_CODEX_CLOUD_ENV:-}" ] && [ -z "$env" ] && env="$OSRC_CODEX_CLOUD_ENV"
  # Never let a user:pass@ credential ride into the pack, lane record or vehicle argv.
  [ -n "$repo" ] && repo="$(_osrc_url_clean "$repo")"
  _cloudrun_id_ok "$id" || die "cloud: bad lane id '$id' (allowed: A-Za-z0-9._-, max 64, no leading dot)"
  local lane_file; lane_file="$(_cloudrun_rdir)/$id.json"
  [ ! -e "$lane_file" ] && [ ! -L "$lane_file" ] || die "cloud: lane '$id' already registered ($lane_file)"
  [ -n "$repo" ] || die "cloud start needs --repo <owner/name|git-url|path>"
  [ -n "$brief" ] || die "cloud start needs --brief <file>"
  [ -f "$brief" ] || die "cloud: brief file not found: $brief"
  brief="$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")"
  case "$where" in auto|cloud|local) ;; *) die "cloud: --where must be auto|cloud|local (got '$where')" ;; esac
  case "$donewhen" in check:*) donewhen="${donewhen#check:}" ;; esac
  # repo root + match: hosted vehicles clone the repo of the directory they launch from.
  local top; top="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "cloud start must run inside a git clone of --repo (the hosted session clones from the remote)"
  _cloudrun_repo_match "$repo" "$top" \
    || die "cloud: --repo '$repo' does not match this checkout's origin — the hosted session would clone the wrong repo"
  [ -n "$base" ] || base="$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$base" ] || die "cloud: --base required (could not detect current branch)"
  case "$base" in *[!A-Za-z0-9._/-]*|-*|*..*) die "cloud: bad --base '$base'" ;; esac
  local parsed transport url fetch display
  parsed="$(_cloudrun_repo_parse "$repo")" || die "cloud: cannot parse --repo '$repo' (use owner/name, a git URL, or a path)"
  transport="$(printf '%s' "$parsed" | cut -f1)"; url="$(printf '%s' "$parsed" | cut -f2)"; display="$(printf '%s' "$parsed" | cut -f3)"
  fetch="$(_cloudrun_fetch_url "$transport" "$url")"
  local branch="cloud/$id"
  # --where routing: show the decision before launching (explicit local is a usage error here).
  if [ "$where" = "local" ]; then
    die "cloud start cannot run a local brief — this one needs this machine. Use session/run/edit for local work."
  fi
  if [ "$where" = "auto" ]; then
    local wout wdec wreason
    wout="$(osrc_where "$brief")"; wdec="$(printf '%s' "$wout" | head -1)"; wreason="$(printf '%s' "$wout" | sed -n '2s/^reason: //p')"
    printf '>>> [cloud] where=auto -> %s (%s)\n' "$wdec" "$wreason" >&2
    [ "$wdec" = "cloud" ] || die "cloud: --where auto routed this brief LOCAL ($wreason) — use session/run/edit, or pass --where cloud to override"
  fi
  # --sha pins an exact commit (the heavy gate's offer carries it through); it must be a
  # commit this clone has AND fully reachable from a remote — the cloud box can only see
  # what was pushed. Checked before preflight so the reason is about the pin, not HEAD.
  if [ -n "$pinsha" ]; then
    git -C "$top" rev-parse --verify --quiet "${pinsha}^{commit}" >/dev/null 2>&1 \
      || die "cloud: --sha '$pinsha' is not a commit in this clone"
    local pinunp; pinunp="$(git -C "$top" rev-list --count "$pinsha" --not --remotes 2>/dev/null)"
    case "$pinunp" in ''|*[!0-9]*) pinunp=1 ;; esac
    [ "$pinunp" = "0" ] || die "cloud: --sha '$pinsha' has commits not on any remote — the hosted session could never see it"
  elif [ "${id#heavy-}" != "$id" ]; then
    # heavy-gate lanes embed the offered sha in their id; without --sha the pack would pin
    # whatever HEAD happens to be at approval time and the RESULT could describe other code
    die "cloud: lane id '$id' came from a heavy-check offer — pass --sha <the offered commit> so the pack cannot drift"
  fi
  # preflight: pushed base + no unpushed work + repo match (above)
  _cloudrun_preflight "$fetch" "$base" "$top"
  # The pack pins HEAD but the hosted clone starts from the remote base: they must be the same commit.
  # With --sha the checkout must be that pinned commit: the vehicle launches from this checkout.
  local btip bhead bwhat="the tip of base '$base'"
  btip="${_CLOUDRUN_BASE_TIP:-}"; bhead="$(git -C "$top" rev-parse HEAD 2>/dev/null)"
  [ -z "$pinsha" ] || { btip="$(git -C "$top" rev-parse "${pinsha}^{commit}" 2>/dev/null)"; bwhat="the pinned --sha"; }
  [ -z "$btip" ] || [ "$btip" = "$bhead" ] \
    || die "cloud: this checkout's HEAD (${bhead:0:7}) is not $bwhat (${btip:0:7}): the lane would be built on the wrong code. Check out that commit first."
  # context pack + gates (refusals before any vehicle probe or launch)
  local pack packtext; pack="$(_cloudrun_pack "$id" "$display" "$base" "$branch" "$brief" "$donewhen" "$pinsha")"
  packtext="$(cat "$pack")"
  _cloudrun_private_check "$pack" \
    || die "cloud: pack failed the private-name check — sanitize the brief (no machine-local paths or denylisted names) and retry"
  local WITH_SPEC=""
  _secret_scan "$packtext" "cloudrun"     # dies on credential files in scope / secret values
  # vehicle + spend gate + consent + launch
  local claude_bin
  claude_bin="$(_cloudrun_claude_path)" || claude_bin=""
  local veh; veh="$(_cloudrun_pick_vehicle "$vehicle" "$env" "$claude_bin")" \
    || die "cloud: no usable hosted-session vehicle"
  [ "$veh" = codex ] && [ -z "$env" ] && die "cloud: codex vehicle needs --env <id> or OSRC_CODEX_CLOUD_ENV"
  # Spend gate, FAIL CLOSED + per-launch consent export (L10-r3 verdict finding C):
  # --spend-ok exports OSRC_SPEND_OK=1 for THIS process so L7's gate (which consents on
  # that var) sees this command's approval; OSRC_SPEND_NEXT carries the runnable `cloud
  # start` line so a gate refusal can print it. Devin cloud is metered: it ALWAYS
  # requires --spend-ok whether or not a gate is loaded — the gate is called in
  # addition, never instead. Interface agreed in CONTRACT.md.
  local _sp_lane spendnext
  case "$veh" in claude) _sp_lane=cc ;; devin) _sp_lane=dv ;; codex) _sp_lane=cx ;; *) _sp_lane="$veh" ;; esac
  spendnext="\"${SCRIPT_PATH:-$0}\" cloud start $id --repo $(printf '%q' "$repo") --base $(printf '%q' "$base") --brief $(printf '%q' "$brief") --vehicle $veh --where cloud"
  [ -n "$env" ] && spendnext="$spendnext --env $(printf '%q' "$env")"
  [ -n "$claudeenv" ] && spendnext="$spendnext --claude-env $(printf '%q' "$claudeenv")"
  [ -n "$model" ] && spendnext="$spendnext --model $(printf '%q' "$model")"
  [ -n "$pinsha" ] && spendnext="$spendnext --sha $pinsha"
  [ -n "$donewhen" ] && spendnext="$spendnext --done-when $(printf '%q' "check:$donewhen")"
  # NEXT is the approve-line: it always ends in --spend-ok so a gate refusal hands the
  # orchestrator one runnable command (never a dead end that re-asks the same way).
  spendnext="$spendnext --spend-ok"
  OSRC_SPEND_NEXT="$spendnext"; export OSRC_SPEND_NEXT
  # Unguarded: a missing spend gate is a refusal (rc 127), never a launch with a note.
  _osrc_spend_gate "$_sp_lane" "$model" "$veh" "cloud session $id" \
    || die "cloud: spend gate refused the hosted-session launch (NEXT: $OSRC_SPEND_NEXT)"
  if [ "$veh" = "devin" ]; then
    [ "$spendok" = "1" ] || die "cloud: devin cloud bills metered usage — re-run with --spend-ok to approve THIS launch only"
  fi
  _cloudrun_consent "$veh" "$(_cloudrun_vehicle_quota "$veh")"
  local cenv="$claudeenv"; [ "$veh" = claude ] || cenv=""
  local log pidfile launch_out pid ref
  log="$(_cloudrun_cdir)/$id.launch.log"; pidfile="$log.pid"
  : > "$log" 2>/dev/null || die "cloud: cannot write $log"
  printf '>>> [cloud] launching %s session %s (spends: %s)\n' "$veh" "$id" "$(_cloudrun_vehicle_quota "$veh")" >&2
  if ! launch_out="$(_cloudrun_launch "$veh" "$pack" "$packtext" "$log" "$pidfile" "$top" "$base" "$env" "$cenv" "$model" "$claude_bin")"; then
    # Failed launch (no session URL/id, or the vehicle exited non-zero): show the vehicle's output,
    # name the real cause, register nothing.
    local cls fref; cls="$(_cloudrun_classify_failure "$veh" "$log")"
    fref="$(_cloudrun_extract_ref "$log" "$veh" 2>/dev/null)"
    if [ -n "$fref" ]; then
      fref="the $veh session printed ${fref#*:} and then the launch failed"
    else
      fref="no session link appeared within ${OSRC_CLOUD_LAUNCH_WAIT:-30}s (raise OSRC_CLOUD_LAUNCH_WAIT if the vehicle is slow)"
    fi
    die "cloud: the $veh session did not start: $fref. A session may still have been created: check the vehicle dashboard. Nothing was registered.
${cls#*	}
its last output:
$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -5)"
  fi
  pid="$(printf '%s' "$launch_out" | sed -n '1p')"; ref="$(printf '%s' "$launch_out" | sed -n '2p')"
  _cloudrun_register "$id" "$veh" "$branch" "$transport" "$url" "$repo" "$base" "$brief" "$donewhen" "$pack" "$ref"
  _cloudrun_done_contract "$id" "$fetch" "$branch" "$top"
  printf 'cloud %s: %s session started on %s (branch %s)\n' "$id" "$veh" "$display" "$branch"
  printf '  session: %s\n' "$ref"
  printf '  quota   : %s\n' "$(_cloudrun_vehicle_quota "$veh")"
  printf '  log     : %s (launcher pid %s)\n' "$log" "$pid"
  printf '  track   : %s lane ls · %s lane events · READY = %s.READY at %s tip\n' "$0" "$0" "$id" "$branch"
  return 0
}

cmd_cloud() {
  case "${1:-}" in
    start) shift; _cloudrun_start "$@" ;;
    where) shift; osrc_where "$@" ;;
    ls|list) _cloudrun_ls ;;
    consent)
      case "${2:-}" in
        grant) _cloudrun_consent_grant && echo "cloud session consent: granted in $(_cloudrun_consent_file) (hosted-session key only; model-API consent is separate). Revoke: $0 cloud consent revoke" ;;
        revoke) rm -f "$(_cloudrun_consent_file)" 2>/dev/null; echo "cloud session consent: revoked." ;;
        status) if _cloudrun_consent_ok; then echo "cloud session consent: GRANTED"; else echo "cloud session consent: not granted"; fi ;;
        *) die "cloud consent: grant|revoke|status" ;;
      esac ;;
    *) die "cloud: start <id> --repo R --base B --brief F [--vehicle V] [--where W] | where <brief> | ls | consent grant|revoke|status" ;;
  esac
}

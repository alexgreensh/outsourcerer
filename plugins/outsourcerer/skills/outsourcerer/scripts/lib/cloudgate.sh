# lib/cloudgate.sh — cloud disclosure + secret-scan gate.
#
# Moved verbatim out of outsourcerer.sh (scripts/check_file_size.py ratchet: the legacy file may
# only shrink). Defines functions only, runs nothing at load time. Callers, env vars and behavior
# are unchanged.

# =============================================================================
# CLOUD DISCLOSURE + SECRET-SCAN GATE (security hardening).
# Mirrors the _perm_escalate/_protected_scope shapes: a small pure classifier plus a
# gate that dies on REFUSE. Local/ollama/lmstudio lanes are short-circuited in
# route_delegate BEFORE this runs, so this only guards CLOUD lanes (cc/codex/OpenRouter,
# devin, gemini, codex-native) where repo content actually leaves the machine.
# Fail-closed: non-interactive without an explicit ack (OSRC_CLOUD_ACK=1 or --cloud-ack)
# REFUSEs; a REAL .env/credential file in scope hard-dies regardless of ack (KTD1/KTD2).
# =============================================================================

# _osrc_url_clean <url> -> the URL with any user:pass@ / user@ credential stripped. Anything a
# pack, brief, lane record or done-check writes down must go through this first: a token embedded
# in an origin URL is a live credential, and git's own credential helper supplies auth locally.
_osrc_url_clean() {
  printf '%s' "${1:-}" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1#'
}

# _is_cloud_lane <disp> -> 0 if the resolved dispatch lane ships data off-machine, else 1.
# Descriptor-first via _lane_by_disp (disp-vehicle context — provider names like
# `cc`/`gemini` deliberately do NOT resolve here, preserving the session path's
# current `*`-arm answer). The case below is the unported-lane fallback.
_is_cloud_lane() {
  local _l _v
  if _l="$(_lane_by_disp "${1:-}" 2>/dev/null)"; then
    _v="$(_lane_field "$_l" is_cloud 2>/dev/null)"
    [ -n "$_v" ] && { [ "$_v" = "yes" ]; return; }
  fi
  case "$1" in
    devin) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- per-lane / per-repo trust for the credential-FILE hard-block (issue #2).
# Default EMPTY, so every install stays fail-closed exactly as before. A lane is trusted only for
# repos explicitly listed for it, so trusting a lane in one repo grants nothing anywhere else.
# Deliberately NOT an environment variable: an exported grant is inherited by every child process
# (bg/fanout jobs, nested invocations) and would silently widen the trusted set far past the repo the
# operator was thinking about. The config file and a per-invocation flag are the only two grants, and
# neither survives into a child.
# Config: $XDG_CONFIG_HOME/outsourcerer/trusted-lanes.json (default ~/.config/...), shape:
#   { "devin": ["/abs/path/to/repo", ...], "cc": [...] }
_trust_config_file() { printf '%s/outsourcerer/trusted-lanes.json' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# _lane_trusted_for_pwd <lane> -> 0 when this lane is trusted for the current repo. Fails CLOSED on
# every uncertainty: no file, unreadable, bad JSON, no jq, unresolvable path.
_lane_trusted_for_pwd() {
  local lane="$1" cf here p rp
  [ -n "$lane" ] || return 1
  # Per-invocation grant (--trust-lane). Not exported, so a bg/fanout child re-evaluates from config.
  case " ${OSRC_TRUST_LANE_ONCE:-} " in *" $lane "*) return 0 ;; esac
  cf="$(_trust_config_file)"
  [ -f "$cf" ] && [ -r "$cf" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Resolve $PWD through symlinks so a symlinked path cannot masquerade as a trusted repo.
  here="$(cd "$PWD" 2>/dev/null && pwd -P)" || return 1
  [ -n "$here" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "~"/*) p="$HOME/${p#\~/}" ;; esac
    rp="$(cd "$p" 2>/dev/null && pwd -P)" || continue
    # Exact repo, or anywhere inside it. Never a prefix-string match (/repo must not match /repo-two).
    [ "$here" = "$rp" ] && return 0
    case "$here" in "$rp"/*) return 0 ;; esac
  done < <(jq -r --arg l "$lane" '.[$l] // [] | .[]? | select(type=="string")' "$cf" 2>/dev/null)
  return 1
}

# _cred_file_hits -> fills the global array _CRED_HITS with every credential FILE the cloud gate blocks
# on inside the delegated scope ($PWD), in gate order (fixed top-level names, top-level .env.*, then the
# bounded deep sweep). Sets _CRED_SCAN_RC: 0 = scan complete, else the find rc of a scan that could not
# complete (the caller must fail CLOSED). Called directly, never in $(...), so the globals survive.
# One rule set shared by the hard-block in _secret_scan and the auto-isolate in _cloud_autoisolate.
_cred_file_hits() {
  _CRED_HITS=(); _CRED_SCAN_RC=0
  local f
  for f in "$PWD/.env" "$PWD/.env.local" "$PWD/credentials" "$PWD/id_rsa" "$PWD/id_ed25519" "$PWD/.aws/credentials"; do
    [ -f "$f" ] && _CRED_HITS+=("$f")
  done
  # dotenv variants (.env.*), excluding obvious templates (.example/.sample/.template/.dist).
  while IFS= read -r f; do
    case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
    [ "$f" = "$PWD/.env.local" ] && continue   # already listed above
    [ -f "$f" ] && _CRED_HITS+=("$f")
  done < <(compgen -G "$PWD/.env.*" 2>/dev/null)
  # (1b) A cloud delegate can read the WHOLE workspace, not just its root, so a nested
  # credential file (services/prod/.env, deploy/.env.production, config/id_rsa) is just as exfiltrable.
  # Bounded recursive sweep: depth-limited, prunes heavy/vendored dirs, excludes obvious templates.
  # Opt out with OSRC_SECRET_SCAN_DEEP=0 (e.g. a giant monorepo where the walk is too slow).
  if [ "${OSRC_SECRET_SCAN_DEEP:-1}" = "1" ] && command -v find >/dev/null 2>&1; then
    # Validate depth to an integer -- a bogus OSRC_SECRET_SCAN_DEPTH made `find`
    # error out, the read loop saw nothing, and the scan FAILED OPEN (no die). Never fail open on a scan
    # we cannot run: sanitize to the default, and if find itself errors, refuse the cloud route.
    local _depth="${OSRC_SECRET_SCAN_DEPTH:-4}"
    case "$_depth" in ''|*[!0-9]*) _depth=4 ;; esac
    [ "$_depth" -gt 12 ] 2>/dev/null && _depth=12   # cap: an unbounded walk is a DoS/hang, not security
    # Process substitution DISCARDS find's exit status, so a find that fails
    # to run scans nothing and the gate fails OPEN. Run find into a private temp file, CHECK its status,
    # and fail CLOSED if the scan could not complete. A cloud delegate runs with our own repo
    # privileges, so paths find can read are exactly the paths the delegate can read.
    local _sf _ef
    _sf="$(mktemp "${TMPDIR:-/tmp}/osrc.scan.XXXXXX" 2>/dev/null)" || die "CLOUD GATE: cannot create scan tempfile — refusing cloud route (fail closed)."
    _ef="$(mktemp "${TMPDIR:-/tmp}/osrc.scanerr.XXXXXX" 2>/dev/null)" || { rm -f "$_sf"; die "CLOUD GATE: cannot create scan tempfile — refusing cloud route (fail closed)."; }
    find "$PWD" -maxdepth "$_depth" \
               \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv \
                  -o -name target -o -name dist -o -name build -o -name .terraform \) -prune -o \
               \( -type f -o -type l \) \( -name '.env' -o -name '.env.*' -o -name 'credentials' -o -name 'id_rsa' \
                  -o -name 'id_ed25519' \) -print > "$_sf" 2>"$_ef"
    local _fs=$?
    # A nonzero find rc is USUALLY routine traversal noise (a mode-000 or
    # root-owned subdir). Same-privilege: a path find can't read, the cloud delegate can't read either, so
    # that's NOT an exfil gap -- process the readable results and proceed. Fail CLOSED only on a REAL scan
    # failure (bad invocation/syntax/tool error): i.e. stderr has a line that is NOT a permission diagnostic.
    if [ "$_fs" -ne 0 ] && [ -s "$_ef" ] && grep -qvE 'Permission denied|Operation not permitted|Not a directory|No such file' "$_ef"; then
      rm -f "$_sf" "$_ef"; _CRED_SCAN_RC="$_fs"; return 0
    fi
    local _seen
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
      for _seen in ${_CRED_HITS[@]+"${_CRED_HITS[@]}"}; do [ "$_seen" = "$f" ] && continue 2; done
      _CRED_HITS+=("$f")
    done < "$_sf"
    rm -f "$_sf" "$_ef"
  fi
  return 0
}

# _cred_hit_ignored_untracked <path> -> 0 when <path> is gitignored AND not tracked by git, i.e. a
# `git worktree add` (or any clone) of this repo will never contain it. Fails closed (rc 1) outside a
# repo or on any git error.
_cred_hit_ignored_untracked() {
  local p="$1" d b
  d="$(dirname "$p")"; b="$(basename "$p")"
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$d" ls-files --error-unmatch -- "$b" >/dev/null 2>&1 && return 1   # tracked -> ships with the repo
  git -C "$d" check-ignore -q -- "$b" 2>/dev/null
}

# _cloud_autoisolate <disp> -> issue #51. A cloud delegation whose ONLY credential-file hits are
# gitignored and untracked (web/.env.local and friends) used to die at the gate, leaving the operator to
# snapshot the tree into a worktree by hand and relaunch. Do that here instead: snapshot the checkout
# (tracked + untracked files, uncommitted changes included, everything gitignored left out) into a fresh
# worktree on branch outsourcerer/<id>, and cd into it. The full gate (_secret_scan) still runs
# afterwards, on the isolated tree, so this never weakens it: a tracked .env still blocks, a pasted
# secret value still blocks. rc 0 = isolated (PWD changed); rc 1 = nothing done, the gate decides as
# before. Must be called directly (never in $(...)) by the process that then launches the delegate.
# Off switch: OSRC_CLOUD_AUTOISOLATE=0.
_cloud_autoisolate() {
  local lane="${1:-}"
  [ "${OSRC_CLOUD_AUTOISOLATE:-1}" = "1" ] || return 1
  _is_cloud_lane "$lane" || return 1
  _lane_trusted_for_pwd "$lane" && return 1          # trusted lane: the file scan is skipped anyway
  _cred_file_hits
  [ "$_CRED_SCAN_RC" = "0" ] || return 1             # scan failed: let the gate fail closed
  [ "${#_CRED_HITS[@]}" -gt 0 ] || return 1          # nothing to keep out
  local h
  for h in "${_CRED_HITS[@]}"; do
    _cred_hit_ignored_untracked "$h" || return 1     # a tracked/unignored secret: the gate blocks it
  done
  local root rel id jd wt br base tree snap idx gidx
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  rel="$(git rev-parse --show-prefix 2>/dev/null)"   # resume in the same subdir of the snapshot
  if [ -n "${OSRC_JOB_DIR:-}" ]; then id="$(basename "$OSRC_JOB_DIR")"; jd="$OSRC_JOB_DIR"
  # A foreground run is not a job: keep its receipt out of the jobs dir so `status` lists no ghost row.
  else id="run-$(date +%Y%m%d-%H%M%S)-$$"; jd="$OSRC_HOME/isolated/$id"; fi
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  wt="$root/.outsourcerer/worktrees/$id"; br="outsourcerer/$id"
  _osrc_git_exclude_state "$root"                    # keep .outsourcerer/ out of the snapshot itself
  # Snapshot through a PRIVATE copy of the index, so the user's staging area is never touched.
  idx="$(mktemp "${TMPDIR:-/tmp}/osrc.idx.XXXXXX" 2>/dev/null)" || return 1
  gidx="$(git -C "$root" rev-parse --git-path index 2>/dev/null)"
  case "$gidx" in /*|[A-Za-z]:[/\\]*) ;; *) gidx="$root/$gidx" ;; esac
  # cp -p keeps the index mtime: git trusts an entry's stat data only when the file is older than the
  # index, so a fresh mtime would hide a same-size edit made in the same second ("racily clean").
  if [ -f "$gidx" ]; then cp -p "$gidx" "$idx" 2>/dev/null || { rm -f "$idx"; return 1; }; else rm -f "$idx"; fi
  if ! GIT_INDEX_FILE="$idx" git -C "$root" add -A -- . >/dev/null 2>&1 \
     || ! tree="$(GIT_INDEX_FILE="$idx" git -C "$root" write-tree 2>/dev/null)"; then
    rm -f "$idx"; echo "[outsourcerer] cloud gate: could not snapshot the checkout for isolation; falling back to the normal gate." >&2; return 1
  fi
  rm -f "$idx"
  base="$(git -C "$root" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
  local -a _par=(); [ -n "$base" ] && _par=(-p "$base")
  local _msg="outsourcerer: snapshot of the working tree for $id (gitignored files left out)"
  # commit-tree runs no hooks. Use the user's identity when set, else a neutral local one.
  snap="$(git -C "$root" commit-tree "$tree" ${_par[@]+"${_par[@]}"} -m "$_msg" 2>/dev/null)" \
    || snap="$(git -C "$root" -c user.name=outsourcerer -c user.email=outsourcerer@localhost commit-tree "$tree" ${_par[@]+"${_par[@]}"} -m "$_msg" 2>/dev/null)" \
    || { echo "[outsourcerer] cloud gate: could not snapshot the checkout for isolation; falling back to the normal gate." >&2; return 1; }
  if ! git -C "$root" worktree add -q -b "$br" "$wt" "$snap" >/dev/null 2>&1; then
    echo "[outsourcerer] cloud gate: could not create the isolated worktree $wt; falling back to the normal gate." >&2; return 1
  fi
  cd "$wt/$rel" 2>/dev/null || cd "$wt" 2>/dev/null || return 1
  # Receipt in the job dir, so `status`/`cleanup <id>` find the worktree like a --worktree job's.
  _mkdir_private "$jd" 2>/dev/null || true
  if have jq; then
    jq -cn --arg p "$wt" --arg b "$br" --arg bs "$snap" '{path:$p,branch:$b,base_sha:$bs,auto_isolated:true}' > "$jd/worktree.json" 2>/dev/null || true
  else
    printf '{"path":"%s","branch":"%s","base_sha":"%s","auto_isolated":true}\n' "$wt" "$br" "$snap" > "$jd/worktree.json" 2>/dev/null || true
  fi
  printf '>>> [outsourcerer] cloud gate: %s gitignored secret file(s) (e.g. %s) stay in your checkout. The delegate runs in an isolated copy instead:\n' "${#_CRED_HITS[@]}" "${_CRED_HITS[0]#"$root"/}" >&2
  printf '>>>   isolated    : %s (branch %s; includes your uncommitted work, minus gitignored files)\n' "$wt" "$br" >&2
  printf '>>>   bring back  : (cd "%s" && git add -A && git diff --cached --binary %s) | git -C "%s" apply\n' "$wt" "${snap:0:12}" "$root" >&2
  printf '>>>   then        : %s cleanup %s --force   (turn this off with OSRC_CLOUD_AUTOISOLATE=0)\n' "$0" "$id" >&2
  return 0
}

# _secret_scan <prompt> -> best-effort, gitignore-aware (KTD2). Hard-dies if a REAL credential
# file sits inside the delegated scope (cwd top-level + .aws). Reports (via OSRC_SECRET_HIT_COUNT) any
# high-signal pattern found in the prompt or a --with file, but does NOT hard-block on a regex
# hit alone (avoid crying wolf); only an actual credential FILE hard-blocks.
# Issue #51: run/edit/bg/fanout call _cloud_autoisolate BEFORE this, so a checkout whose only hits are
# gitignored never reaches the block below; it runs in a secret-free snapshot worktree instead.
_secret_scan() {
  local prompt="${1:-}" f scan="$1" lane="${2:-}" trusted=0
  if _lane_trusted_for_pwd "$lane"; then trusted=1; fi
  # (1) hard block: an actual credential file in scope. Skipped ONLY for a lane explicitly trusted for
  # THIS repo. The pattern scan (2) and the pasted-VALUE block (3) below still run either way: trusting
  # a lane with the credentials a repo already contains is a different decision from letting a live
  # secret VALUE be pasted into a prompt, and the second is never implied by the first.
  if [ "$trusted" = "0" ]; then
    _cred_file_hits
    [ "$_CRED_SCAN_RC" = "0" ] || die "CLOUD GATE: workspace credential scan could not complete (find rc=$_CRED_SCAN_RC) — refusing cloud route (fail closed). Fix the scan or set OSRC_SECRET_SCAN_DEEP=0 to skip it (NOT recommended for cloud lanes)."
    if [ "${#_CRED_HITS[@]}" -gt 0 ]; then
      local _hit="${_CRED_HITS[0]}" _hint=""
      # Name the way out when the file is only local (gitignored, untracked): the delegate can still
      # read it from THIS checkout, but a worktree of the repo never contains it.
      _cred_hit_ignored_untracked "$_hit" \
        && _hint=" It is gitignored, so a fresh worktree never contains it: start the delegate from one (git worktree add <dir> HEAD), or let run/edit/bg/fanout do that for you (on unless OSRC_CLOUD_AUTOISOLATE=0)."
      die "CLOUD GATE: real credential file in delegated scope: $_hit — refusing cloud route. Remove it, or delegate to a local (ollama/lmstudio) lane which never leaves the machine.$_hint"
    fi
  fi
  # (2) best-effort pattern scan over prompt + --with files (report only, never hard-blocks).
  # Every WITH_SPEC token that went through _validate_with_token is a skills=… or mcp=… form, so
  # the `*=*) continue` branch fires and the bare-file `[ -f "$tok" ]` path below is not expected
  # to run. Kept as defensive coverage for any path that sets WITH_SPEC without the validator.
  # `${_ws[@]:-}` is required: a whitespace-only spec yields an empty array, and "${_ws[@]}" on an
  # empty array is a fatal unbound-variable error under bash 3.2 + set -u.
  if [ -n "${WITH_SPEC:-}" ]; then
    local tok
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in *=*) continue ;; esac          # skills=a,b / mcp=x are not file paths
      [ -f "$tok" ] && scan="$scan
$(cat "$tok" 2>/dev/null)"
    done <<_OSRC_GATE_SPECS
$(_with_specs)
_OSRC_GATE_SPECS
  fi
  # Count distinct high-signal matches; do NOT retain the matched secret text (only a count is
  # surfaced downstream, so the raw credential fragments never live in a variable or reach stderr/logs).
  OSRC_SECRET_HIT_COUNT="$(printf '%s\n' "$scan" | grep -Eoi '(^|[^A-Za-z0-9])(OPENROUTER_API_KEY|sk-[A-Za-z0-9._-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[0-9A-Za-z_]{20,}|AIza[0-9A-Za-z_-]{35}|AWS_SECRET[_A-Z]*|-----BEGIN [A-Z ]*PRIVATE KEY-----)' 2>/dev/null | sort -u | grep -c . )"
  OSRC_SECRET_HIT_COUNT="${OSRC_SECRET_HIT_COUNT:-0}"
  # (3) VALUE hard-block: a real high-entropy secret VALUE pasted into the prompt / --with
  # files (not merely a keyword like the bare name OPENROUTER_API_KEY, which appears in normal code
  # discussion) ships a LIVE credential to a cloud lane. These patterns are token values and are almost
  # never legitimately pasted, so — unlike the count-only keyword scan above — they HARD-BLOCK by
  # default. Opt out with OSRC_SECRET_ALLOW_VALUE=1 for the rare deliberate case. The value itself is
  # never printed (only the refusal). Reference secrets by NAME, not value, when delegating.
  # Here-string, not `printf | grep -q`: $scan is the whole prompt + --with files (unbounded), and
  # once it outgrows the pipe buffer grep's early exit SIGPIPEs printf, which pipefail reports as
  # "no secret" -- the hard-block would wave a real credential through to a cloud lane.
  if [ "${OSRC_SECRET_ALLOW_VALUE:-0}" != "1" ] \
     && grep -Eq '(^|[^A-Za-z0-9])(sk-[A-Za-z0-9._-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[0-9A-Za-z_]{20,}|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|[a-zA-Z][a-zA-Z0-9+.-]{1,15}://[^/[:space:]@:"'"'"']+:[^/[:space:]@"'"'"']+@|-----BEGIN [A-Z ]*PRIVATE KEY-----)' <<<"$scan"; then
    die "CLOUD GATE: a live secret VALUE (API key / token / private key) is in the prompt or a --with file — refusing the cloud route so it doesn't leave your machine. Reference the secret by NAME instead of pasting its value, or set OSRC_SECRET_ALLOW_VALUE=1 if you truly intend to send it."
  fi
}

# _cloud_disclose <lane> <model> <prompt> -> the cloud gate. Idempotent per process via
# OSRC_CLOUD_ACKED (set on any successful ack so fanout does not re-prompt N times).
_cloud_disclose() {
  local lane="$1" model="${2:-}" prompt="${3:-}"
  _is_cloud_lane "$lane" || return 0                 # local/ollama/lmstudio: skip entirely
  # SECURITY (CRITICAL): the credential hard-block MUST run for every cloud delegation,
  # BEFORE any acknowledgement short-circuit. OSRC_CLOUD_ACKED is exported and therefore inherited by
  # child processes (bg/fanout __runjob, nested invocations); if the ACKED early-return preceded the
  # scan, `OSRC_CLOUD_ACKED=1` in the environment would ship a repo with a live .env to a third-party
  # API with the hard-block silently skipped. An ack only suppresses the human-facing notice/prompt --
  # never the scan.
  _secret_scan "$prompt" "$lane"                     # dies here if a real cred file is in scope
  [ "${OSRC_CLOUD_ACKED:-0}" = "1" ] && return 0     # already disclosed in-process -> skip the notice only
  local cwd="${PWD/#$HOME/~}"
  local train="paid/non-training route (no training on your data)"
  # match :free ANYWHERE — the model arg may be a comma-joined pair (second-opinion), so a leading
  # `hy3:free,deepseek/...` must still disclose may-train (an ends-with test missed the joined case).
  case "$model" in *:free*) train="':free' route — PROVIDER MAY TRAIN on your data" ;; esac
  printf '>>> [outsourcerer] CLOUD DISCLOSURE: delegating to a CLOUD lane (%s / %s).\n' "$lane" "$model" >&2
  printf '>>>   destination : a third-party API over the network — repo content LEAVES this machine.\n' >&2
  printf '>>>   readable    : this working dir (%s) + any --with files you passed.\n' "$cwd" >&2
  # Kill the recurring misread: "content leaves the machine" is a PRIVACY disclosure, NOT a claim
  # that the delegate works on a remote copy. The delegate runs with THIS directory as its CWD and
  # reads AND EDITS files here IN PLACE. A cloud lane does NOT need you to push, commit, or clone
  # anything for it to work on local files — just launch from the dir (or a worktree) you want edited.
  printf '>>>   local edits : the delegate edits files in THIS dir in place — no push/commit/clone needed for a cloud lane to work on local files.\n' >&2
  # Some agent CLIs additionally pull "always-on" rule files from $HOME and prepend them to every
  # session. That is outside the working dir, so the line above would otherwise be a promise this gate
  # cannot keep. Naming it matters twice over: those files leave the machine, and because they are
  # INSTRUCTIONS they also steer the delegate on a task that never asked for them.
  _rule_files_note >&2
  printf '>>>   training    : %s\n' "$train" >&2
  # Report the COUNT of high-signal matches, never the matched secret text itself (printing the
  # values would leak the very credentials we are warning about to the terminal / any log capturing stderr).
  [ "${OSRC_SECRET_HIT_COUNT:-0}" -gt 0 ] 2>/dev/null && printf '>>>   secret scan : %s high-signal credential pattern(s) detected in prompt/--with (values redacted)\n' "$OSRC_SECRET_HIT_COUNT" >&2
  # A skipped credential scan is never silent: the one case where the gate stood down is the case the
  # operator most needs to see named, every single time.
  _lane_trusted_for_pwd "$lane" && printf '>>>   trust       : credential-file scan SKIPPED — lane '"'"'%s'"'"' is trusted for %s (trusted-lanes.json / --trust-lane). Pasted-secret and pattern scans still ran.\n' "$lane" "$cwd" >&2
  # acknowledge: env/flag ack (persisted for next time), else remembered consent, else interactive
  # prompt (persisted on yes), else fail-closed refuse with the one-time-fix spelled out.
  if [ "${OSRC_CLOUD_ACK:-0}" = "1" ]; then
    _cloud_consent_persist; export OSRC_CLOUD_ACKED=1; return 0
  fi
  if _cloud_consent_ok; then
    printf '>>>   consent     : remembered grant in %s (revoke: %s consent revoke)\n' "${OSRC_CONSENT_FILE/#$HOME/~}" "$0" >&2
    export OSRC_CLOUD_ACKED=1; return 0
  fi
  if [ -t 0 ] && [ -t 2 ]; then
    printf '>>>   Acknowledge cloud disclosure? (remembered for future runs) [y/N] ' >&2
    local ans=""; IFS= read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) _cloud_consent_persist; export OSRC_CLOUD_ACKED=1; return 0 ;; esac
    die "CLOUD GATE: disclosure declined interactively — refusing cloud route. Re-run with OSRC_CLOUD_ACK=1 or --cloud-ack."
  fi
  die "CLOUD GATE: cloud delegation needs a ONE-TIME consent (this run sends repo content to a third-party API). Fix once, never see this again:
    $0 consent grant        # remember consent for all future runs
  or pass --cloud-ack on this command (also remembered). Local ollama/lmstudio lanes never need this."
}

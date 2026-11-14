#!/usr/bin/env bash
# perm.sh — `--perm safe|default` permission profiles for interactive `session start`,
# plus the session-launch helpers moved here from outsourcerer.sh (file-size ratchet:
# outsourcerer.sh is legacy and may only shrink; new code lives in scripts/lib/).
#
# Loaded by the byte-identical CONTRACT line in outsourcerer.sh directly after
# `OSRC_JOBS="$OSRC_HOME/jobs"`, and again from the real script dir after the factory
# loader (see briefs/LOADER.md — the second line covers sourced mode and symlinked
# invocation, where $SCRIPT_DIR does not point at this file's folder).
#
# osrc_perm_flags <engine> <profile> <workdir>
#   Prints the EXTRA launch flags for the profile, one argv element per line.
#   profile=default (or an engine with no faithful safe rung) prints NOTHING, so the
#   launch is byte-identical to before. Every flag below was verified against the
#   engine's own --help / bundled docs — see sessions/2026-11-13-autonomy/out/L5-AUDIT.md.

# ---- moved verbatim from outsourcerer.sh (session-launch helpers) ---------------

_session_launch_error() {
  local provider="$1" reason="$2"
  die "session start: $provider interactive launch unavailable ($reason). Use '$0 --provider $provider run \"task\"' for one-shot work or '$0 --provider $provider bg run \"task\"' for supervised background work."
}

_session_probe_help() {
  local probe_file rc=0
  probe_file="$(mktemp "${TMPDIR:-/tmp}/osrc-session-probe.XXXXXX" 2>/dev/null)" || return 1
  _timeout 3 "$@" > "$probe_file" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$probe_file" ]; then
    rm -f "$probe_file"
    [ "$rc" -ne 0 ] && return "$rc"
    return 1
  fi
  cat "$probe_file"
  rm -f "$probe_file"
}

_session_shell_command() {
  local arg quoted out=""
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    [ -n "$out" ] && out="$out "
    out="$out$quoted"
  done
  printf '%s\n' "$out"
}

# _session_help_has_model_flag <help-text> -> 0 if a model override flag is documented in the FULL
# help text, 1 otherwise. Matches both long (--model <id> / --model=<id>) and short (-m <id> /
# -m, --model <id>) forms, delimited so a flag like --mode or -mode cannot false-positive. This is
# the evidence-based proof behind the general model-pin guard: a lane may only append a model flag
# to an interactive launch when its own CLI documents that flag at the level being invoked. The
# droid bug was an unverified COMMENT asserting "interactive droid accepts --model too" — the flag
# was never in `droid --help`, fell through into the prompt, and the run billed Claude quota on the
# DEFAULT model (claude-opus-5). Verifying the real --help (never truncated) is the only proof.
_session_help_has_model_flag() {
  # Here-string, not a pipeline: help text is never truncated, so it can outgrow the pipe buffer
  # and `printf | grep -q` would take grep's early-exit SIGPIPE (141) under pipefail as a miss.
  grep -Eq -- '--model([ =]|$)|(^|[[:space:],])-m([[:space:],]|$)' <<<"$1"
}

# _session_assert_model_pinnable <provider> <cli> [help-args...] -> probe the real CLI help and
# REFUSE (via _session_launch_error) if no model override flag is documented at the level being
# invoked. Returns 0 silently when the flag is proven present. This is the general guard: a lane
# that cannot PROVE it honors an explicit model must fail loudly, never start on the lane default
# and bill silently. A failed/timed-out probe is also a refusal — "could not prove it" is not "it
# is supported". <help-args> are the subcommand/help args to probe (e.g. `hermes chat --help`).
#
# Uses a GENEROUS timeout (OSRC_SESSION_MODEL_PROBE_SECS, default 8) rather than the 3s
# _session_probe_help cap: this is a once-per-session safety check, and heavy node CLIs (e.g.
# gemini-cli) can take ~5s to print --help on a cold start. A 3s cap falsely refused a lane that
# DOES document -m/--model, which is its own kind of silent breakage. The cost is paid only when a
# model is explicitly pinned (MODEL_EXPLICIT=1), not on every session start.
_session_assert_model_pinnable() {
  local provider="$1" cli="$2"; shift 2
  local help_text probe_file rc=0
  probe_file="$(mktemp "${TMPDIR:-/tmp}/osrc-mpg.XXXXXX" 2>/dev/null)" || _session_launch_error "$provider" "model-flag probe: could not create a temp file"
  _timeout "${OSRC_SESSION_MODEL_PROBE_SECS:-8}" "$cli" "$@" > "$probe_file" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$probe_file" ]; then
    rm -f "$probe_file"
    _session_launch_error "$provider" "the model-flag help probe for \`$cli $*\` failed or timed out (rc=$rc) — cannot prove interactive model pinning, refusing rather than billing on the lane default"
  fi
  help_text="$(cat "$probe_file")"; rm -f "$probe_file"
  _session_help_has_model_flag "$help_text" \
    || _session_launch_error "$provider" "interactive $provider has no model override in \`$cli $*\` (verified against the real CLI --help). A --model/-m token would not be honored and the run would proceed on the lane DEFAULT model, billing silently. Drop -m to use the lane's configured model, or use the lane's exec/delegate path (e.g. '$0 --provider $provider run -m <model> \"task\"') where the flag is documented."
}

# ---- --perm safe|default ---------------------------------------------------------

# Canonical "safe" shell-command prefixes: read-only commands, git read commands, and
# test/lint/build commands. One prefix per line; emitters turn each into the engine's
# native allow syntax. Everything not matching still prompts — the list only removes
# prompts for routine dev work.
#
# Deliberately EXCLUDED (they prompt): env/xargs/parallel/watch/nice/nohup/time/command
# (exec wrappers), awk/perl/ruby/python/node (arbitrary code — only the `-m pytest|unittest`
# forms are listed), make/just/task/tox/nox (task runners), npm exec/npx/bunx/uv/poetry run
# (fetch+exec), curl/wget/ssh/scp/rsync/sftp, docker/kubectl/aws/gcloud/az/terraform/
# vercel/firebase/netlify, psql/mysql/sqlite3/redis-cli/mongosh, tmux/screen/osascript/
# automator/open/launchctl/crontab/at/batch, sudo/doas, git mutating verbs (push/pull/
# fetch/commit/checkout/restore/reset/clean/rebase/merge/am/apply/cherry-pick/revert/
# stash-mutations/worktree add|remove|prune/submodule update|init/bisect/gc/prune/
# update-ref/read-tree/write-tree/commit-tree/mktree/hash-object), tar/unzip/zip/patch/
# cp/mv/ln/install/dd/tee/touch/mkdir/rmdir/chmod/chown/xattr/chflags, less/more/vim/
# nano/emacs/bat/man (interactive — would stall a turn), sed/yq (in-place write forms
# can't be prefix-excluded), sips (--out writes), npm install/i/ci/add/remove/update/
# publish/link, pip install/download, brew install/uninstall, gem install, apt/yum/
# dnf/pacman/zypper entirely, jq kept (no write flags).
#
# Also excluded after review (L5 round 2): printenv (dumps every secret in the
# environment into the delegate's context), defaults read / nvram -p (can print stored
# tokens), mount (bare form lists, but `mount <dev> <dir>` mutates — the prefix emitter
# cannot exclude the arg form), gh api (a later -X DELETE on the same line is not
# excluded by a GET prefix), and commands that never return on their own — ping,
# traceroute, nettop, fs_usage, log stream, syslog, gh run watch, sleep, tail -f (via
# ask rules), log show (unbounded dump) — for the same reason interactive pagers are
# excluded: they would stall the delegate's turn. black/isort write in place by
# default (no read-only form to allow); prettier/eslint/ruff keep their read-only
# defaults and their write flags are ask-listed instead.
#
# Prefix-write holes verified live in a scratch repo and removed: `git remote -v`
# (its ` *` tail accepts `git remote -v prune|update` — prune RAN, verified), bare
# `git reflog` (`git reflog expire|drop` mutate), and both `git symbolic-ref` forms
# (`git symbolic-ref [--short] HEAD <ref>` WRITES HEAD — verified rc=0). git's own
# action-conflict guard rejects the smuggled combos on the kept entries
# (`branch -a -d`, `tag -l -d`, `config -l --add`, `worktree list prune` all error).
_osrc_perm_safe_cmds() {
  cat <<'EOF'
ls
cat
head
tail
grep
egrep
fgrep
rg
ag
fd
eza
exa
wc
file
stat
readlink
realpath
basename
dirname
pwd
echo
printf
which
whereis
type
date
uname
hostname
whoami
id
arch
nproc
locale
tree
du
df
ps
lsof
netstat
jq
sort
uniq
cut
tr
column
diff
cmp
md5
shasum
cksum
true
false
sw_vers
find
git status
git diff
git log
git show
git blame
git grep
git ls-files
git ls-tree
git ls-remote
git rev-parse
git rev-list
git describe
git shortlog
git merge-base
git name-rev
git cherry
git show-branch
git count-objects
git fsck
git cat-file
git verify-commit
git verify-tag
git stash list
git stash show
git worktree list
git submodule status
git remote show
git remote get-url
git branch --show-current
git branch --list
git branch -a
git tag -l
git tag --list
git reflog show
git config --get
git config --get-all
git config --list
git config -l
git var
git version
gh pr view
gh pr list
gh pr checks
gh pr diff
gh issue view
gh issue list
gh run list
gh run view
gh release view
gh release list
gh repo view
npm test
npm run test
npm run lint
npm run build
npm run typecheck
npm run check
npm ls
npm list
npm outdated
npm explain
npm why
npm view
npm fund
npm search
yarn test
yarn lint
yarn build
yarn typecheck
yarn run test
yarn run lint
yarn run build
yarn run typecheck
yarn list
yarn info
yarn why
pnpm test
pnpm lint
pnpm build
pnpm typecheck
pnpm run test
pnpm run lint
pnpm run build
pnpm run typecheck
pnpm run check
pnpm ls
pnpm list
pnpm why
pytest
py.test
python -m pytest
python3 -m pytest
python -m unittest
python3 -m unittest
cargo test
cargo build
cargo check
cargo clippy
go test
go build
go vet
go list
dotnet test
dotnet build
mvn test
mvn verify
mvn compile
mvn package
./mvnw test
./mvnw verify
./mvnw compile
./mvnw package
gradle test
gradle build
gradle check
./gradlew test
./gradlew build
./gradlew check
mix test
swift test
swift build
deno test
deno check
deno lint
bun test
rspec
phpunit
php artisan test
jest
vitest
mocha
ava
cypress run
playwright test
eslint
prettier
ruff check
mypy
pyright
tsc --noEmit
pip list
pip show
pip freeze
pip3 list
pip3 show
pip3 freeze
gem list
gem contents
brew list
brew info
brew search
brew leaves
brew deps
brew cat
plutil -p
plutil -lint
codesign -dv
xcodebuild -list
system_profiler
ioreg
kextstat
vm_stat
log stats
diskutil list
diskutil info
diskutil apfs list
hdiutil info
hdiutil imageinfo
qlmanage -m
spctl --status
spctl -a -vv
csrutil status
fdesetup status
pmset -g
EOF
}

# Ask-listed patterns: matched commands PROMPT (not allow, not deny) even when an allow
# prefix would cover them. Covers the dangerous corners INSIDE allowed families:
# find -delete/-exec/-ok/-fprint/-fls, output-file writers (--out*, sort -o is left to
# Claude's own path guard), exec-via-flag commands (fd -x/-X/--exec, rg/ag --pre/
# --pager/--hostname-bin, git grep -O / --open-files-in-pager, sort
# --compress-program), formatter/test-runner write+stall flags (prettier --write,
# eslint --fix/-o, ruff --fix, go/dotnet/cargo output-dir flags, --watch/--ui/--debug/
# --pdb interactive modes, tail -f, lsof +r, gh --watch, playwright --ui/--debug),
# secret exposure (ps env forms), and .git writers (git fsck --lost-found).
#
# Claude Code rule order is deny -> ask -> allow and a matching ask rule prompts even
# when a MORE SPECIFIC allow rule also matches — there is no specificity tiebreak
# (code.claude.com/docs/en/permissions). Verified live on Claude Code 2.1.323
# (claude-haiku-5-5, -p): `ls && rm -rf dir`, `ls && touch f`, `echo $(touch f)`,
# `cat f | sh`, and `echo x > f` were all stopped by Claude's OWN command parser
# before the allow rules mattered — it splits compounds, refuses unverifiable nested
# commands, and asks before any file creation even inside the workdir. The `>`/`<`
# ask rules were therefore redundant and are dropped: they cost the commonest
# delegate command (`2>&1 | tail`, `2>/dev/null`) a prompt for no added safety.
# What remains asks on flags the parser does not model as separate operations.
_osrc_perm_ask_patterns() {
  printf '%s\n' \
    'Bash(*-delete*)' 'Bash(*-exec*)' 'Bash(*-ok*)' 'Bash(*-fprint*)' 'Bash(*-fls*)' 'Bash(*--out*)' \
    'Bash(*--ext-diff*)' 'Bash(*--textconv*)' \
    'Bash(fd *-x*)' 'Bash(fd *-X*)' 'Bash(fd *--exec*)' \
    'Bash(rg *--pre*)' 'Bash(rg *--hostname-bin*)' 'Bash(rg *--pager*)' 'Bash(ag *--pager*)' \
    'Bash(sort *--compress-program*)' \
    'Bash(git grep *-O*)' 'Bash(git grep *--open-files-in-pager*)' 'Bash(git fsck *--lost-found*)' \
    'Bash(tail *-f*)' 'Bash(tail *-F*)' 'Bash(tail *--follow*)' \
    'Bash(ps e*)' 'Bash(ps * e*)' 'Bash(ps *-E*)' \
    'Bash(lsof *+r*)' \
    'Bash(*--watch*)' 'Bash(*--pdb*)' \
    'Bash(playwright *--ui*)' 'Bash(playwright *--debug*)' 'Bash(vitest *--ui*)' \
    'Bash(go build *-o*)' 'Bash(go test *-o*)' 'Bash(dotnet *-o *)' 'Bash(cargo *--target-dir*)' \
    'Bash(eslint *--fix*)' 'Bash(eslint *-o *)' \
    'Bash(prettier *--write*)' 'Bash(ruff *--fix*)'
}

# Script-name families that also appear in colon form (`npm run test:unit`, `yarn build:prod`).
# The ` *` space form misses the colon, so emitters add the `:*` trailing-wildcard variant.
_osrc_perm_colon_families() {
  printf '%s\n' \
    'npm run test' 'npm run lint' 'npm run build' 'npm run typecheck' 'npm run check' \
    'yarn test' 'yarn lint' 'yarn build' 'yarn typecheck' \
    'yarn run test' 'yarn run lint' 'yarn run build' 'yarn run typecheck' \
    'pnpm test' 'pnpm lint' 'pnpm build' 'pnpm typecheck' \
    'pnpm run test' 'pnpm run lint' 'pnpm run build' 'pnpm run typecheck' 'pnpm run check'
}

# _osrc_perm_claude_args -> --allowedTools rules + --settings ask-list for `claude` safe mode.
# Rule syntax per code.claude.com/docs/en/permissions: `Bash(<prefix>)` exact,
# `Bash(<prefix> *)` prefix+args; `Edit(./**)`/`Write(./**)` scope file edits to the
# session workdir (cwd). Read/Grep/Glob are always-safe tool names.
_osrc_perm_claude_args() {
  local p s a asks=''
  printf '%s\n' '--allowedTools' 'Read' 'Grep' 'Glob' 'Edit(./**)' 'Write(./**)'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf 'Bash(%s)\n' "$p"
    printf 'Bash(%s *)\n' "$p"
  done < <(_osrc_perm_safe_cmds)
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf 'Bash(%s:*)\n' "$s"
  done < <(_osrc_perm_colon_families)
  printf '%s\n' '--settings'
  while IFS= read -r a; do asks="$asks\"$a\","; done < <(_osrc_perm_ask_patterns)
  asks="${asks%,}"
  printf '{"permissions":{"ask":[%s]}}\n' "$asks"
}

# _osrc_perm_gemini_args <workdir> -> --approval-mode auto_edit only: gemini-cli's edit
# tools auto-approve while shell commands keep the default approval behavior.
#
# A generated [[rule]] policy file was tried and WITHDRAWN (L5 round 2, review finding
# 3): commandRegex is tested against the tool-call JSON args, and the round-1 regexes
# both stopped at the first quoted string (`[^\"]*`) and anchored only the first word,
# so `echo "hi" > ~/.zshrc`, `find . -delete`, `ls && rm -rf ~`, `cat a | sh` and
# `sort -o /tmp/x` all evaluated as allow. gemini-cli refuses OAuth on this machine,
# so no live session can prove a corrected policy — per the review, emit only
# auto_edit until one does.
_osrc_perm_gemini_args() {
  printf '%s\n' '--approval-mode' 'auto_edit'
}

# osrc_perm_apply_launch <provider> <lane> — append the safe-profile flags to the
# SESSION_LAUNCH array built by a _session_launch_* adapter. Called from
# _session_launch_adapter after the lane fn returns. Engines whose safe rung is a
# SUBSTITUTION rather than an append (cx: --approve-for-me replaces -s) handle
# PERM_PROFILE inside their own adapter; everything else lands here.
# A flag-generation failure is fatal: silently launching with default permissions
# under a "safe" banner is exactly the lie the banner exists to prevent.
osrc_perm_apply_launch() {
  local provider="$1" lane="$2" eng _pa _flags
  eng="${SESSION_LAUNCH_ENGINE:-$lane}"   # separate stmt: `local a= b=$a` expands before assign
  [ "${PERM_PROFILE:-default}" = "default" ] && return 0
  type osrc_perm_flags >/dev/null 2>&1 \
    || _session_launch_error "$provider" "--perm $PERM_PROFILE needs scripts/lib/perm.sh, which is missing from this install"
  _flags="$(osrc_perm_flags "$eng" "$PERM_PROFILE" "$PWD")" \
    || _session_launch_error "$provider" "--perm safe flag generation failed for engine '$eng'"
  while IFS= read -r _pa; do [ -n "$_pa" ] && SESSION_LAUNCH+=("$_pa"); done <<< "$_flags"
  # Explicit rc0: a no-rung engine yields empty _flags, and the while/read above
  # returns 1 at EOF — without this the ADAPTER reports failure for exactly the
  # engines safe mode is supposed to launch unchanged (droid/hermes/cline/pi).
  return 0
}

# osrc_perm_desc <engine> -> one-line honest description of what `safe` actually does
# for that engine, or rc 1 when the engine has no faithful safe rung. "safe" is NOT
# one thing across engines (review finding 4): Claude gets an explicit allow-list;
# devin/codex/cursor get the engine's OWN auto-approval rung, where a model or server
# classifier judges each action — not a list; agy gets the vendor's auto mode;
# gemini-cli gets edit-tools-only auto-approval. The launch banner prints this so the
# receipt never claims an allow-list the engine does not have.
osrc_perm_desc() {
  case "$1" in
    devin|dv)          printf '%s' "devin --permission-mode smart (MODEL-JUDGED: a fast model auto-runs what it judges safe; installs, mutating git, rm/sudo, dotenv/keys still prompt)" ;;
    cx|codex)          printf '%s' "codex --approve-for-me (MODEL-JUDGED: approval requests route through automatic review; replaces -s workspace-write)" ;;
    cc|claude)         printf '%s' "claude --allowedTools allow-list + ask rules (EXPLICIT LIST: read-only/git-read/test-build commands + workspace edits; deletes, exec-flags, redirects and everything else still prompt)" ;;
    cursor)            printf '%s' "cursor --auto-review (CLASSIFIER-JUDGED: a server classifier auto-runs safe tool calls)" ;;
    agy|antigravity)   printf '%s' "agy --mode auto (engine auto mode per vendor docs — not an allow-list)" ;;
    gemini|gmnative|gm) printf '%s' "gemini-cli --approval-mode auto_edit (edit tools auto-approve; shell commands still ask)" ;;
    *)                 return 1 ;;
  esac
}

# _osrc_perm_banner <provider> — print the honest [perm] line after a safe-profile
# launch is built. No-op unless PERM_PROFILE=safe. Engines with no faithful rung get
# an explicit "launched default" line instead of a false success banner.
_osrc_perm_banner() {
  [ "${PERM_PROFILE:-default}" = "safe" ] || return 0
  local _pb_eng="${SESSION_LAUNCH_ENGINE:-$1}" _pb_desc
  if _pb_desc="$(osrc_perm_desc "$_pb_eng" 2>/dev/null)"; then
    printf '>>> [perm] safe — %s. Anything outside still prompts.\n' "$_pb_desc" >&2
  else
    printf '>>> [perm] safe: no faithful safe rung for %s; launched with DEFAULT permissions (everything prompts).\n' "$1" >&2
  fi
}

# osrc_perm_string_suffix <engine> <profile> -> prints " <flag> <flag>..." with each
# flag %q-quoted, for launch vectors carried as ONE shell string (tmux send-keys,
# winpty launch.bash is an array and does NOT use this, respawn-pane). default or a
# no-rung engine prints nothing; rc 1 when safe was requested but osrc_perm_flags is
# unavailable, so callers can die loudly instead of launching unprotected.
osrc_perm_string_suffix() {
  local eng="$1" prof="${2:-default}" _pa out=""
  [ "$prof" = "safe" ] || return 0
  type osrc_perm_flags >/dev/null 2>&1 || return 1
  while IFS= read -r _pa; do [ -n "$_pa" ] && out="$out $(printf '%q' "$_pa")"; done < <(osrc_perm_flags "$eng" "$prof" "$PWD")
  printf '%s' "$out"
}

# _osrc_perm_restore_profile <session-id> — set the global PERM_PROFILE from the
# session's latest start record (registry field 5, written by _session_registry_append
# at launch). Relaunch/effort-relaunch rebuild the command from scratch, so without
# this a `--perm safe` session silently comes back with default permissions. Records
# written before L5 lack the field -> env/default. Not local: the relaunch_fn lanes
# and the registry append read the global.
_osrc_perm_restore_profile() {
  local _ps_saved
  _ps_saved="$(_session_record "$1" 2>/dev/null | cut -f5)"
  case "$_ps_saved" in safe|default) PERM_PROFILE="$_ps_saved" ;; *) PERM_PROFILE="${PERM_PROFILE:-${OSRC_PERM_PROFILE:-default}}" ;; esac
  case "$PERM_PROFILE" in safe|default) ;; *) PERM_PROFILE=default ;; esac
}

# ---- session relaunch vectors (moved from outsourcerer.sh for the size ratchet) ---
# Both read the global PERM_PROFILE, which _session_control_relaunch restores from
# the session's registry record before calling _session_relaunch_command.

# _session_cc_uuid_valid <id> -> 0 only for a real claude sessionId shape (a
# UUID). --resume takes the value verbatim, so the check must be strict: the
# looser _external_session_id_valid charset accepts a leading-dash id like
# --dangerously-skip-permissions, which claude would read as a flag, and any
# process the delegate starts can plant a matching ~/.claude/sessions file.
_session_cc_uuid_valid() {
  printf '%s\n' "${1:-}" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

# _session_cc_resume_id <tmux-pane> -> the pane claude's sessionId for
# `claude --resume <id>`, or nothing (= the caller falls back to --continue).
# Live proof first: ~/.claude/sessions/*.json maps the running claude pid to its
# sessionId via _fleet_cc_session_for_pane; the registry start record's
# cc_session_id is the fallback for a pane whose session file is already gone.
# --resume beats --continue because --continue picks the newest conversation in
# the folder, which may be a DIFFERENT session's when two claude panes share a
# cwd; the id pins this pane's own conversation.
_session_cc_resume_id() {
  local pane="$1" pid cwd match sid
  pid="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)"
  cwd="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  if [ -n "$cwd" ]; then cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || cwd=""; fi
  if [ -n "$pid" ] && [ -n "$cwd" ]; then
    match="$(_fleet_cc_session_for_pane "$pid" "$cwd" 2>/dev/null)" || match=""
    sid="${match%%$'\t'*}"
    _session_cc_uuid_valid "$sid" && { printf '%s\n' "$sid"; return 0; }
  fi
  sid="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$pane" 'select(.event=="start" and .session_id==$id) | .cc_session_id // empty' | tail -1)"
  _session_cc_uuid_valid "$sid" && printf '%s\n' "$sid"
}

# _session_cc_resume_for <prov> <pane> -> the resume id for cc/claude panes,
# empty for every other provider (and whenever no id can be proven).
_session_cc_resume_for() {
  case "$1" in cc|claude) _session_cc_resume_id "$2" 2>/dev/null ;; esac
}

# Relaunch command for `session effort` on a cc session (claude honors effort via
# MAX_THINKING_TOKENS plus the session-scoped --effort flag). $3 is the pane's
# claude sessionId when known: --resume <id> pins THIS conversation, --continue
# (the fallback) picks the newest in the folder and can grab a sibling pane's.
# --perm safe adds the same allow-list/ask-rules suffix session start emits
# (default -> empty suffix). No effort -> rc1 (the caller leaves it intact).
_session_relaunch_cc() {
  local tokens suffix flag resume="${3:-}"
  tokens="$(_effort_thinking_tokens "$2")"
  [ -n "$tokens" ] || return 1
  suffix="$(osrc_perm_string_suffix cc "${PERM_PROFILE:-default}")" || return 1
  flag="$(_cc_effort_flag "$2")"
  printf 'env MAX_THINKING_TOKENS=%q -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude --model %q' "$tokens" "$1"
  if _session_cc_uuid_valid "$resume"; then printf ' --resume %q' "$resume"; else printf ' --continue'; fi
  printf '%s' "$suffix"
  if [ -n "$flag" ] && _session_cc_effort_supported; then printf ' --effort %q' "$flag"; fi
}

# Relaunch command for codex/cx. --perm safe applies the SAME substitution as
# session start: --approve-for-me replaces `-s workspace-write` (the two conflict).
_session_relaunch_cx() { # <model> <effort> -> relaunch command string
  local cid code_mode_host sbx
  cid="$(resolve_model_row "$1")"; cid="${cid%%|*}"; [ -n "$cid" ] || cid="$1"
  _validate_model_token "$cid"
  code_mode_host="$(_codex_code_mode_host_flag)" || return 1
  sbx="-s workspace-write"
  [ "${PERM_PROFILE:-default}" = "safe" ] && sbx="--approve-for-me"
  printf 'codex -m %q %s -c features.code_mode_host=%q -c model_reasoning_effort=%q' "$cid" "$sbx" "$code_mode_host" "$2"
}

# osrc_perm_flags <engine> <profile> <workdir> — see header. Engine keys accept both
# provider tokens and lane names; gm resolves to its vehicle via OSRC_GEMINI_VEHICLE
# or a PATH probe when called directly.
osrc_perm_flags() {
  local engine="$1" profile="$2" workdir="${3:-$PWD}"
  [ "$profile" = "safe" ] || return 0
  case "$engine" in
    devin|dv)        printf '%s\n' '--permission-mode' 'smart' ;;
    cx|codex)        printf '%s\n' '--approve-for-me' ;;
    cc|claude)       _osrc_perm_claude_args ;;
    cursor)          printf '%s\n' '--auto-review' ;;
    agy|antigravity) printf '%s\n' '--mode' 'auto' ;;
    gemini|gmnative|gm)
      # The gm lane's safe flags depend on its VEHICLE: agy has --mode auto; gemini-cli
      # gets --approval-mode auto_edit (edit tools auto-approve, shell commands still
      # ask). SESSION_LAUNCH_ENGINE normally carries the resolved vehicle; direct calls
      # resolve it the same way _session_launch_gm does.
      local veh="${SESSION_LAUNCH_ENGINE:-${OSRC_GEMINI_VEHICLE:-}}"
      [ -n "$veh" ] || { command -v agy >/dev/null 2>&1 && veh=agy; }
      [ -n "$veh" ] || { command -v gemini >/dev/null 2>&1 && veh=gemini; }
      [ -n "$veh" ] || veh=gemini
      case "$veh" in
        agy)    printf '%s\n' '--mode' 'auto' ;;
        *)      _osrc_perm_gemini_args "$workdir" ;;
      esac ;;
    *)               : ;;  # droid/hermes/cline/pi/warp/etc: no faithful per-launch safe rung
  esac
}

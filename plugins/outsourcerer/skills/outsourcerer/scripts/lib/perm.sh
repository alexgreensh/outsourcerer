#!/usr/bin/env bash
# perm.sh — `--perm safe|default` permission profiles for interactive `session start`,
# plus the session-launch helpers moved here from outsourcerer.sh (file-size ratchet:
# outsourcerer.sh is legacy and may only shrink; new code lives in scripts/lib/).
#
# Loaded by the byte-identical loader line in outsourcerer.sh directly after
# `OSRC_JOBS="$OSRC_HOME/jobs"`:
#   for _osrc_lib in "$SCRIPT_DIR"/lib/*.sh; do [ -r "$_osrc_lib" ] && . "$_osrc_lib"; done; unset _osrc_lib
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
printenv
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
ping
traceroute
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
sleep
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
git remote -v
git remote show
git remote get-url
git branch --show-current
git branch --list
git branch -a
git tag -l
git tag --list
git reflog
git reflog show
git symbolic-ref HEAD
git symbolic-ref --short HEAD
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
gh run watch
gh release view
gh release list
gh repo view
gh api --method GET
gh api -X GET
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
ruff
mypy
pyright
black
isort
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
defaults read
plutil -p
plutil -lint
codesign -dv
xcodebuild -list
system_profiler
ioreg
kextstat
vm_stat
nettop
fs_usage
log show
log stream
log stats
syslog
diskutil list
diskutil info
diskutil apfs list
mount
hdiutil info
hdiutil imageinfo
qlmanage -m
spctl --status
spctl -a -vv
csrutil status
fdesetup status
nvram -p
pmset -g
EOF
}

# Ask-listed patterns: matched commands PROMPT (not allow, not deny) even when an allow
# prefix would cover them. Covers the dangerous corners INSIDE allowed families:
# find -delete/-exec/-ok/-fprint/-fprintf, git diff --output / sips-style --out writers,
# and shell redirection (<, >) which would otherwise let `echo x > ~/.ssh/authorized_keys`
# ride an allowed `echo`. `2>/dev/null` prompts too — the safe direction; the orchestrator
# can still approve it in one keystroke. NOTE: where the engine resolves ask-vs-allow by
# specificity, a more specific allow (e.g. `Bash(git diff *)`) can win — the residual is
# documented in L5-REPORT.md; gemini's policy engine resolves by priority so ask wins there.
_osrc_perm_ask_patterns() {
  printf '%s\n' \
    'Bash(*>*)' 'Bash(*<*)' \
    'Bash(*-delete*)' 'Bash(*-exec*)' 'Bash(*-ok*)' 'Bash(*-fprint*)' 'Bash(*--out*)'
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

# _osrc_perm_gemini_args <workdir> -> --approval-mode auto_edit (edit tools auto-approve)
# plus --policy <file>: a generated user-tier TOML whose [[rule]] entries map the same
# safe prefixes to decision="allow" and the dangerous corners to decision="ask_user".
# Verified against @google/gemini-cli 0.58.0 bundled docs/reference/policy-engine.md:
# commandRegex is tested against the tool-call JSON args (`{"command":"..."}`), rules
# resolve by highest priority, and ask_user prompts interactively. Policy file lives under
# $OSRC_HOME/perm/ so it survives across sessions and never touches the repo.
_osrc_perm_gemini_policy() {
  local path="$1" alts='' p rx
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # regex-escape the only metachar present in the list ('.' in ./mvnw, ./gradlew)
    rx="${p//./[.]}"
    alts="$alts|$rx"
  done < <(_osrc_perm_safe_cmds)
  alts="${alts#|}"
  mkdir -p "$(dirname "$path")" 2>/dev/null
  {
    printf '# Generated by outsourcerer --perm safe — do not edit; regenerated each launch.\n'
    printf 'version = 1\n\n[policy]\n\n'
    printf '[[rule]]\ntoolName = "run_shell_command"\npriority = 100\ndecision = "allow"\n'
    printf 'commandRegex = '"'"'"command":"(%s)(\\s|")'"'"'\n\n' "$alts"
    printf '[[rule]]\ntoolName = "run_shell_command"\npriority = 200\ndecision = "ask_user"\n'
    printf 'commandRegex = '"'"'"command":"[^"]*(-delete|-exec|-ok|-fprint|--out|>|<)'"'"'\n'
  } > "$path" 2>/dev/null
  chmod 600 "$path" 2>/dev/null
  [ -s "$path" ] || return 1
}

_osrc_perm_gemini_args() {
  local workdir="${1:-$PWD}" path
  path="${OSRC_HOME:-$HOME/.outsourcerer}/perm/gemini-safe.toml"
  _osrc_perm_gemini_policy "$path" || return 1
  printf '%s\n' '--approval-mode' 'auto_edit' '--policy' "$path"
}

# osrc_perm_apply_launch <provider> <lane> — append the safe-profile flags to the
# SESSION_LAUNCH array built by a _session_launch_* adapter. Called from
# _session_launch_adapter after the lane fn returns. Engines whose safe rung is a
# SUBSTITUTION rather than an append (cx: --approve-for-me replaces -s) handle
# PERM_PROFILE inside their own adapter; everything else lands here.
osrc_perm_apply_launch() {
  local provider="$1" lane="$2" eng _pa
  eng="${SESSION_LAUNCH_ENGINE:-$lane}"   # separate stmt: `local a= b=$a` expands before assign
  [ "${PERM_PROFILE:-default}" = "default" ] && return 0
  type osrc_perm_flags >/dev/null 2>&1 \
    || _session_launch_error "$provider" "--perm $PERM_PROFILE needs scripts/lib/perm.sh, which is missing from this install"
  while IFS= read -r _pa; do [ -n "$_pa" ] && SESSION_LAUNCH+=("$_pa"); done \
    < <(osrc_perm_flags "$eng" "$PERM_PROFILE" "$PWD" 2>/dev/null)
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
      # gets the generated policy file + auto_edit. SESSION_LAUNCH_ENGINE normally carries
      # the resolved vehicle; direct calls resolve it the same way _session_launch_gm does.
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

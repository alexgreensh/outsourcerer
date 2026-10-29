#!/usr/bin/env bash
# test_cloud_autoisolate.sh -- issue #51: a cloud delegation whose only credential files are gitignored
# (web/.env.local) runs in a secret-free snapshot worktree instead of dying at the cloud gate.
#
# Pins: (1) gitignored+untracked hits -> isolate, the delegate's tree has no secret, uncommitted and
# untracked work is carried, the user's index is untouched; (2) a tracked or unignored secret, a non-git
# dir, the off switch, a local lane and a trusted lane all leave the gate exactly as before; (3) the job
# receipt makes `cleanup <id>` work; (4) end to end: `delegate` with a fake devin starts on the first try
# in the isolated tree; (5) the gate's refusal names the way out when the file is gitignored.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" XDG_CONFIG_HOME="$TMP/xdg" OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$OSRC_HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
unset OSRC_CLOUD_AUTOISOLATE OSRC_JOB_DIR

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# mkrepo <dir> -> a repo with a committed app, a gitignored nested web/.env.local, one uncommitted
# tracked edit, one staged edit and one untracked (not ignored) file.
mkrepo() {
  local d="$1"; mkdir -p "$d/web"; (
    cd "$d" && git init -q
    printf '.env.local\n' > web/.gitignore
    printf 'v1\n' > app.txt; printf 'v1\n' > staged.txt; printf 'page\n' > web/page.txt; printf 'a1\n' > same.txt
    git add -A && git commit -qm init
    printf 'a2\n' > same.txt   # same size, same second as the index write: the racily-clean case
    printf 'SECRET=live\n' > web/.env.local
    printf 'v2-uncommitted\n' > app.txt
    printf 'v2-staged\n' > staged.txt; git add staged.txt
    printf 'new\n' > web/new.txt
  )
}

# In a fresh shell with the script sourced: cd into $1, run the helper for lane $2, print PWD + rc.
iso() { # <dir> <lane> [env...]
  local d="$1" lane="$2"; shift 2
  env "$@" bash -c 'f="$1"; d="$2"; lane="$3"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; cd "$d" || exit 9
    _cloud_autoisolate "$lane"; rc=$?; printf "rc=%s\npwd=%s\n" "$rc" "$PWD"' _ "$SRC" "$d" "$lane" 2>"$TMP/iso.err"
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "=== (1) gitignored-only secret -> isolated snapshot ==="
R="$TMP/r1"; mkrepo "$R"
cached_before="$(git -C "$R" diff --cached --name-only)"
out="$(iso "$R" devin)"; wt="$(field "$out" pwd)"
[ "$(field "$out" rc)" = "0" ] && ok "helper isolates (rc 0)" || bad "helper did not isolate: $out $(cat "$TMP/iso.err")"
case "$wt" in "$R/.outsourcerer/worktrees/run-"*) ok "cwd moved into a repo worktree" ;; *) bad "cwd not in a worktree: $wt" ;; esac
[ ! -e "$wt/web/.env.local" ] && ok "isolated tree has no web/.env.local" || bad "secret copied into the isolated tree"
[ "$(cat "$wt/app.txt" 2>/dev/null)" = "v2-uncommitted" ] && ok "uncommitted tracked edit carried" || bad "uncommitted edit missing"
[ "$(cat "$wt/staged.txt" 2>/dev/null)" = "v2-staged" ] && ok "staged edit carried" || bad "staged edit missing"
[ "$(cat "$wt/same.txt" 2>/dev/null)" = "a2" ] && ok "same-size edit in the same second carried" || bad "racily-clean edit lost: $(cat "$wt/same.txt")"
[ -f "$wt/web/new.txt" ] && ok "untracked (not ignored) file carried" || bad "untracked file missing"
[ -f "$R/web/.env.local" ] && ok "secret left in the original checkout" || bad "original secret was moved"
[ "$(git -C "$R" diff --cached --name-only)" = "$cached_before" ] && ok "user's staging area untouched" || bad "user's index changed"
[ "$(cat "$R/app.txt")" = "v2-uncommitted" ] && ok "original working tree untouched" || bad "original working tree changed"
[ -z "$(git -C "$wt" status --porcelain)" ] && ok "worktree starts clean on the snapshot" || bad "worktree starts dirty"
grep -q 'gitignored secret file(s)' "$TMP/iso.err" && grep -q 'bring back' "$TMP/iso.err" \
  && ok "prints the isolated path and how to bring edits back" || bad "notice missing: $(cat "$TMP/iso.err")"
grep -q 'SECRET=live' "$TMP/iso.err" && bad "notice leaked the secret value" || ok "notice never prints the secret value"
git -C "$R" status --porcelain | grep -q '\.outsourcerer' && bad ".outsourcerer shows up in the user's git status" || ok ".outsourcerer kept out of git status"
# The full gate then passes on the isolated tree.
gate="$(cd "$wt" && bash -c 'f="$1"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _secret_scan "task" devin && echo PASSED' _ "$SRC" 2>&1)"
case "$gate" in *PASSED*) ok "secret scan passes inside the isolated tree" ;; *) bad "gate still blocks in the isolated tree: $gate" ;; esac

echo "=== (1b) run from a subdirectory resumes in the same subdirectory ==="
R="$TMP/r1b"; mkrepo "$R"
out="$(iso "$R/web" devin)"; wt="$(field "$out" pwd)"
case "$wt" in "$R/.outsourcerer/worktrees/"*/web) ok "cwd is <worktree>/web" ;; *) bad "subdir not preserved: $wt" ;; esac

echo "=== (2) cases that must NOT isolate (the gate decides as before) ==="
R="$TMP/r2"; mkrepo "$R"; printf 'K=1\n' > "$R/.env"; git -C "$R" add -f .env; git -C "$R" commit -qm 'tracked env'
out="$(iso "$R" devin)"; [ "$(field "$out" rc)" = "1" ] && ok "tracked .env: no isolation" || bad "tracked .env isolated: $out"
msg="$(cd "$R" && bash -c 'f="$1"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _secret_scan "task" devin' _ "$SRC" 2>&1)"
case "$msg" in *"CLOUD GATE: real credential file"*"/.env "*) ok "tracked .env still hard-blocks and names the path" ;; *) bad "tracked .env not blocked: $msg" ;; esac

R="$TMP/r3"; mkrepo "$R"; printf 'K=1\n' > "$R/.env.production"   # untracked and NOT ignored
out="$(iso "$R" devin)"; [ "$(field "$out" rc)" = "1" ] && ok "unignored .env.production: no isolation" || bad "unignored secret isolated: $out"

D="$TMP/plain"; mkdir -p "$D"; printf 'K=1\n' > "$D/.env.local"
out="$(iso "$D" devin)"; [ "$(field "$out" rc)" = "1" ] && ok "non-git dir: no isolation" || bad "non-git dir isolated"

R="$TMP/r4"; mkrepo "$R"
out="$(iso "$R" devin OSRC_CLOUD_AUTOISOLATE=0)"; [ "$(field "$out" rc)" = "1" ] && ok "OSRC_CLOUD_AUTOISOLATE=0 turns it off" || bad "off switch ignored"
msg="$(cd "$R" && bash -c 'f="$1"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; _secret_scan "task" devin' _ "$SRC" 2>&1)"
case "$msg" in *"It is gitignored"*"git worktree add"*) ok "refusal names the worktree way out for a gitignored file" ;; *) bad "refusal has no hint: $msg" ;; esac
out="$(iso "$R" local)"; [ "$(field "$out" rc)" = "1" ] && ok "local lane: no isolation" || bad "local lane isolated"
[ -z "$(git -C "$R" worktree list | sed -n 2p)" ] && ok "no worktree created by the refused cases" || bad "stray worktree created"

R="$TMP/r5"; mkrepo "$R"; mkdir -p "$XDG_CONFIG_HOME/outsourcerer"
printf '{"devin":["%s"]}\n' "$R" > "$XDG_CONFIG_HOME/outsourcerer/trusted-lanes.json"
out="$(iso "$R" devin)"; [ "$(field "$out" rc)" = "1" ] && ok "trusted lane: no isolation (scan skipped anyway)" || bad "trusted lane isolated"
rm -f "$XDG_CONFIG_HOME/outsourcerer/trusted-lanes.json"

echo "=== (3) job receipt + cleanup ==="
R="$TMP/r6"; mkrepo "$R"; JD="$OSRC_HOME/jobs/job-test-1"
out="$(iso "$R" devin OSRC_JOB_DIR="$JD")"; wt="$(field "$out" pwd)"
case "$wt" in */.outsourcerer/worktrees/job-test-1) ok "job id names the worktree" ;; *) bad "job worktree path: $wt" ;; esac
[ "$(jq -r .branch "$JD/worktree.json" 2>/dev/null)" = "outsourcerer/job-test-1" ] && ok "receipt written to the job dir" || bad "no receipt in $JD"
printf 'edit\n' >> "$wt/app.txt"
cl="$(bash -c 'f="$1"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; cmd_cleanup job-test-1' _ "$SRC" 2>&1)"
case "$cl" in *REFUSING*) ok "cleanup refuses while the delegate's edits are unmerged" ;; *) bad "cleanup did not protect edits: $cl" ;; esac
# The printed bring-back recipe applies the delegate's edits to the original checkout.
(cd "$wt" && git add -A && git diff --cached --binary "$(jq -r .base_sha "$JD/worktree.json")") | git -C "$R" apply \
  && [ "$(tail -n1 "$R/app.txt")" = "edit" ] && ok "bring-back recipe lands the edit in the original checkout" || bad "bring-back recipe failed"
bash -c 'f="$1"; set --; OSRC_SOURCED=1; . "$f" >/dev/null 2>&1; cmd_cleanup job-test-1 --force' _ "$SRC" >/dev/null 2>&1
[ ! -d "$wt" ] && ! git -C "$R" rev-parse -q --verify refs/heads/outsourcerer/job-test-1 >/dev/null \
  && ok "cleanup --force removes the worktree and branch" || bad "cleanup left the worktree/branch"

echo "=== (4) end to end: delegate starts on the first try, in the isolated tree ==="
mkdir -p "$TMP/bin"
cat > "$TMP/bin/devin" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then echo "Logged in"; exit 0; fi
{ echo "cwd=$PWD"; [ -e web/.env.local ] && echo "secret=present" || echo "secret=absent"; cat same.txt; } > "$DEVIN_CAPTURE"
echo ok; exit 0
EOF
chmod +x "$TMP/bin/devin"
# Plain fixture on purpose: no index write after the edit. That is the shape where a stale copy of the
# index (fresh mtime) hid a same-size edit made in the commit's second; mkrepo's later `git add` masks it.
R="$TMP/r7"; mkdir -p "$R/web"
( cd "$R" && git init -q && printf '.env.local\n' > web/.gitignore && printf 'a1\n' > same.txt && git add -A && git commit -qm init \
  && printf 'S=1\n' > web/.env.local && printf 'a2\n' > same.txt )
cap="$TMP/devin.cap"
# Through the real `edit` command, so route_delegate's gate is in the path (delegate() sits below it).
e2e="$(cd "$R" && env PATH="$TMP/bin:$PATH" DEVIN_CAPTURE="$cap" OSRC_CLOUD_ACK=1 bash "$SRC" --provider devin edit -m swe-2 "fix the parser" </dev/null 2>&1)"
if [ -s "$cap" ]; then ok "delegate launched (no gate kill)"; else bad "delegate never launched: $(printf '%s' "$e2e" | grep -m2 'CLOUD GATE\|error')"; fi
grep -q "^cwd=$R/.outsourcerer/worktrees/run-" "$cap" 2>/dev/null && ok "delegate cwd is the isolated worktree" || bad "delegate cwd: $(head -1 "$cap" 2>/dev/null)"
grep -q '^secret=absent' "$cap" 2>/dev/null && ok "delegate cannot see web/.env.local" || bad "delegate saw the secret"
rid="$(basename "$(sed -n 's/^cwd=//p' "$cap" 2>/dev/null)")"
[ -f "$OSRC_HOME/isolated/$rid/worktree.json" ] && [ ! -d "$OSRC_HOME/jobs/$rid" ] \
  && ok "foreground receipt kept out of the jobs list" || bad "foreground receipt misplaced ($rid)"
bash "$SRC" cleanup "$rid" --force >/dev/null 2>&1
[ ! -d "$R/.outsourcerer/worktrees/$rid" ] && ok "cleanup finds a foreground run's worktree" || bad "cleanup missed $rid"
grep -q '^a2' "$cap" 2>/dev/null && ok "delegate sees the uncommitted same-size edit" || bad "delegate missed the uncommitted edit: $(tail -1 "$cap" 2>/dev/null)"

echo "=== structural ==="
awk '/^route_delegate\(\)/{r=1} r && /_cloud_autoisolate "\$disp"/{a=NR} r && /_cloud_disclose "\$disp" "\$RESOLVED_ID"/{print (a && a<NR) ? "ok" : "bad"; exit}' "$SRC" | grep -qx ok \
  && ok "route_delegate isolates right before the cloud gate" || bad "route_delegate does not call _cloud_autoisolate before _cloud_disclose"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

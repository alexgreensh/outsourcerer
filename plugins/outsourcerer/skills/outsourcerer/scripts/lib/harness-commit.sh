# Commit a finished lane's leftover edits only inside its registered job checkout.
_osrc_harness_commit() (
  local wt job="$2" record repo dir scratch lock path rc
  wt="$(cd "$1" && pwd -P)" || return 1
  case "$job" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  record="${OSRC_JOBS:?}/$job/worktree.json"
  repo="${wt%/.outsourcerer/worktrees/*}"
  [ "$wt" = "$repo/.outsourcerer/worktrees/$job" ] || return 1
  local registered gitdir top
  registered="$(jq -er --arg branch "outsourcerer/$job" 'select(.branch==$branch) | .path' "$record")" || return 1
  [ "$(cd "$registered" && pwd -P)" = "$wt" ] || return 1
  dir="$repo/.git/worktrees/$job"
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)" || return 1
  top="$(git -C "$wt" rev-parse --show-toplevel)" || return 1
  [ "$(cd "$gitdir" && pwd -P)" = "$dir" ] &&
    [ "$(cd "$top" && pwd -P)" = "$wt" ] &&
    [ "$(cat "$dir/gitdir")" = "$top/.git" ] &&
    [ "$(cd "$dir/$(cat "$dir/commondir")" && pwd -P)" = "$repo/.git" ] &&
    [ "$(git -C "$wt" symbolic-ref -q HEAD)" = "refs/heads/outsourcerer/$job" ] || return 1

  export GIT_DIR="$dir" GIT_WORK_TREE="$wt"
  scratch="$(mktemp -d "$dir/harness.XXXXXXXX")" || return 1
  trap 'rm -rf "$scratch"' EXIT
  mkdir "$scratch/hooks" || return 1
  # The scan invokes git too. Disable checkout-configured hooks throughout.
  git() { command git -c core.hooksPath="$scratch/hooks" "$@"; }
  lock="$dir/index.lock"
  (set -C; : > "$lock") 2>/dev/null || return 1
  trap 'rm -f "$lock"; rm -rf "$scratch"' EXIT
  export GIT_INDEX_FILE="$scratch/index"
  cp "$dir/index" "$GIT_INDEX_FILE" && git -C "$wt" add -A || return 1
  git -C "$wt" diff --cached --no-renames --name-only --diff-filter=ACMRT -z > "$scratch/paths" || return 1
  while IFS= read -r -d '' path; do
    case "${path##*/}" in
      *.example|*.sample|*.template|*.dist) ;;
      .env|.env.*|credentials|id_rsa|id_ed25519|id_ecdsa|id_dsa|*.pem|*.key|*.p12|*.pfx) return 1 ;;
    esac
  done < "$scratch/paths"
  git -C "$wt" diff --cached --text --no-ext-diff --no-textconv --no-color > "$scratch/diff" || return 1
  rc=0; grep -Eq "$OSRC_SECRET_ADDED_ERE" "$scratch/diff" || rc=$?
  [ "$rc" = 1 ] || return 1
  cp "$GIT_INDEX_FILE" "$lock" || return 1
  git -C "$wt" -c commit.gpgsign=false -c user.name="${OSRC_COMMIT_NAME:-outsourcerer}" -c user.email="${OSRC_COMMIT_EMAIL:-outsourcerer@localhost}" \
    commit -qm "lane $job: work left uncommitted by its sandbox" || return 1
  mv "$lock" "$dir/index" || return 1
  trap 'rm -rf "$scratch"' EXIT
)

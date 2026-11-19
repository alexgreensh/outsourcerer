# Extend the caller's workspace-write flags only for a matching managed checkout.
_codex_worktree_index_args() {
  local wt repo job dir
  wt="$(pwd -P)"
  case "$wt" in */.outsourcerer/worktrees/*) ;; *) return 0 ;; esac
  job="${wt##*/}"
  repo="${wt%/.outsourcerer/worktrees/*}"
  [ "$wt" = "$repo/.outsourcerer/worktrees/$job" ] || return 0
  dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ "$dir" = "$repo/.git/worktrees/$job" ] || return 0
  [ "$(cd "$dir" && pwd -P)" = "$dir" ] || return 0
  [ "$(cat "$dir/gitdir" 2>/dev/null)" = "$wt/.git" ] || return 0
  sflag+=(--add-dir "$dir")
}

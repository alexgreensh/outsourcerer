# _osrc_harness_commit <worktree> <job> -> rc0 when it committed leftover work in a ship worktree.
# A sandboxed lane can edit its worktree but not write the shared git objects and refs, so its
# finished work arrives uncommitted (seen 2026-11-19 on Codex). The done check commits it here,
# outside the sandbox, only when the lane made no commit of its own (partial work stays refused); the check, the secret scan and review that follow still gate it.
_osrc_harness_commit() {
  local wt="$1" job="$2"
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 1
  git -C "$wt" add -A >/dev/null 2>&1 || return 1
  git -C "$wt" -c user.name="${OSRC_COMMIT_NAME:-outsourcerer}" -c user.email="${OSRC_COMMIT_EMAIL:-outsourcerer@localhost}" \
    commit -q -m "lane $job: work left uncommitted by its sandbox" >/dev/null 2>&1
}

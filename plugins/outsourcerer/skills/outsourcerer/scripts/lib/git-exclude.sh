# lib/git-exclude.sh — keep Outsourcerer's per-repo state out of `git status` and `git add -A`, while
# leaving the files a repo is meant to commit addable without -f.
#
# _osrc_git_exclude_state <repo-root> writes this block to the repo's local .git/info/exclude (never the
# tracked .gitignore):
#   /.outsourcerer/*            worker worktrees and lane state stay ignored
#   !/.outsourcerer/guards/     repo guards (lib/guards.sh), incl. guards/slop.allow
#   !/.outsourcerer/guards.conf
#   !/.outsourcerer/verify      the repo's verify command
# Migration: the old single `/.outsourcerer/` line (and any copy of the block lines) is replaced by one
# block at the first such line; every other line stays as it was, in order. Rerunning is a no-op (the
# file is not rewritten). An old line ending in CRLF migrates too. The file is rewritten in place, so a
# symlinked exclude stays a symlink and keeps its mode. Silently gives up if git or the file can't be
# written. Caveat: a TRACKED .gitignore entry `.outsourcerer/` (a directory pattern) still hides the
# carve-outs, because git never looks inside an ignored directory; repos use `.outsourcerer/*` there.
# Moved out of outsourcerer.sh (the legacy file may only shrink); callers: the engine, factory-land.sh,
# lib/cloudgate.sh.

# '|'-separated: BSD awk (macOS) refuses a newline inside a -v value.
_OSRC_EXCLUDE_LINES='/.outsourcerer/*|!/.outsourcerer/guards/|!/.outsourcerer/guards.conf|!/.outsourcerer/verify'

# _osrc_git_exclude_current <file>: 0 when the block is present exactly once, in order, and the old
# `/.outsourcerer/` line is gone.
_osrc_git_exclude_current() {
  [ -f "$1" ] || return 1
  awk -v want="$_OSRC_EXCLUDE_LINES" '
    BEGIN { n = split(want, w, "|"); for (i = 1; i <= n; i++) idx[w[i]] = i }
    { l = $0; sub(/\r$/, "", l) }
    l == "/.outsourcerer/" { bad = 1 }
    l in idx { if ($0 != l) bad = 1; seen[l]++; if (idx[l] != ++pos) bad = 1 }
    END { for (i = 1; i <= n; i++) if (seen[w[i]] != 1) bad = 1; exit bad }' "$1"
}

_osrc_git_exclude_state() {
  local common ex tmp _tb
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*|[A-Za-z]:[/\\]*) ;; *) common="$1/$common" ;; esac
  ex="$common/info/exclude"
  _osrc_git_exclude_current "$ex" && return 0
  mkdir -p "$common/info" 2>/dev/null || return 0
  _tb="${TMPDIR:-/tmp}"; tmp="$(mktemp "${_tb%/}/osrc-exclude.XXXXXX" 2>/dev/null)" || return 0
  if [ -f "$ex" ]; then
    { awk -v want="$_OSRC_EXCLUDE_LINES" '
      BEGIN { n = split(want, w, "|"); for (i = 1; i <= n; i++) ours[w[i]] = 1; ours["/.outsourcerer/"] = 1 }
      { l = $0; sub(/\r$/, "", l) }
      l in ours { if (!done) { for (i = 1; i <= n; i++) print w[i]; done = 1 } next }
      { print }
      END { if (!done) { if (NR) print ""; print "# outsourcerer worker worktrees (local, added automatically)"
                         for (i = 1; i <= n; i++) print w[i] } }' "$ex" >"$tmp" \
      && cat "$tmp" >"$ex"; } 2>/dev/null
  else
    { { echo '# outsourcerer worker worktrees (local, added automatically)'; tr '|' '\n' <<<"$_OSRC_EXCLUDE_LINES"; } >"$ex"; } 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null
  return 0
}

#!/usr/bin/env python3
"""Run the lines of one command through the segment classifier, tracking what earlier steps change.

Two things the shell does between segments would defeat a path check made up front:
- `cd X` can fail, and bash then carries on in the old directory. Every later segment is judged
  in each directory it might run in; only a segment joined to the `cd` by `&&` is known to run
  in the new one.
- A step that replaces files or directories (git switch, mv, rm, ln, cp ...) can turn a path that
  was inside the worktree into a link that leaves it. A later write or cd then holds.
"""
from __future__ import annotations

# Writes that cannot swap a directory for a link: they create or edit one file in place.
_HARMLESS_WRITES = ("write-in-worktree:touch", "write-in-worktree:mkdir", "write-in-worktree:tee",
                    "write-in-worktree:sed -i", "write-in-worktree:git add", "write-in-worktree:git commit",
                    "write-in-worktree:git checkout -b")
_PIPES = ("|", "|&")


def run_lines(lines, cwd, roots, pre_checks, split_segments, classify_segment, Hold):
    """Return the rule of every segment, or raise Hold. `lines` are logical command lines."""
    rules, may, tree_changed = [], {cwd}, False
    for line in lines:
        pre_checks(line)
        segs = split_segments(line)
        must = None                                   # directories known after a chain of `cd X &&`
        for i, (seg, prev) in enumerate(segs):
            nxt = segs[i + 1][1] if i + 1 < len(segs) else None
            use = must if (prev == "&&" and must is not None) else may
            outcomes, new_dirs = [], set()
            for d in sorted(use):
                rule, after = classify_segment(seg, prev, d, roots)
                outcomes.append(rule)
                if rule == "cd":
                    new_dirs.add(after)
            rule = outcomes[0]
            if len(set(outcomes)) != 1:
                rule = " + ".join(dict.fromkeys(outcomes))
            if rule.endswith("cd") and rule != "cd":
                raise Hold("cd run through another command")
            is_cd = "cd" in outcomes
            if is_cd and (prev in _PIPES or nxt in _PIPES):
                raise Hold("cd inside a pipeline runs in a subshell")
            writes = rule.startswith("write-in-worktree") or is_cd or _redirects_out(seg)
            if tree_changed and writes:
                raise Hold("an earlier step can change how this path resolves (link, switch or move)")
            if rule.startswith("write-in-worktree") and not rule.startswith(_HARMLESS_WRITES):
                tree_changed = True
            if is_cd:
                may = may | new_dirs
                must = new_dirs
            elif prev != "&&":
                must = None
            rules.append(rule)
    return rules


def _redirects_out(seg) -> bool:
    return any(t.startswith((">", "&>")) or (t[:1].isdigit() and ">" in t) for t in seg)

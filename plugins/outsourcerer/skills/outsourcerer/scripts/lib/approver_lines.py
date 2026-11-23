#!/usr/bin/env python3
"""Physical command lines for the safe approver.

The shell only continues a command across a newline for a few constructs: an open quote, a
backslash continuation, a here-document, or an unfinished operator/redirect. This module proves
that every newline in the visible command is a real command boundary before the classifier judges
each physical line on its own. Anything else is ambiguous and must hold.
"""
from __future__ import annotations


class LineHold(Exception):
    pass


def command_lines(cmd: str) -> list[str]:
    """Return the stripped, non-empty command lines of *cmd*.

    Comment-only lines are ignored (the shell never runs them). Raises LineHold when a newline
    sits inside quotes or after a trailing backslash, because the shell would join those lines.
    """
    raw_lines = cmd.split("\n")
    last = len(raw_lines) - 1
    quote = None
    lines = []
    for idx, raw in enumerate(raw_lines):
        text = raw.strip()
        is_last = idx == last
        if text.startswith("#"):
            continue
        i, n = 0, len(raw)
        while i < n:
            c = raw[i]
            if quote == "'":
                if c == "'":
                    quote = None
                i += 1
                continue
            if quote == '"':
                if c == '"':
                    quote = None
                    i += 1
                    continue
                if c == "\\":
                    i += 2 if i + 1 < n else 1
                    continue
                i += 1
                continue
            if c == "\\":
                if i + 1 >= n:
                    if not is_last:
                        raise LineHold("line %d ends in a line continuation" % (idx + 1))
                    i += 1
                    continue
                i += 2
                continue
            if c == "'":
                quote = "'"
            elif c == '"':
                quote = '"'
            i += 1
        if quote is not None and not is_last:
            raise LineHold("line %d opens a quote that continues past the newline" % (idx + 1))
        if text:
            lines.append(text)
    return lines


# The shell treats a newline after &&, ||, | or |& as whitespace inside the same command, so those
# physical lines are joined before judging. A space is required before the operator so an escaped or
# glued operator (`cmd\&&`, `cmd&&`) still falls through to the conservative per-line holds.
_CONTINUATIONS = (" &&", " ||", " |&", " |")


def logical_lines(cmd: str) -> list[str]:
    """command_lines() plus the &&/||/|/|& continuations the shell itself would join."""
    lines = command_lines(cmd)
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        while i + 1 < len(lines) and line.endswith(_CONTINUATIONS):
            line = line + " " + lines[i + 1]
            i += 1
        out.append(line)
        i += 1
    return out

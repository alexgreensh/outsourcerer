#!/usr/bin/env python3
"""Physical command lines for the safe approver.

The shell only continues a command across a newline for a few constructs: an open quote, a
backslash continuation, a here-document, or an unfinished operator/redirect. This module proves
that every newline in the visible command is a real command boundary before the classifier judges
each physical line on its own. Anything else is ambiguous and must hold.
"""
from __future__ import annotations

import itertools
import unicodedata


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
        text = raw.strip(" \t")   # shell blanks only: str.strip() also drops U+2003 and friends
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


# The shell treats a newline after &&, || or | as whitespace inside the same command, so those
# physical lines are joined before judging. A space is required before the operator so an escaped or
# glued operator (`cmd\&&`, `cmd&&`) still falls through to the conservative per-line holds.
_CONTINUATIONS = (" &&", " ||", " |")


def logical_lines(cmd: str) -> list[str]:
    """command_lines() plus the &&/||/| continuations the shell itself would join."""
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


def check_characters(cmd: str) -> None:
    """Hold any whitespace, control or invisible character the shell does not treat as a blank.

    Python and bash disagree on what is whitespace (U+2003 is a word character to bash), so a row
    that looks blank or like a comment on screen could run a command. Only space, tab and newline
    pass; a carriage return is held by the caller.
    """
    for ch in cmd:
        if ch in " \t\n":
            continue
        if ch.isspace() or unicodedata.category(ch) in ("Cc", "Cf", "Zs", "Zl", "Zp", "Co", "Cs", "Cn"):
            raise LineHold("whitespace, control or invisible character U+%04X" % ord(ch))


# How the screen reader saw each break between two command rows: "n" = a shell newline for sure
# (the row is shorter than the pane would let it be), "s" = a newline or a display wrap at a word
# boundary, "h" = also a hard wrap through a word. Unknown means "h": the reader could not tell.
_BREAK_JOINS = {"n": ("\n",), "s": ("\n", " "), "h": ("\n", " ", "")}
MAX_INTERPRETATIONS = 81


def interpretations(cmd: str, breaks: str = "") -> list:
    """Every command text the displayed rows could stand for; approving needs all of them safe."""
    rows = cmd.split("\n")
    if len(rows) == 1:
        return [cmd]
    codes = list(breaks)
    if len(codes) != len(rows) - 1 or any(c not in _BREAK_JOINS for c in codes):
        codes = ["h"] * (len(rows) - 1)
    options = [_BREAK_JOINS[c] for c in codes]
    total = 1
    for o in options:
        total *= len(o)
    if total > MAX_INTERPRETATIONS:
        raise LineHold("too many line breaks that could be a terminal wrap or a shell newline")
    out = []
    for combo in itertools.product(*options):
        text = rows[0]
        for sep, row in zip(combo, rows[1:]):
            text += sep + row
        out.append(text)
    return list(dict.fromkeys(out))

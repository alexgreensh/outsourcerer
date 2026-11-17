#!/usr/bin/env python3
"""slop: built-in Outsourcerer guard over the ADDED lines of a lane's diff. Regex only, no model.

Four classes, each with its own FIX:
  narration   a comment that describes the edit instead of the code ("added", "now we", ...)
  excuse      a comment that admits a shortcut ("hack", "temporary", "not sure why", ...)
  inflation   a hunk whose added comment lines outnumber its added code lines (min 4 comments)
  markdown    a new *.md file outside the allowlist (CHANGELOG.md, README.md, docs/, repo-meta files by default)

Inputs (set by lib/guards.sh, all read from the BASE ref, never from the lane):
  OSRC_GUARD_DIFF    unified diff of base...HEAD plus uncommitted and untracked files
  OSRC_GUARD_CFGDIR  dir holding the base copies of guards.conf and slop.allow (may be empty)
guards.conf keys: slop.md_allow = <glob> ... (replaces the default list), slop.comment_min = N.
slop.allow lines: `<path-glob> [class]  # reason` (no class = every class); a line with no reason
is ignored.
Exit 0 = clean; exit 1 = findings, printed as WHAT:/FIX: lines.
"""
import fnmatch
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HASH = {".sh", ".bash", ".zsh", ".py", ".pyi", ".yml", ".yaml", ".toml", ".rb", ".pl", ".r",
        ".conf", ".cfg", ".ini", ".ps1", ".tf", ".mk"}
HASH_NAMES = {"makefile", "dockerfile", "gemfile", "rakefile", ".gitignore"}
SLASH = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".css", ".scss", ".less", ".go", ".rs",
         ".java", ".kt", ".swift", ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".php", ".dart"}
HTML = {".html", ".htm", ".xml", ".svg", ".vue", ".svelte"}
SKIP = ("node_modules/", "vendor/", "third_party/", "dist/", "build/", ".venv/", "venv/",
        "__pycache__/", "fixtures/", "testdata/", "generated/", ".git/")
SKIP_GLOBS = ("*.min.js", "*.min.css", "*.bundle.js", "*.map", "*_pb2.py", "*.generated.*",
              "*.lock", "package-lock.json", "*.snap")
MD_DEFAULT = ["CHANGELOG.md", "README.md", "docs/", "LICENSE*.md", "SECURITY.md", "CONTRIBUTING.md",
              "CODE_OF_CONDUCT.md", "SKILL.md", "AGENTS.md", "CLAUDE.md"]

NARRATION = re.compile(
    r"^(?:i |we )?(?:just )?(?:added|fixed|changed|updated|removed)(?: (?:the|a|an|this|that|these|it|its|"
    r"support|handling|missing|logic|bug|issue|check|guard|test|tests|code|function)\b| ?#\d| ?:)"
    r"|\bnow we\b|\bwe now\b|\bfixed the bug\b|\bfixes the bug\b"
    r"|\b(?:changed|updated) (?:it |this |that )?to\b|\bas requested\b|^new:"
    r"|\bper (?:the )?review(?:er)?\b|\bper your request\b", re.I)
EXCUSE = re.compile(
    r"\bhack(?:y|ish)?\b|\bworkaround for now\b|\bfor now\b.*\b(?:later|properly)\b"
    r"|\btemporar(?:y|ily) (?:fix|hack|workaround|solution|patch|measure|disabled?|skip(?:ped)?)\b"
    r"|\btemporarily\b(?= *$)|\btodo:? *(?:proper|real|fix (?:this )?(?:properly|later)|clean ?up)"
    r"|\bproper fix\b|\bfor some reason\b|\bnot sure why\b|\bdon'?t know why\b|\bquick fix\b"
    r"|\bskip(?:ped|ping)? (?:the )?(?:check|test|tests|validation) for now\b", re.I)
FIX = {
    "narration": "delete the comment; the commit message carries the why",
    "excuse": "do the proper fix now, or open a task and delete the comment",
    "inflation": "keep the one comment a reader needs; the commit message carries the rest",
    "markdown": "delete the file unless the brief asked for it; put notes in the commit or report",
}


def kind_of(path):
    base = os.path.basename(path).lower()
    ext = os.path.splitext(base)[1]
    if ext in HASH or base in HASH_NAMES:
        return "hash"
    if ext in SLASH:
        return "slash"
    if ext in HTML:
        return "html"
    return None


def _match(path, g):
    return fnmatch.fnmatch(path, g) or fnmatch.fnmatch(os.path.basename(path), g)


def skipped(path, allow):
    p = "/" + path
    if any(("/" + s) in p for s in SKIP):
        return True
    name = os.path.basename(path)
    if any(fnmatch.fnmatch(name, g) for g in SKIP_GLOBS):
        return True
    return any(cls is None and _match(path, g) for g, cls in allow)


def _code_part(line, marker):
    """Index where an unquoted trailing comment starts, or -1."""
    single = double = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and not single:
            i += 2
            continue
        if c == "'" and not double:
            single = not single
        elif c == '"' and not single:
            double = not double
        elif not single and not double and line.startswith(marker, i) and i > 0 and line[i - 1] in " \t":
            if marker == "//" and line[i - 1] == ":":
                pass
            else:
                return i
        i += 1
    return -1


def comment(line, kind, state):
    """-> (comment_text or None, whole_line_is_comment). state carries an open /* or <!-- block."""
    s = line.strip()
    if kind == "hash":
        if s.startswith("#!") or s.startswith("#{") or s.startswith("#region"):
            return None, False
        if s.startswith("#"):
            return s.lstrip("#").strip(), True
        i = _code_part(line, " #")
        return (line[i + 2:].strip(), False) if i >= 0 else (None, False)
    if kind == "slash":
        if state.get("block"):
            if "*/" in s:
                state["block"] = False
            return s.split("*/")[0].lstrip("*").strip(), True
        if s.startswith("//"):
            return s.lstrip("/").strip(), True
        if s.startswith("/*"):
            if "*/" not in s:
                state["block"] = True
            return s[2:].split("*/")[0].lstrip("*").strip(), True
        i = _code_part(line, "//")
        if i < 0:
            i = _code_part(line, "/*")
            if i >= 0 and "*/" not in line[i:]:
                state["block"] = True
            return (line[i + 2:].split("*/")[0].strip(), False) if i >= 0 else (None, False)
        return line[i + 2:].strip(), False
    if kind == "html":
        if state.get("block"):
            if "-->" in s:
                state["block"] = False
            return s.split("-->")[0].strip(), True
        if s.startswith("<!--"):
            if "-->" not in s:
                state["block"] = True
            return s[4:].split("-->")[0].strip(), s.endswith("-->") or state.get("block", False)
        return None, False
    return None, False


def read_conf(cfgdir):
    conf, allow = {}, []
    if not cfgdir:
        return conf, allow
    try:
        with open(os.path.join(cfgdir, "guards.conf"), encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.split("#", 1)[0].strip()
                m = re.match(r"([\w.-]+)\s*[=: ]\s*(.*)$", line)
                if m:
                    conf[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    try:
        with open(os.path.join(cfgdir, "slop.allow"), encoding="utf-8", errors="replace") as f:
            for raw in f:
                if "#" not in raw:
                    continue
                spec, reason = raw.split("#", 1)
                words = spec.split()
                if words and reason.strip():
                    allow.append((words[0], words[1] if len(words) > 1 else None))
    except OSError:
        pass
    return conf, allow


def md_allowed(path, globs):
    name = os.path.basename(path)
    for g in globs:
        if g.endswith("/"):
            if path.startswith(g) or ("/" + g) in ("/" + path):
                return True
        elif fnmatch.fnmatch(path, g) or fnmatch.fnmatch(name, g):
            return True
    return False


def scan(diff_text, conf, allow):
    md_globs = conf.get("slop.md_allow", "").split() or MD_DEFAULT
    try:
        cmin = max(1, int(conf.get("slop.comment_min", "4")))
    except ValueError:
        cmin = 4
    hits = []
    path, kind, new_file, state = None, None, False, {}
    hunk = None

    def close_hunk():
        if hunk and hunk["comments"] >= cmin and hunk["comments"] > hunk["code"]:
            hits.append(("inflation", path, "%s:%d: %d comment lines vs %d code lines in one hunk"
                         % (path, hunk["start"], hunk["comments"], hunk["code"])))

    for raw in diff_text.splitlines():
        if raw.startswith("diff --git "):
            close_hunk()
            hunk, path, new_file, state = None, None, False, {}
            continue
        if raw.startswith("new file mode"):
            new_file = True
            continue
        if raw.startswith("+++ "):
            p = raw[4:].strip()
            path = None if p == "/dev/null" else (p[2:] if p.startswith("b/") else p)
            kind = kind_of(path) if path else None
            if path and (skipped(path, allow)):
                path = None
            elif path and new_file and path.lower().endswith(".md") and not md_allowed(path, md_globs):
                hits.append(("markdown", path, "%s: new markdown file" % path))
            continue
        if raw.startswith("@@"):
            close_hunk()
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            hunk = {"start": int(m.group(1)) if m else 0, "line": int(m.group(1)) if m else 0,
                    "comments": 0, "code": 0}
            state = {}
            continue
        if hunk is None or path is None or kind is None:
            continue
        if raw.startswith("+"):
            line = raw[1:]
            lineno = hunk["line"]
            hunk["line"] += 1
            if not line.strip():
                continue
            text, whole = comment(line, kind, state)
            if whole:
                hunk["comments"] += 1
            else:
                hunk["code"] += 1
            if text:
                for cls, rx in (("narration", NARRATION), ("excuse", EXCUSE)):
                    if rx.search(text):
                        hits.append((cls, path, "%s:%d: %s" % (path, lineno, line.strip()[:160])))
                        break
        elif raw.startswith(" "):
            hunk["line"] += 1
    close_hunk()
    return [h for h in hits if not any(cls == h[0] and _match(h[1], g) for g, cls in allow)]


def main():
    diff_path = os.environ.get("OSRC_GUARD_DIFF", "")
    if not diff_path or not os.path.isfile(diff_path):
        print("WHAT: slop guard got no diff (OSRC_GUARD_DIFF unset)")
        print("FIX: run it through `outsourcerer guards run`")
        return 2
    with open(diff_path, encoding="utf-8", errors="replace") as f:
        diff_text = f.read()
    conf, allow = read_conf(os.environ.get("OSRC_GUARD_CFGDIR", ""))
    hits = scan(diff_text, conf, allow)
    if not hits:
        return 0
    seen = []
    for cls, _path, where in hits:
        print("WHAT: %s %s" % (cls, where))
        if cls not in seen:
            seen.append(cls)
    for c in seen:
        print("FIX: %s: %s" % (c, FIX[c]))
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Approver policy "safe": decide approve|hold for one pending delegate action.

Deny by default. There is exactly ONE gate, is_safe(): it returns approve only when NO danger rule
matched AND EVERY segment of the command is in the safe set. Anything not understood holds.

Usage:
  approver_classify.py --root DIR [--extra DIR]... [--kind shell|write|read] [--path P]   (command on stdin)
  -> prints "approve <rule>" or "hold <rule>" (one line), exit 0. Exit 2 = usage error (caller holds).

Matching is on the PARSED command (shlex tokens, quote-aware), never on substrings of the raw text:
a filename containing "approve" or "install" is just an argument, and `grep -E 'a|b'` is one
segment because the pipe is quoted. Stdlib only.
"""
from __future__ import annotations

import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")

# ---- protected locations and secrets -------------------------------------------------------------
PROTECTED_DIRS = [os.path.join(HOME, d) for d in (".outsourcerer", ".claude", ".ssh", ".gnupg", ".aws",
                                                  ".config/gh", ".kube", ".docker", "Library/Keychains")]
if os.environ.get("OSRC_HOME"):
    PROTECTED_DIRS.append(os.environ["OSRC_HOME"])
SECRET_NAME = re.compile(
    r"(^|/)(\.env(\..*)?|\.netrc|\.npmrc|\.pypirc|id_[a-z0-9]+|.*\.pem|.*\.key|.*\.p12|.*\.keychain(-db)?|"
    r"credentials(\.json)?|.*token.*|.*secret.*|.*password.*|auth\.json|\.git-credentials)$", re.I)
SECRET_VAR = re.compile(r"(KEY|TOKEN|SECRET|PASS|CRED|AUTH)", re.I)

# ---- command sets ---------------------------------------------------------------------------------
READ_ONLY = {
    "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ag", "file", "stat", "du", "df",
    "pwd", "echo", "printf", "which", "type", "tree", "diff", "cmp", "uniq", "cut", "tr", "nl", "jq",
    "basename", "dirname", "realpath", "readlink", "date", "uname", "whoami", "id", "true", "false",
    "test", "[", "sleep", "md5", "md5sum", "shasum", "sha1sum", "sha256sum", "column", "comm", "fold",
    "expand", "rev", "seq", "yes", "hexdump", "xxd", "od", "strings", "less", "more", "bat", "fd",
    "wc", "locale", "hostname", "sw_vers", "lsof", "ps", "pgrep", "shellcheck",
}
WRAPPERS = {"time", "nice", "command", "builtin", "nohup", "stdbuf"}
PKG_MANAGERS = {"npm", "pnpm", "yarn", "bun", "pip", "pip3", "uv", "brew", "apt", "apt-get", "gem",
                "cargo", "go", "poetry", "pipx", "conda", "port", "dnf", "yum", "apk", "composer"}
INTERPRETERS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "perl",
                "ruby", "php", "osascript", "deno", "bun", "pwsh"}
TEST_RUNNERS = {"pytest", "jest", "vitest", "mocha", "tsc", "eslint", "ruff", "mypy", "pyright",
                "rspec", "phpunit", "flake8", "pylint", "black", "prettier", "golangci-lint",
                "swiftlint", "ctest", "tox", "nox", "bats"}
SCRIPT_VERBS = {"test", "tests", "lint", "build", "check", "typecheck", "type-check", "format:check",
                "test:unit", "test:e2e", "verify"}
GIT_READ = {"status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe",
            "shortlog", "cat-file", "ls-tree", "merge-base", "rev-list", "name-rev", "grep",
            "show-ref", "for-each-ref", "whatchanged", "count-objects", "var", "help", "version"}
GIT_LOCAL_WRITE = {"add", "commit", "mv", "rm", "switch", "restore", "stash", "init"}
GH_READ = {("pr", "view"), ("pr", "list"), ("pr", "diff"), ("pr", "checks"), ("pr", "status"),
           ("issue", "view"), ("issue", "list"), ("issue", "status"), ("run", "view"),
           ("run", "list"), ("repo", "view"), ("release", "view"), ("release", "list"),
           ("workflow", "list"), ("workflow", "view"), ("search", "code"), ("search", "issues"),
           ("search", "prs"), ("auth", "status"), ("label", "list"), ("cache", "list")}

OPERATORS = {"&&", "||", ";", "|", "&", "|&", ";;", "(", ")"}
REDIRECT = re.compile(r"^(\d*)(>>?|&>|>\||<|<<<?|<>)(.*)$")


class Hold(Exception):
    pass


def resolve(path: str, cwd: str) -> str:
    path = path.replace("${HOME}", HOME)
    if path == "~" or path.startswith("~/"):
        path = HOME + path[1:]
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def inside(path: str, roots: list[str]) -> bool:
    for r in roots:
        if path == r or path.startswith(r.rstrip("/") + "/"):
            return True
    return False


def check_path(tok: str, cwd: str, roots: list[str], write: bool) -> None:
    if "$" in tok.replace("${HOME}", "").replace("$HOME", ""):
        raise Hold("variable expansion in an argument")
    tok = tok.replace("$HOME", HOME)
    if any(c in tok for c in "*?[") and write:
        raise Hold("glob in a write target")
    p = resolve(tok, cwd)
    if SECRET_NAME.search(p) or SECRET_NAME.search(tok):
        raise Hold("secret-looking path: " + tok)
    if inside(p, [os.path.realpath(d) for d in PROTECTED_DIRS]):
        raise Hold("protected location: " + tok)
    if write:
        if not inside(p, roots):
            raise Hold("write outside the worktree: " + tok)
        if p in roots:
            raise Hold("write targets the worktree root itself: " + tok)
    else:
        root = roots[0]
        if not inside(p, roots):
            q = p
            while q and q != "/":
                if os.path.exists(os.path.join(q, ".git")):
                    if not inside(root, [q]):
                        raise Hold("reads another worktree: " + tok)
                    break
                q = os.path.dirname(q)


def path_args(args: list[str]) -> list[str]:
    return [a for a in args if a and not a.startswith("-")]


def split_segments(cmd: str) -> list[list[str]]:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        toks = list(lex)
    except ValueError as e:
        raise Hold("unparseable: %s" % e)
    segs, cur = [], []
    for t in toks:
        if t in OPERATORS:
            if t in ("(", ")"):
                raise Hold("subshell")
            if t == "&":
                raise Hold("background job")
            segs.append((cur, t)); cur = []
        else:
            cur.append(t)
    segs.append((cur, None))
    out, prev_op = [], None
    for seg, op in segs:
        if not seg:
            prev_op = op
            continue
        out.append((seg, prev_op))
        prev_op = op
    return out


def merge_redirects(tokens: list[str]) -> tuple[list[str], list[tuple[str, str]]]:
    """shlex splits '>' and '2>&1' oddly; regroup into (op, target) pairs."""
    args, redirs, i = [], [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in (">", ">>", "<", ">&", "<<", "<<<", ">|", "&>"):
            tgt = tokens[i + 1] if i + 1 < len(tokens) else ""
            redirs.append((t, tgt)); i += 2; continue
        m = re.match(r"^(\d+)$", t)
        if m and i + 1 < len(tokens) and tokens[i + 1] in (">", ">>", ">&", "<"):
            tgt = tokens[i + 2] if i + 2 < len(tokens) else ""
            redirs.append((tokens[i + 1], tgt)); i += 3; continue
        args.append(t); i += 1
    return args, redirs


def classify_segment(tokens, prev_op, cwd, roots) -> tuple[str, str]:
    """Returns (rule, new_cwd). Raises Hold."""
    args, redirs = merge_redirects(tokens)
    for op, tgt in redirs:
        if op in ("<<", "<<<"):
            raise Hold("heredoc / here-string")
        if op == ">&" or tgt in ("/dev/null", "&1", "&2", "1", "2"):
            continue
        if op == "<":
            check_path(tgt, cwd, roots, write=False); continue
        check_path(tgt, cwd, roots, write=True)
    while args and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0]):
        if SECRET_VAR.search(args[0].split("=", 1)[0]):
            raise Hold("sets a secret-looking variable")
        args = args[1:]
    while args and args[0] in WRAPPERS:
        args = args[1:]
    if args and args[0] == "timeout":
        args = args[2:] if len(args) > 2 else []
    if args and args[0] == "env":
        if len(args) == 1:
            raise Hold("env dump (secrets)")
        args = args[1:]
        while args and "=" in args[0]:
            args = args[1:]
    if not args:
        return "redirect-only", cwd
    for a in args:
        if "`" in a or "$(" in a or "<(" in a or ">(" in a:
            raise Hold("command substitution")
    name = os.path.basename(args[0])
    rest = args[1:]

    if prev_op in ("|", "|&") and name in INTERPRETERS | {"xargs", "sudo", "tee", "source", "."}:
        if name in INTERPRETERS or name in ("sudo", "source", "."):
            raise Hold("pipe into a shell/interpreter")
    if name in ("sudo", "doas", "su"):
        raise Hold("privilege escalation")
    if name in ("eval", "exec", "source", ".", "trap"):
        raise Hold("eval/exec/source")
    if name in ("curl", "wget", "nc", "ssh", "scp", "rsync", "ftp", "sftp", "telnet"):
        raise Hold("network tool")
    if name in ("security", "keychain", "printenv", "set", "declare", "export"):
        raise Hold("secrets / environment access")
    if name in ("kill", "killall", "pkill", "shutdown", "reboot", "launchctl", "systemctl", "crontab",
                "chown", "dd", "mkfs", "diskutil", "tmux", "screen", "osascript", "open"):
        raise Hold("system / process control: " + name)
    if len(rest) == 1 and rest[0] in ("--help", "-h", "--version", "-V") and "/" not in args[0]:
        return "help/version", cwd

    if name == "cd":
        tgt = rest[0] if rest else HOME
        check_path(tgt, cwd, roots, write=False)
        return "cd", resolve(tgt, cwd)
    if name in READ_ONLY:
        for a in path_args(rest):
            if name in ("grep", "egrep", "fgrep", "rg", "ag", "jq", "tr", "echo", "printf", "seq",
                        "date", "sleep", "test", "[", "cut", "column", "yes") :
                continue
            check_path(a, cwd, roots, write=False)
        if name in ("grep", "rg", "egrep", "fgrep", "ag"):
            for a in path_args(rest)[1:]:
                check_path(a, cwd, roots, write=False)
        return "read-only:" + name, cwd
    if name == "find":
        bad = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"}
        if any(a in bad for a in rest):
            raise Hold("find with an action (-exec/-delete)")
        for a in rest:
            if a.startswith("-") or a in ("!", "(", ")"):
                break
            check_path(a, cwd, roots, write=False)
        return "read-only:find", cwd
    if name == "sort":
        if any(a == "-o" or a.startswith("--output") for a in rest):
            raise Hold("sort -o writes a file")
        for a in path_args(rest):
            check_path(a, cwd, roots, write=False)
        return "read-only:sort", cwd
    if name in ("sed", "gsed"):
        if any(a == "-i" or a.startswith("-i") or a == "--in-place" for a in rest):
            files = [a for a in path_args(rest)][1:]
            if not files:
                raise Hold("sed -i without a file")
            for f in files:
                check_path(f, cwd, roots, write=True)
            return "write-in-worktree:sed -i", cwd
        script = path_args(rest)[0] if path_args(rest) else ""
        if re.search(r"(^|[;}\s])[wWe]\s|/[wW]\s", script):
            raise Hold("sed script writes or executes")
        for a in path_args(rest)[1:]:
            check_path(a, cwd, roots, write=False)
        return "read-only:sed", cwd
    if name in ("awk", "gawk", "mawk"):
        prog = " ".join(rest)
        if "system" in prog or ">" in prog or "|" in prog or "getline" in prog:
            raise Hold("awk program writes or executes")
        return "read-only:awk", cwd
    if name == "xargs":
        sub = [a for a in rest if not a.startswith("-")]
        if not sub:
            raise Hold("xargs without a command")
        r, _ = classify_segment(sub, None, cwd, roots)
        if not r.startswith("read-only"):
            raise Hold("xargs runs a non-read-only command")
        return "read-only:xargs " + sub[0], cwd

    if name in ("mkdir", "touch", "cp", "mv", "ln", "rmdir", "rm", "unlink", "tee", "chmod", "truncate", "install"):
        if name == "install":
            raise Hold("install(1)")
        if name == "chmod" and any("s" in a for a in rest if a.startswith(("+", "u+", "g+"))):
            raise Hold("setuid/setgid chmod")
        targets = path_args(rest)
        if name == "chmod":
            targets = targets[1:]
        if not targets:
            raise Hold(name + " without a target")
        if name == "cp" or name == "ln":
            for s in targets[:-1]:
                check_path(s, cwd, roots, write=False)
            targets = targets[-1:]
        for t in targets:
            check_path(t, cwd, roots, write=True)
        return "write-in-worktree:" + name, cwd

    if name == "git":
        i = 0
        while i < len(rest) and rest[i].startswith("-"):
            if rest[i] in ("-C", "-c"):
                raise Hold("git -C/-c")
            i += 1
        if i >= len(rest):
            raise Hold("bare git")
        sub, sargs = rest[i], rest[i + 1:]
        if any(a in ("-f", "--force", "--force-with-lease", "-D", "--hard", "--mirror", "--delete")
               or a.startswith("--force") for a in sargs):
            raise Hold("git force/hard/delete flag")
        if sub == "push":
            raise Hold("git push")
        if sub in GIT_READ:
            return "read-only:git " + sub, cwd
        if sub in ("branch", "tag", "remote", "worktree", "config", "stash", "reflog"):
            if sub == "config" and sargs[:1] and sargs[0] in ("--get", "--list", "-l", "--get-all", "--get-regexp"):
                return "read-only:git config", cwd
            if sub == "stash" and (not sargs or sargs[0] in ("list", "show")):
                return "read-only:git stash list", cwd
            if sub == "worktree" and sargs[:1] == ["list"]:
                return "read-only:git worktree list", cwd
            if sub in ("branch", "tag", "remote", "reflog") and all(a in ("-a", "-r", "-v", "-vv", "--list", "-l", "--show-current", "--all", "show") for a in sargs):
                return "read-only:git " + sub, cwd
            if sub == "stash" and sargs[0] in ("push", "save") and len(sargs) <= 3:
                return "write-in-worktree:git stash", cwd
            raise Hold("git %s with arguments" % sub)
        if sub in ("checkout",):
            if sargs[:1] == ["-b"] and len(sargs) == 2:
                return "write-in-worktree:git checkout -b", cwd
            raise Hold("git checkout can discard work")
        if sub == "restore":
            raise Hold("git restore discards work")
        if sub in GIT_LOCAL_WRITE:
            if sub == "commit" and "--amend" in sargs:
                raise Hold("git commit --amend")
            for a in path_args(sargs) if sub in ("add", "mv", "rm") else []:
                check_path(a, cwd, roots, write=True) if sub != "add" else check_path(a, cwd, roots, write=False)
            return "write-in-worktree:git " + sub, cwd
        raise Hold("git " + sub)

    if name == "gh":
        pair = tuple(rest[:2])
        if pair in GH_READ:
            return "read-only:gh " + " ".join(pair), cwd
        if rest[:1] == ["api"]:
            a = rest[1:]
            if any(x in ("-X", "--method", "-f", "-F", "--field", "--raw-field", "--input") for x in a):
                raise Hold("gh api with a method or fields")
            return "read-only:gh api GET", cwd
        raise Hold("gh " + " ".join(rest[:2]) + " (publishing / mutating)")

    # package managers: tests/builds approve, installs/publish hold
    if name in ("npm", "pnpm", "yarn", "bun"):
        if not rest:
            raise Hold(name + " bare")
        verb = rest[0]
        if verb in ("test", "t") or verb in SCRIPT_VERBS:
            return "test/build:" + name + " " + verb, cwd
        if verb == "run" and len(rest) >= 2 and (rest[1] in SCRIPT_VERBS or rest[1].startswith(("test", "lint", "build", "typecheck"))):
            return "test/build:" + name + " run " + rest[1], cwd
        if verb in ("ls", "list", "outdated", "view", "why", "audit") and name != "bun":
            return "read-only:" + name + " " + verb, cwd
        if verb in ("publish", "unpublish", "deprecate", "dist-tag", "owner", "login", "adduser", "token"):
            raise Hold("network publishing: %s %s" % (name, verb))
        raise Hold("package install / script: %s %s" % (name, verb))
    if name == "npx" or name == "pnpx":
        if rest and os.path.basename(rest[0]) in TEST_RUNNERS:
            return "test/build:npx " + rest[0], cwd
        raise Hold("npx runs a downloaded package")
    if name in ("cargo", "go"):
        if rest and rest[0] in ("test", "build", "check", "clippy", "vet", "fmt") and not (rest[0] == "fmt" and "--check" not in rest and name == "cargo"):
            return "test/build:%s %s" % (name, rest[0]), cwd
        raise Hold("%s %s" % (name, rest[0] if rest else ""))
    if name in ("make", "gmake"):
        tgts = [a for a in rest if not a.startswith("-")]
        if tgts and all(t in SCRIPT_VERBS or t.startswith(("test", "lint", "check")) for t in tgts):
            return "test/build:make " + " ".join(tgts), cwd
        raise Hold("make target not a test/build/lint")
    if name in TEST_RUNNERS:
        if name in ("prettier", "black") and not any(a in ("--check", "-c", "--diff") for a in rest):
            raise Hold(name + " rewrites files")
        if name == "ruff" and rest[:1] == ["format"] and "--check" not in rest:
            raise Hold("ruff format rewrites files")
        if name == "eslint" and "--fix" in rest:
            raise Hold("eslint --fix rewrites files")
        return "test/build:" + name, cwd
    if name in ("python", "python3") and len(rest) >= 2 and rest[0] == "-m":
        if rest[1] in ("pytest", "unittest", "mypy", "ruff", "flake8", "pylint", "py_compile", "compileall", "tox", "nox"):
            return "test/build:python -m " + rest[1], cwd
        if rest[1] == "json.tool":
            return "read-only:python -m json.tool", cwd
        raise Hold("python -m " + rest[1])
    if name in ("bash", "sh", "zsh") and rest:
        if rest[0] == "-n":
            return "test/build:%s -n" % name, cwd
        script = rest[0]
        if script.startswith("-"):
            raise Hold("%s %s" % (name, script))
        p = resolve(script, cwd)
        base = os.path.basename(p)
        rel = "/" + os.path.relpath(p, roots[0]) if inside(p, roots) else ""
        if rel and (re.match(r"^(test|tests|check|lint|conformance)[_.-]", base) or "/tests/" in rel or "/test/" in rel):
            return "test/build:%s %s" % (name, base), cwd
        raise Hold("runs a script that is not a test inside the worktree")
    if name in ("node",) and rest[:1] == ["--check"]:
        return "test/build:node --check", cwd
    if name in PKG_MANAGERS:
        raise Hold("package manager: " + name)
    if name in INTERPRETERS:
        raise Hold("interpreter: " + name)
    raise Hold("unknown command: " + name)


def is_safe(cmd: str, kind: str, path: str, cwd: str, roots: list[str]) -> tuple[bool, str]:
    """THE gate. (True, rule) only if no danger rule fires AND every segment is in the safe set."""
    try:
        if kind == "trust":
            raise Hold("folder trust prompt (never auto-approved)")
        if kind in ("write", "edit"):
            if not path:
                raise Hold("file write with no visible path")
            check_path(path, cwd, roots, write=True)
            return True, "write-in-worktree:file " + path
        if kind == "read":
            if not path:
                raise Hold("file read with no visible path")
            check_path(path, cwd, roots, write=False)
            return True, "read-only:file " + path
        if kind != "shell":
            raise Hold("unrecognised prompt kind: " + (kind or "none"))
        cmd = cmd.strip()
        if not cmd:
            raise Hold("no command visible")
        if "\n" in cmd:
            raise Hold("multi-line command (continuation lines, heredoc or wrapped text)")
        if "`" in cmd or "$(" in cmd or "<(" in cmd or ">(" in cmd:
            raise Hold("command substitution")
        rules, cur = [], cwd
        for seg, prev in split_segments(cmd):
            rule, cur = classify_segment(seg, prev, cur, roots)
            rules.append(rule)
        if not rules:
            raise Hold("empty command")
        return True, " + ".join(dict.fromkeys(rules))
    except Hold as h:
        return False, str(h)


def main(argv: list[str]) -> int:
    root, extras, kind, path = None, [], "shell", ""
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--root" and i + 1 < len(argv):
            root = argv[i + 1]; i += 2
        elif a == "--extra" and i + 1 < len(argv):
            extras.append(argv[i + 1]); i += 2
        elif a == "--kind" and i + 1 < len(argv):
            kind = argv[i + 1]; i += 2
        elif a == "--path" and i + 1 < len(argv):
            path = argv[i + 1]; i += 2
        else:
            print("hold usage error: " + a); return 2
    if not root or not os.path.isdir(root):
        print("hold no delegate worktree known"); return 0
    root = os.path.realpath(root)
    roots = [root] + [os.path.realpath(e) for e in extras if os.path.isdir(e)]
    if root in ("/", os.path.realpath(HOME)):
        print("hold delegate root is / or $HOME (too broad to scope writes)"); return 0
    cmd = sys.stdin.read()
    ok, rule = is_safe(cmd, kind, path, root, roots)
    print(("approve " if ok else "hold ") + rule.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

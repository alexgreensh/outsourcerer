#!/usr/bin/env python3
"""Approver policy "safe": decide approve|hold for one pending delegate action.

Deny by default. There is exactly ONE gate, is_safe(): it returns approve only when NO danger rule
matched AND EVERY segment of the command is in the safe set. Anything not understood holds.

Round 2 (review L3-VERDICT): the classifier no longer approves a command NAME with arbitrary
flags, and no longer treats a token as a literal path when the shell would expand it.
- Anything the shell expands before running is held up front: any `$`, backticks, braces, `~user`
  / `~+` / `~-`, `=~`, a truncated `…`, a trailing operator, more than one line, any mention of
  OSRC_HOME.
- Every approved command has a flag allowlist. An unknown flag (including attached forms such as
  `-XPUT`, `-osrc/x`, `--output=...`) holds.
- Env prefixes hold (a tiny harmless list aside), with a named rule for OSRC_HOME, HOME, PATH,
  TMUX*, GIT_*, BASH_ENV and *_OPTIONS. `env -u` is parsed; unsetting OSRC_HOME or HOME holds.
- Writes never touch `.git`. Paths compare case-folded on macOS.

Usage:
  approver_classify.py --root DIR [--extra DIR]... [--kind shell|write|read] [--path P]   (command on stdin)
  -> prints "approve <rule>" or "hold <rule>" (one line), exit 0. Exit 2 = usage error (caller holds).

`safe` stops accidents. It is not a sandbox: a delegate allowed to write tests/x.sh and then run
`bash tests/x.sh` can run anything. See references/screen-and-approver.md.
"""
from __future__ import annotations

import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))   # -I drops the script dir
from approver_tables import *  # noqa: E402,F401,F403  (tables only; logic stays here)
from approver_tables import COLOR, Spec  # noqa: E402
HOME = os.path.expanduser("~")
FOLD = sys.platform == "darwin"   # macOS file systems are case-insensitive by default


def norm(p: str) -> str:
    return p.lower() if FOLD else p



class Hold(Exception):
    pass


def parse(name: str, args: list[str], sp: Spec) -> tuple[list[str], list[tuple[str, str]]]:
    """-> (positionals, [(flag, value)]). Unknown flag = Hold. Letter-level parsing, so attached
    forms (-XPUT, -osrc/x, -fkey=v) are seen."""
    pos, vals, i, eoo = [], [], 0, False
    while i < len(args):
        a = args[i]
        if eoo or a == "-" or not a.startswith("-"):
            pos.append(a); i += 1; continue
        if a == "--":
            eoo = True; i += 1; continue
        if a.startswith("--"):
            key, eq, v = a.partition("=")
            if key in sp.long and not eq:
                i += 1; continue
            if key in sp.long_val:
                if not eq:
                    if i + 1 >= len(args):
                        raise Hold("%s %s needs a value" % (name, key))
                    v = args[i + 1]; i += 1
                vals.append((key, v)); i += 1; continue
            raise Hold("flag not on the %s allowlist: %s" % (name, a))
        body = a[1:]
        if sp.num and body.isdigit():
            i += 1; continue
        j = 0
        while j < len(body):
            c = body[j]
            if c in sp.short_val:
                v = body[j + 1:]
                if not v:
                    if i + 1 >= len(args):
                        raise Hold("%s -%s needs a value" % (name, c))
                    v = args[i + 1]; i += 1
                vals.append(("-" + c, v)); break
            if c not in sp.short:
                raise Hold("flag not on the %s allowlist: -%s (in %s)" % (name, c, a))
            j += 1
        i += 1
    return pos, vals


# ---- paths ---------------------------------------------------------------------------------------
def resolve(path: str, cwd: str) -> str:
    if path == "~" or path.startswith("~/"):
        path = HOME + path[1:]
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def inside(path: str, roots: list[str]) -> bool:
    p = norm(path)
    for r in roots:
        r = norm(r)
        if p == r or p.startswith(r.rstrip("/") + "/"):
            return True
    return False


def check_path(tok: str, cwd: str, roots: list[str], write: bool) -> None:
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
        if norm(p) in [norm(r) for r in roots]:
            raise Hold("write targets the worktree root itself: " + tok)
        for r in roots:
            if inside(p, [r]):
                if ".git" in [norm(x) for x in os.path.relpath(p, r).split(os.sep)]:
                    raise Hold("write into .git: " + tok)
    else:
        root = roots[0]
        if not inside(p, roots) and (inside(p, [os.path.realpath(HOME)]) or inside(os.path.realpath(HOME), [p])):
            raise Hold("read under the home folder outside the worktree: " + tok)
        if not inside(p, roots):
            q = p
            while q and q != "/":
                if os.path.exists(os.path.join(q, ".git")):
                    if not inside(root, [q]):
                        raise Hold("reads another worktree: " + tok)
                    break
                q = os.path.dirname(q)


def check_inside(tok: str, cwd: str, roots: list[str], what: str) -> None:
    check_path(tok, cwd, roots, write=False)
    if not inside(resolve(tok, cwd), roots):
        raise Hold("%s outside the worktree: %s" % (what, tok))


# ---- shell-level danger (before any parsing) -----------------------------------------------------
def outside_single_quotes(cmd: str) -> str:
    """The command with single-quoted spans removed: the shell expands nothing inside '...'.
    Escapes and double-quoted text are kept (the shell still expands $ and ` there)."""
    out, q, i = [], None, 0
    while i < len(cmd):
        c = cmd[i]
        if q == "'":
            q = None if c == "'" else q
            i += 1; continue
        if c == "\\":
            out.append(cmd[i:i + 2]); i += 2; continue
        if c == '"':
            q = None if q == '"' else '"'
        elif c == "'" and q is None:
            q = "'"; i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def pre_checks(cmd: str) -> None:
    if "\n" in cmd or "\r" in cmd:
        raise Hold("multi-line command (continuation lines, heredoc or wrapped text)")
    bare = outside_single_quotes(cmd)
    if "`" in bare or "$(" in bare or "<(" in bare or ">(" in bare:
        raise Hold("command substitution")
    if "$" in bare:
        raise Hold("variable or special-parameter expansion ($)")
    if "{" in bare or "}" in bare:
        raise Hold("brace expansion or group")
    if "…" in cmd:
        raise Hold("truncated command (…): the rest is not visible")
    if "OSRC_HOME" in cmd:
        raise Hold("mentions OSRC_HOME (unset/override would point the run at the live ~/.outsourcerer)")
    t = cmd.rstrip()
    for op in ("&&", "||", "|", ";", "\\", "&"):
        if t.endswith(op):
            raise Hold("command ends in an operator (%s): the rest is not visible" % op)


def check_tilde(tok: str) -> None:
    if tok.startswith("~") and not (tok == "~" or tok.startswith("~/")):
        raise Hold("tilde expansion to another user or the dir stack: " + tok)
    if "=~" in tok or ":~" in tok:
        raise Hold("tilde expansion inside an assignment-like word: " + tok)


def split_segments(cmd: str):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>")
    lex.whitespace_split = True
    lex.commenters = ""
    try:
        toks = list(lex)
    except ValueError as e:
        raise Hold("unparseable: %s" % e)
    segs, cur, prev = [], [], None
    for t in toks:
        if t in OPERATORS:
            if t in ("(", ")"):
                raise Hold("subshell")
            if t == "&":
                raise Hold("background job")
            if cur:
                segs.append((cur, prev))
            cur, prev = [], t
        else:
            cur.append(t)
    if cur:
        segs.append((cur, prev))
    return segs


def take_redirects(tokens, cwd, roots):
    args, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        fd = re.fullmatch(r"\d+", t) and i + 1 < len(tokens) and tokens[i + 1] in REDIR_OPS
        if t in REDIR_OPS or fd:
            if fd:
                i += 1; t = tokens[i]
            tgt = tokens[i + 1] if i + 1 < len(tokens) else ""
            i += 2
            if t in ("<<", "<<<"):
                raise Hold("heredoc / here-string")
            if t in (">&", "<&") and (tgt.isdigit() or tgt == "-"):
                continue
            if not tgt:
                raise Hold("redirect without a target")
            check_tilde(tgt)
            if tgt == "/dev/null":
                continue
            check_path(tgt, cwd, roots, write=(t not in ("<", "<&")))
            continue
        args.append(t); i += 1
    return args


# ---- per-command rules ---------------------------------------------------------------------------
def read_positionals(name, pos, sp, vals, cwd, roots):
    kind = sp.pos
    if kind in ("none", "any"):
        return
    if kind == "one" and len(pos) > 1:
        raise Hold("%s writes its second argument (an output file): %s" % (name, pos[1]))
    if kind == "pattern" and not any(f in ("-e", "--regexp") for f, _ in vals):
        pos = pos[1:]
    if kind == "filter":
        if name == "jq" and pos and re.search(r"\benv\b|\$ENV|\$__loc__|\binput|\bdebug|\bstderr|\$__prog", pos[0]):
            raise Hold("jq filter reads the environment or extra input: " + pos[0])
        pos = pos[1:]
    for a in pos:
        if kind == "inside":
            check_inside(a, cwd, roots, name + " path")
        else:
            check_path(a, cwd, roots, write=False)


def sed_script_ok(script: str) -> None:
    """Only an address plus p, d, q, =, n, N, and s/// with flags g|p|I|digits. Anything else
    (w, W, e, r, R, a, i, c, s///w, s///e, labels, braces) holds."""
    i, n = 0, len(script)
    while i < n:
        while i < n and script[i] in " ;\t":
            i += 1
        if i >= n:
            break
        while i < n and (script[i].isdigit() or script[i] in "$,!"):
            i += 1
        if i < n and script[i] == "/":
            j = script.find("/", i + 1)
            if j < 0:
                raise Hold("sed address not closed")
            i = j + 1
            if i < n and script[i] == ",":
                i += 1
                while i < n and (script[i].isdigit() or script[i] == "$"):
                    i += 1
                if i < n and script[i] == "/":
                    j = script.find("/", i + 1)
                    i = (j + 1) if j >= 0 else n
            while i < n and script[i] == " ":
                i += 1
        if i >= n:
            raise Hold("sed address without a command")
        c = script[i]
        if c in "pdq=nN":
            i += 1; continue
        if c == "s" and i + 1 < n:
            d = script[i + 1]
            if d.isalnum() or d in " \\":
                raise Hold("sed s with an unusual delimiter")
            parts, j = 0, i + 2
            while j < n and parts < 2:
                if script[j] == "\\":
                    j += 2; continue
                if script[j] == d:
                    parts += 1
                j += 1
            if parts < 2:
                raise Hold("sed s not closed")
            while j < n and script[j] != ";":
                if script[j] not in "gpI0123456789 ":
                    raise Hold("sed s flag writes or executes: " + script[j])
                j += 1
            i = j; continue
        raise Hold("sed command not on the allowlist: " + c)


def sed_rule(args, cwd, roots):
    scripts, files, inplace, i, has_e = [], [], False, 0, "-e" in args
    while i < len(args):
        a = args[i]
        if a in ("-n", "-E", "-r", "--quiet", "--silent"):
            i += 1; continue
        if a == "-e":
            scripts.append(args[i + 1] if i + 1 < len(args) else ""); i += 2; continue
        if a == "-i":
            inplace = True
            if i + 1 < len(args) and args[i + 1] == "":
                i += 1
            i += 1; continue
        if a.startswith("-"):
            raise Hold("flag not on the sed allowlist: " + a)
        if not has_e and not scripts:
            scripts.append(a)
        else:
            files.append(a)
        i += 1
    if not scripts:
        raise Hold("sed without a script")
    for s in scripts:
        sed_script_ok(s)
    for f in files:
        check_path(f, cwd, roots, write=inplace)
    if inplace:
        if not files:
            raise Hold("sed -i without a file")
        return "write-in-worktree:sed -i"
    return "read-only:sed"


def awk_rule(args, cwd, roots):
    pos, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "-F":
            i += 2; continue
        if a.startswith("-F") and len(a) > 2:
            i += 1; continue
        if a.startswith("-"):
            raise Hold("flag not on the awk allowlist: " + a)
        pos.append(a); i += 1
    if not pos:
        raise Hold("awk without a program")
    if re.search(r"system|getline|ENVIRON|\||>|close|fflush", pos[0]):
        raise Hold("awk program writes, executes or reads the environment")
    if re.search(r"SYMTAB|FUNCTAB|PROCINFO", pos[0]):   # gawk tables reach ENVIRON and every variable
        raise Hold("awk program reads gawk symbol tables (SYMTAB/FUNCTAB/PROCINFO)")
    if re.search(r"@|ARGV|ARGC", pos[0]):   # gawk @f() indirect calls, @load; ARGV/ARGC read any file
        raise Hold("awk program uses @ (indirect call / @load) or rewrites ARGV/ARGC")
    for f in pos[1:]:
        check_path(f, cwd, roots, write=False)
    return "read-only:awk"


FIND_OK_NOARG = {"-print", "-print0", "-prune", "-empty", "-not", "!", "(", ")", "-o", "-a", "-and", "-or",
                 "-depth", "-xdev"}
FIND_OK_ARG = {"-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth", "-newer", "-mtime",
               "-mmin", "-size", "-regex", "-iregex", "-perm", "-user", "-group", "-wholename"}


def find_rule(args, cwd, roots):
    i, starts = 0, True
    while i < len(args):
        a = args[i]
        if starts and not a.startswith("-") and a not in ("!", "(", ")"):
            check_path(a, cwd, roots, write=False); i += 1; continue
        starts = False
        if a in FIND_OK_NOARG:
            i += 1; continue
        if a in FIND_OK_ARG:
            i += 2; continue
        raise Hold("find predicate not on the allowlist (actions like -exec/-delete hold): " + a)
    return "read-only:find"


WRITE_SPECS = {"mkdir": Spec("pv"), "touch": Spec("acm"), "cp": Spec("rRpafvn"), "mv": Spec("fvn"),
               "rm": Spec("rRfvd"), "rmdir": Spec("pv"), "ln": Spec("sfnv"), "unlink": Spec(""),
               "tee": Spec("a"), "chmod": Spec("Rv", pos="any")}


def write_rule(name, args, cwd, roots):
    if name == "rm" and any(a.startswith("-") and not a.startswith("--") and ("r" in a[1:] or "R" in a[1:]) for a in args):
        raise Hold("recursive rm requires explicit approval")
    pos, _ = parse(name, args, WRITE_SPECS[name])
    if name == "chmod":
        if len(pos) < 2:
            raise Hold("chmod needs a mode and a target")
        mode, pos = pos[0], pos[1:]
        if not re.fullmatch(r"[0-7]{3}|[ugoa]*[+=-][rwxX]+(,[ugoa]*[+=-][rwxX]+)*", mode):
            raise Hold("chmod mode not on the allowlist (setuid/sticky/4-digit): " + mode)
    if not pos:
        raise Hold(name + " without a target")
    if name in ("cp", "ln"):
        for s in pos[:-1]:
            check_path(s, cwd, roots, write=False)
        pos = pos[-1:]
    for t in pos:
        check_path(t, cwd, roots, write=True)
    return "write-in-worktree:" + name


def git_rule(rest, cwd, roots):
    i = 0
    while i < len(rest) and rest[i].startswith("-"):
        if rest[i] == "--no-pager":
            i += 1; continue
        raise Hold("git global flag (could aim at another repo or run a program): " + rest[i])
    if i >= len(rest):
        raise Hold("bare git")
    sub, sargs = rest[i], rest[i + 1:]
    if sub in GIT_READ:
        if sub == "grep" and any(a.startswith("-O") or a.startswith("--open-files") for a in sargs):
            raise Hold("git grep -O runs a pager program")
        pos, _ = parse("git " + sub, sargs, GIT_READ_SPEC)
        for a in pos:
            if "/" in a or os.path.exists(resolve(a, cwd)):
                check_path(a, cwd, roots, write=False)
        return "read-only:git " + sub
    if sub == "branch" and all(a in ("-a", "-r", "-v", "-vv", "--list", "--show-current", "--all") for a in sargs):
        return "read-only:git branch"
    if sub == "tag" and all(a in ("-l", "--list") for a in sargs):
        return "read-only:git tag"
    if sub == "remote" and not sargs:   # names only; -v / get-url / show print URLs (can hold a token)
        return "read-only:git remote"
    if sub == "stash":
        if sargs[:1] in (["list"], ["show"]) and all(a in ("-p", "--stat") or not a.startswith("-") for a in sargs[1:]):
            return "read-only:git stash " + sargs[0]
        raise Hold("git stash changes the shared stash stack (only list/show approve)")
    if sub == "worktree" and sargs == ["list"]:
        return "read-only:git worktree list"
    if sub == "config":
        # Config can hold an http.extraheader AUTHORIZATION line or a token-bearing URL (CI checkouts
        # write both), so --list/--get-all/remote URLs hold. One --get of a harmless key approves.
        if len(sargs) == 2 and sargs[0] == "--get" and re.fullmatch(
                r"(?i)user\.(name|email)|core\.[a-z]+|branch\.[A-Za-z0-9._/-]+\.(remote|merge|rebase)|"
                r"init\.defaultbranch|pull\.rebase|push\.default", sargs[1]):
            return "read-only:git config --get " + sargs[1]
        raise Hold("git config: only --get of a harmless key approves (config can hold tokens)")
    if sub == "switch":
        if (len(sargs) == 1 and not sargs[0].startswith("-")) or \
           (len(sargs) == 2 and sargs[0] == "-c" and not sargs[1].startswith("-")):
            return "write-in-worktree:git switch"
        raise Hold("git switch with flags (can discard work or reset a branch)")
    if sub == "checkout" and len(sargs) == 2 and sargs[0] == "-b" and not sargs[1].startswith("-"):
        return "write-in-worktree:git checkout -b"
    if sub == "add":
        pos, _ = parse("git add", sargs, Spec("Auv", long=("--all", "--update", "--verbose")))
        for a in pos:
            # `git add .` stages the worktree (the index is the write), so the root itself is fine here.
            if os.path.realpath(resolve(a, cwd)) in [os.path.realpath(r) for r in roots]:
                continue
            check_path(a, cwd, roots, write=True)
        return "write-in-worktree:git add"
    if sub == "commit":
        pos, _ = parse("git commit", sargs, Spec("aqv", "m", long=("--all", "--quiet"), long_val=("--message",), pos="none"))
        if pos:
            raise Hold("git commit with path arguments")
        return "write-in-worktree:git commit"
    if sub in ("mv", "rm"):
        pos, _ = parse("git " + sub, sargs, Spec("rqn" if sub == "rm" else "nv"))
        for a in pos:
            check_path(a, cwd, roots, write=True)
        return "write-in-worktree:git " + sub
    if sub == "push":
        raise Hold("git push")
    raise Hold("git %s not on the allowlist" % sub)


def runner_rule(name, rest, cwd, roots):
    sp = RUNNER_SPECS[name]
    pos, vals = parse(name, rest, sp)
    for f, v in vals:
        if f in sp.val_inside:
            check_inside(v, cwd, roots, name + " " + f)
    read_positionals(name, pos, sp, vals, cwd, roots)
    return "test/build:" + name


def pkg_rule(name, rest, cwd, roots):
    if name in ("npm", "pnpm", "yarn"):
        core = [a for a in rest if a not in ("--silent", "-s")]
        if core in (["test"], ["t"]) or (len(core) == 1 and core[0] in SCRIPT_VERBS):
            return "test/build:%s %s" % (name, core[0])
        if len(core) == 2 and core[0] == "run" and core[1] in SCRIPT_VERBS:
            return "test/build:%s run %s" % (name, core[1])
        if core[:1] and core[0] in ("publish", "unpublish", "deprecate", "dist-tag", "owner", "login", "adduser", "token"):
            raise Hold("network publishing: %s %s" % (name, core[0]))
        raise Hold("%s %s (install, extra arguments, or a script name not on the allowlist)" % (name, " ".join(core)))
    if name == "cargo":
        if rest[:1] and rest[0] in ("test", "build", "check", "clippy"):
            parse("cargo " + rest[0], rest[1:], Spec("q", "pj", long=("--all-features", "--workspace", "--release", "--quiet",
                                                                    "--lib", "--bins", "--tests", "--no-fail-fast",
                                                                    "--all-targets", "--locked"),
                                                   long_val=("--package", "--features", "--jobs"), pos="any"))
            return "test/build:cargo " + rest[0]
        raise Hold("cargo %s" % (rest[0] if rest else ""))
    if name == "go":
        if rest[:1] and rest[0] in ("test", "build", "vet"):
            ok_flags = {"-v", "-race", "-short", "-cover"}
            for a in rest[1:]:
                if a.startswith("-"):
                    if a not in ok_flags and not re.fullmatch(r"-(run|count|timeout)=[A-Za-z0-9_.^|]+", a):
                        raise Hold("go flag not on the allowlist: " + a)
                else:
                    check_inside(a, cwd, roots, "go package path")
            return "test/build:go " + rest[0]
        raise Hold("go %s" % (rest[0] if rest else ""))
    raise Hold("package manager: " + name)


def env_word_rule(word: str) -> None:
    nm = word.split("=", 1)[0]
    if nm in ENV_NAMED:
        raise Hold(ENV_NAMED[nm])
    if nm.startswith("TMUX"):
        raise Hold("sets %s (would aim tmux at another server)" % nm)
    if nm.startswith("GIT_"):
        raise Hold("sets %s (git can run programs or use another repo)" % nm)
    if nm.endswith(("_OPTIONS", "_OPTS", "_FLAGS")):
        raise Hold("sets %s (injects options into the program)" % nm)
    if word not in ENV_HARMLESS:
        raise Hold("environment prefix not on the allowlist: " + nm)


def env_rule(args: list[str]) -> list[str]:
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-u":
            nm = args[i + 1] if i + 1 < len(args) else ""
            if nm in ("OSRC_HOME", "HOME"):
                raise Hold("env -u %s (points the run at the live ~/.outsourcerer or a default home)" % nm)
            if nm not in ENV_UNSET_OK:
                raise Hold("env -u %s not on the allowlist" % nm)
            i += 2; continue
        if a.startswith("-"):
            raise Hold("env flag not on the allowlist: " + a)
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", a):
            env_word_rule(a); i += 1; continue
        break
    if i >= len(args):
        raise Hold("env dump (secrets)")
    return args[i:]


NOT_SAFE = {
    "sudo": "privilege escalation", "doas": "privilege escalation", "su": "privilege escalation",
    "curl": "network tool", "wget": "network tool", "nc": "network tool", "ssh": "network tool", "gh": "network tool",
    "scp": "network tool", "rsync": "network tool", "ftp": "network tool", "sftp": "network tool",
    "security": "secrets access", "keychain": "secrets access", "printenv": "secrets access",
    "ps": "shows other processes' environments", "lsof": "process inspection",
}
for _n in ("eval", "exec", "source", ".", "trap", "unset", "export", "set", "declare", "alias"):
    NOT_SAFE[_n] = "shell builtin that changes the environment"
for _n in ("kill", "killall", "pkill", "shutdown", "reboot", "halt", "launchctl", "systemctl", "crontab", "chown",
           "dd", "mkfs", "diskutil", "tmux", "screen", "osascript", "open", "less", "more", "yes", "xargs", "time",
           "nohup", "nice", "watch", "install", "truncate"):
    NOT_SAFE[_n] = "not in the safe set (process control, interactive, unbounded, or runs another command)"


def classify_segment(tokens, prev_op, cwd, roots):
    for t in tokens:
        check_tilde(t)
    args = take_redirects(tokens, cwd, roots)
    while args and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0]):
        env_word_rule(args[0])
        args = args[1:]
    if args and args[0] == "env":
        args = env_rule(args[1:])
    if not args:
        return "redirect-only", cwd
    name, rest = args[0], args[1:]
    if "/" in name:
        raise Hold("runs a program by path: " + name)
    if prev_op in ("|", "|&") and name in INTERPRETERS:
        raise Hold("pipe into a shell/interpreter")
    if name in NOT_SAFE:
        raise Hold("%s: %s" % (NOT_SAFE[name], name))
    if len(rest) == 1 and rest[0] in ("--help", "--version") and name in HELP_OK:
        return "help/version", cwd
    if name == "cd":
        if rest[:1] == ["-"]:
            raise Hold("cd - (goes to $OLDPWD, which is not visible)")
        if len(rest) > 1 or (rest and rest[0].startswith("-")):
            raise Hold("cd with flags")
        tgt = rest[0] if rest else HOME
        check_path(tgt, cwd, roots, write=False)
        return "cd", resolve(tgt, cwd)
    if name == "find":
        return find_rule(rest, cwd, roots), cwd
    if name in ("sed", "gsed"):
        return sed_rule(rest, cwd, roots), cwd
    if name in ("awk", "gawk", "mawk"):
        return awk_rule(rest, cwd, roots), cwd
    if name in ("test", "["):
        ok = {"-f", "-d", "-e", "-s", "-z", "-n", "-x", "-r", "-w", "-L", "!", "-eq", "-ne", "-lt", "-gt", "-le", "-ge", "]"}
        if any(a.startswith("-") and a not in ok for a in rest):
            raise Hold("test operator not on the allowlist")
        return "read-only:test", cwd
    if name in READ_SPECS:
        sp = READ_SPECS[name]
        pos, vals = parse(name, rest, sp)
        if name == "rg" and "--files" in rest:
            sp = Spec(pos="paths")
        read_positionals(name, pos, sp, vals, cwd, roots)
        return "read-only:" + name, cwd
    if name in WRITE_SPECS:
        return write_rule(name, rest, cwd, roots), cwd
    if name == "git":
        return git_rule(rest, cwd, roots), cwd
    if name in RUNNER_SPECS:
        return runner_rule(name, rest, cwd, roots), cwd
    if name in ("npx", "pnpx"):
        if rest and rest[0] in RUNNER_SPECS:
            return runner_rule(rest[0], rest[1:], cwd, roots), cwd
        raise Hold("npx runs a package that is not an allowlisted runner")
    if name == "ruff":
        if rest[:1] == ["check"]:
            pos, _ = parse("ruff check", rest[1:], Spec("q", long=("--quiet", "--statistics", "--no-fix"),
                                                         long_val=("--select", "--ignore", "--output-format"), pos="inside"))
            for a in pos:
                check_inside(a, cwd, roots, "ruff path")
            return "test/build:ruff check", cwd
        if rest[:2] == ["format", "--check"] and all(not a.startswith("-") for a in rest[2:]):
            for a in rest[2:]:
                check_inside(a, cwd, roots, "ruff path")
            return "test/build:ruff format --check", cwd
        raise Hold("ruff without check (rewrites files) or flags off the allowlist")
    if name in ("prettier", "black"):
        if any(a in ("--check", "--diff") for a in rest) and all(a in ("--check", "--diff", "-q", "--quiet") or not a.startswith("-") for a in rest):
            for a in rest:
                if not a.startswith("-"):
                    check_inside(a, cwd, roots, name + " path")
            return "test/build:%s --check" % name, cwd
        raise Hold(name + " rewrites files or uses flags off the allowlist")
    if name in ("make", "gmake"):
        tgts = [a for a in rest if a not in ("-s", "-k") and not re.fullmatch(r"-j\d*", a)]
        if tgts and all(t in SCRIPT_VERBS for t in tgts):
            return "test/build:make " + " ".join(tgts), cwd
        raise Hold("make target/flag not on the allowlist")
    if name in ("python", "python3"):
        if len(rest) >= 2 and rest[0] == "-m":
            mod = rest[1]
            if mod == "pytest":
                return runner_rule("pytest", rest[2:], cwd, roots), cwd
            if mod == "unittest":
                pos, _ = parse("unittest", rest[2:], Spec("vqfb", "k", pos="any"))
                for a in pos:
                    if "/" in a or a.endswith(".py"):
                        check_inside(a, cwd, roots, "unittest path")
                    elif not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", a):
                        raise Hold("unittest argument not a module or a worktree path: " + a)
                return "test/build:python -m unittest", cwd
            if mod in ("py_compile", "compileall"):
                for a in rest[2:]:
                    if a.startswith("-") and a != "-q":
                        raise Hold("flag not on the allowlist: " + a)
                    if not a.startswith("-"):
                        check_inside(a, cwd, roots, mod + " path")
                return "test/build:python -m " + mod, cwd
            if mod in ("mypy", "flake8", "pylint"):
                return runner_rule(mod, rest[2:], cwd, roots), cwd
            raise Hold("python -m " + mod)
        raise Hold("interpreter: " + name)
    if name in ("bash", "sh", "zsh") and rest:
        if rest[0] == "-n":
            for a in rest[1:]:
                check_path(a, cwd, roots, write=False)
            return "test/build:%s -n" % name, cwd
        script = rest[0]
        if script.startswith("-"):
            raise Hold("%s %s" % (name, script))
        p = resolve(script, cwd)
        base = os.path.basename(p)
        rel = "/" + os.path.relpath(p, roots[0]) if inside(p, roots[:1]) else ""
        if rel and (re.match(r"^(test|tests|check|lint|conformance)[_.-]", base) or "/tests/" in rel or "/test/" in rel):
            return "test/build:%s %s" % (name, base), cwd
        raise Hold("runs a script that is not a test inside the worktree")
    if name == "node" and rest[:1] == ["--check"] and len(rest) == 2:
        check_inside(rest[1], cwd, roots, "node --check path")
        return "test/build:node --check", cwd
    if name in PKG_MANAGERS:
        return pkg_rule(name, rest, cwd, roots), cwd
    if name in INTERPRETERS:
        raise Hold("interpreter: " + name)
    raise Hold("unknown command: " + name)


def sealed_runner(cmd: str, cwd: str, root: str) -> bool:
    """Recognize only this checkout's isolated runner and worktree test paths."""
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        return False
    if len(tokens) < 2 or any(c in cmd for c in "|;&<>\n\r"):
        return False
    relative_runner = "plugins/outsourcerer/skills/outsourcerer/scripts/sealed-run.sh"
    runner = os.path.join(root, relative_runner)
    if tokens[0] not in (relative_runner, runner) or os.path.realpath(runner) != runner or not os.access(runner, os.X_OK):
        return False
    platform_tool = {"darwin": "/usr/bin/sandbox-exec", "linux": "/usr/bin/bwrap"}.get(sys.platform)
    if not platform_tool or not os.access(platform_tool, os.X_OK):
        return False
    test_root = os.path.join(root, "plugins/outsourcerer/skills/outsourcerer/scripts/tests")
    for arg in tokens[1:]:
        if os.path.isabs(arg) or arg.startswith("-") or any(p in (".", "..", "") for p in arg.split("/")):
            return False
        path = resolve(arg, cwd)
        if not inside(path, [test_root]) or not path.endswith(".sh") or not os.path.isfile(path):
            return False
    return True


def is_safe(cmd: str, kind: str, path: str, cwd: str, roots: list[str]) -> tuple[bool, str]:
    """THE gate. (True, rule) only if no danger rule fires AND every segment is in the safe set."""
    try:
        if kind == "trust":
            raise Hold("folder trust prompt (never auto-approved)")
        if kind in ("write", "edit"):
            if not path:
                raise Hold("file write with no visible path")
            pre_checks(path)
            check_tilde(path)
            check_path(path, cwd, roots, write=True)
            return True, "write-in-worktree:file " + path
        if kind == "read":
            if not path:
                raise Hold("file read with no visible path")
            pre_checks(path)
            check_tilde(path)
            check_path(path, cwd, roots, write=False)
            return True, "read-only:file " + path
        if kind != "shell":
            raise Hold("unrecognised prompt kind: " + (kind or "none"))
        cmd = cmd.strip()
        if not cmd:
            raise Hold("no command visible")
        pre_checks(cmd)
        if sealed_runner(cmd, cwd, roots[0]):
            return True, "isolated:sealed-run"
        rules, cur = [], cwd
        segs = split_segments(cmd)
        # Names only, and only a form that cannot print a value: `compgen -e` alone. (`env | cut
        # -d= -f1` printed whole rows of multi-line values, e.g. a PEM body: review round 4, B.)
        if [t for t, _ in segs] == [["compgen", "-e"]]:
            return True, "read-only:env names (compgen -e)"
        for seg, prev in segs:
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
    if norm(root) in ("/", norm(os.path.realpath(HOME))):
        print("hold delegate root is / or $HOME (too broad to scope writes)"); return 0
    cmd = sys.stdin.read()
    ok, rule = is_safe(cmd, kind, path, root, roots)
    print(("approve " if ok else "hold ") + rule.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

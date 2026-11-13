"""Data tables for approver_classify.py: protected paths, secret names, env rules, flag specs.
Split out in L3 round 3 so the classifier logic file stays well under the 1,000-line limit. Rules
(the code that reads these) stay in approver_classify.py."""
from __future__ import annotations

import os
import re

HOME = os.path.expanduser("~")

# ---- protected locations and secrets -------------------------------------------------------------
PROTECTED_DIRS = [os.path.join(HOME, d) for d in (".outsourcerer", ".claude", ".ssh", ".gnupg", ".aws",
                                                  ".config/gh", ".kube", ".docker", "Library/Keychains",
                                                  ".netrc", ".config/gcloud", ".azure")]
if os.environ.get("OSRC_HOME"):
    PROTECTED_DIRS.append(os.environ["OSRC_HOME"])
SECRET_NAME = re.compile(
    r"(^|/)(\.env(\..*)?|\.envrc|\.netrc|\.npmrc|\.pypirc|id_[a-z0-9]+|.*\.pem|.*\.key|.*\.p12|.*\.pfx|"
    r".*\.keychain(-db)?|\.?credentials(\..*)?|.*token.*|.*secret.*|.*password.*|auth\.json|"
    r"\.git-credentials|.*\.kdbx|"
    r"\.(bashrc|zshrc|kshrc|cshrc|tcshrc|profile|bash_profile|bash_login|bash_logout|zprofile|zshenv|zlogin|"
    r"zlogout)|.*_history|environ|\.histfile|config\.fish|\.python_history|\.node_repl_history)$", re.I)
ENV_NAMED = {  # env names that get their own rule (every env prefix holds; these say why)
    "OSRC_HOME": "overrides OSRC_HOME (would point the run at the live ~/.outsourcerer)",
    "HOME": "overrides HOME (moves ~ and every dotfile lookup)",
    "PATH": "overrides PATH (chooses which programs run)",
    "BASH_ENV": "sets BASH_ENV (runs a file before the script)",
    "ENV": "sets ENV (runs a file before the shell)",
}
ENV_HARMLESS = {"CI=1", "CI=true", "NO_COLOR=1", "FORCE_COLOR=0", "FORCE_COLOR=1", "TERM=dumb",
                "PYTHONDONTWRITEBYTECODE=1", "PYTHONUNBUFFERED=1"}
ENV_UNSET_OK = {"TMUX", "TMUX_PANE", "CLAUDECODE", "NO_COLOR"}

OPERATORS = {"&&", "||", ";", "|", "&", "|&", ";;", "(", ")"}
REDIR_OPS = {">", ">>", "<", ">&", "<<", "<<<", ">|", "&>", "&>>", "<>", "<&"}

# ---- flag specs ----------------------------------------------------------------------------------
class Spec:
    """Allowed flags for one command. short: boolean letters; short_val: letters taking a value;
    long: boolean long flags; long_val: long flags taking a value (--x=v or --x v); num: allow -NUM.
    pos: how positionals are read: paths | one (a single path: a 2nd is an output) | none | any | pattern (first is a pattern) | filter (first
    is a program) | inside (paths that must be inside the worktree). val_inside: value flags whose
    path must be inside the worktree."""
    def __init__(self, short="", short_val="", long=(), long_val=(), num=False, pos="paths", val_inside=()):
        self.short, self.short_val = set(short), set(short_val)
        self.long, self.long_val = set(long), set(long_val)
        self.num, self.pos, self.val_inside = num, pos, set(val_inside)


# ---- command tables ------------------------------------------------------------------------------
COLOR = ("--color", "--colour")
READ_SPECS = {
    "ls": Spec("1aAlhtrSRdFGiknopsucT", long=("--all", "--almost-all", "--human-readable") + COLOR, long_val=COLOR),
    "cat": Spec("nbsvetAu"),
    "head": Spec("qv", "nc", num=True),
    "tail": Spec("qvr", "nc", num=True),
    "wc": Spec("lwcmL"),
    "grep": Spec("rRnilvcwxEFHhoqsLaIZzP", "eABCm",
                 long=("--line-number", "--ignore-case", "--recursive", "--count", "--files-with-matches", "--word-regexp") + COLOR,
                 long_val=("--include", "--exclude", "--exclude-dir", "--regexp", "--max-count") + COLOR, pos="pattern"),
    "rg": Spec("nilvcwxFHoqsSuUN.", "eABCmgtT",
               long=("--files", "--hidden", "--no-ignore", "--line-number", "--count", "--files-with-matches",
                     "--fixed-strings", "--ignore-case", "--smart-case", "--no-heading", "--heading", "--json",
                     "--vimgrep", "--word-regexp", "--multiline") + COLOR,
               long_val=("--glob", "--type", "--type-not", "--regexp", "--max-count", "--context",
                         "--after-context", "--before-context", "--max-depth") + COLOR, pos="pattern"),
    "file": Spec("bLi"),
    "stat": Spec("Llnqrsx", "ft"),
    "du": Spec("shcakLx", "d"),
    "df": Spec("hkPi"),
    "pwd": Spec("LP", pos="none"),
    "which": Spec("a", pos="none"),
    "type": Spec("a", pos="none"),
    "tree": Spec("adfCi", "LIP"),
    "diff": Spec("uqrNwbBiyc", "U", long=("--brief", "--recursive") + COLOR),
    "cmp": Spec("ls"),
    "uniq": Spec("cdui", pos="one"),
    "cut": Spec("s", "cfd"),
    "tr": Spec("dsc", pos="none"),
    "nl": Spec("", "ba"),
    "jq": Spec("rcSjneC", long=("--raw-output", "--compact-output", "--sort-keys", "--exit-status", "--slurp"), pos="filter"),
    "basename": Spec("a", "s", pos="none"),
    "dirname": Spec(pos="none"),
    "realpath": Spec("eqs", pos="none"),
    "readlink": Spec("fen", pos="none"),
    "date": Spec("uR", pos="none"),
    "uname": Spec("amnrsvp", pos="none"),
    "whoami": Spec(pos="none"), "id": Spec("unG", pos="none"),
    "true": Spec(pos="none"), "false": Spec(pos="none"),
    "sleep": Spec(pos="none"),
    "echo": Spec("ne", pos="none"),
    "printf": Spec(pos="none"),
    "md5": Spec("qr"), "md5sum": Spec(""), "shasum": Spec("", "a"), "sha1sum": Spec(""), "sha256sum": Spec(""),
    "column": Spec("tx", "s"),
    "comm": Spec("123"),
    "fold": Spec("bs", "w"),
    "rev": Spec(""),
    "seq": Spec("", "sf", pos="none"),
    "hexdump": Spec("Cv", "n"), "xxd": Spec("p", "lsc", pos="one"), "od": Spec("cxAv", "tN"), "strings": Spec("a", "n"),
    "sort": Spec("rnufbVhsd", "kt"),
    "shellcheck": Spec("x", "sSef", long=("--external-sources",), long_val=("--shell", "--severity", "--exclude", "--format")),
}
HELP_OK = set(READ_SPECS) | {"git", "gh", "npm", "pnpm", "yarn", "npx", "node", "python", "python3", "pip", "pip3",
                             "cargo", "go", "make", "pytest", "ruff", "mypy", "tsc", "eslint", "jest", "vitest",
                             "devin", "claude", "codex", "agy", "gemini", "cursor-agent", "outsourcerer",
                             "outsourcerer.sh", "tmux", "uv", "deno", "bun", "rustc", "swift", "brew", "find",
                             "sed", "awk", "rm", "cp", "mv", "mkdir"}

GIT_READ = {"status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog",
            "cat-file", "ls-tree", "merge-base", "rev-list", "name-rev", "show-ref", "for-each-ref",
            "count-objects", "version", "grep"}
GIT_READ_LONG = {"--oneline", "--stat", "--shortstat", "--numstat", "--name-only", "--name-status", "--graph",
                 "--decorate", "--all", "--no-merges", "--merges", "--first-parent", "--reverse", "--cached",
                 "--staged", "--no-color", "--patch", "--follow", "--short", "--branch", "--porcelain",
                 "--ignored", "--check", "--summary", "--exit-code", "--quiet", "--no-patch", "--raw",
                 "--show-toplevel", "--abbrev-ref", "--git-dir", "--is-inside-work-tree", "--show-prefix",
                 "--verify", "--tags", "--always", "--dirty", "--count", "--others", "--modified", "--deleted",
                 "--exclude-standard", "--full-name", "--heads", "--long", "--ignore-all-space",
                 "--left-right", "--cherry-pick", "--abbrev-commit", "--source"} | set(COLOR)
GIT_READ_LONG_VAL = {"--format", "--pretty", "--since", "--until", "--after", "--before", "--author", "--grep",
                     "--max-count", "--date", "--diff-filter", "--unified", "--untracked-files", "--abbrev",
                     "--decorate", "--porcelain", "--word-diff", "--relative", "--sort", "--points-at",
                     "--contains", "--merged", "--no-merged", "--skip", "--committer"} | set(COLOR)
GIT_READ_SPEC = Spec("pswbqznrtlcuvSeiEFI", "nUL", tuple(GIT_READ_LONG), tuple(GIT_READ_LONG_VAL), num=True, pos="any")

GH_READ = {("pr", "view"), ("pr", "list"), ("pr", "diff"), ("pr", "checks"), ("pr", "status"),
           ("issue", "view"), ("issue", "list"), ("issue", "status"), ("run", "view"),
           ("run", "list"), ("repo", "view"), ("release", "view"), ("release", "list"),
           ("workflow", "list"), ("workflow", "view"), ("auth", "status"), ("label", "list")}
GH_SPEC = Spec("", "RLq", long=("--log", "--log-failed", "--comments", "--name-only", "--patch", "--exit-status"),
               long_val=("--json", "--jq", "--state", "--limit", "--repo", "--author", "--label", "--base",
                         "--head", "--search", "--branch", "--workflow", "--status", "--job", "--attempt") + COLOR,
               pos="any")

SCRIPT_VERBS = {"test", "tests", "lint", "build", "check", "typecheck", "type-check", "format:check",
                "test:unit", "verify"}
PKG_MANAGERS = {"npm", "pnpm", "yarn", "bun", "pip", "pip3", "uv", "brew", "apt", "apt-get", "gem",
                "cargo", "go", "poetry", "pipx", "conda", "port", "dnf", "yum", "apk", "composer"}
INTERPRETERS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "perl",
                "ruby", "php", "osascript", "deno", "bun", "pwsh"}
RUNNER_SPECS = {
    "pytest": Spec("xqvsl", "km", long=("--lf", "--ff", "--no-header", "--disable-warnings", "--exitfirst", "--quiet", "--verbose"),
                   long_val=("--maxfail", "--tb"), pos="inside"),
    "jest": Spec("i", "t", long=("--runInBand", "--silent", "--ci", "--verbose", "--passWithNoTests"),
                 long_val=("--testNamePattern",), pos="inside"),
    "vitest": Spec("", "t", long=("--run", "--silent"), long_val=("--reporter", "--testNamePattern"), pos="inside"),
    "tsc": Spec("", "p", long=("--noEmit", "--pretty"), long_val=("--project",), pos="none", val_inside=("-p", "--project")),
    "eslint": Spec("", "", long=("--quiet",), long_val=("--max-warnings", "--ext", "--format"), pos="inside"),
    "mypy": Spec("", "", long=("--strict", "--ignore-missing-imports", "--no-error-summary", "--pretty"), pos="inside"),
    "pyright": Spec(pos="inside"),
    "flake8": Spec("", "", long_val=("--max-line-length", "--select", "--ignore", "--extend-ignore"), pos="inside"),
    "pylint": Spec("", "", long_val=("--disable", "--enable"), pos="inside"),
    "shellcheck": READ_SPECS["shellcheck"],
    "bats": Spec("t", pos="inside"),
    "ctest": Spec("", "j", long=("--output-on-failure",), pos="none"),
}

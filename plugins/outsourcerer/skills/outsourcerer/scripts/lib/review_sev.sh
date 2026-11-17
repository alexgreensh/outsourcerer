# shellcheck shell=bash
# lib/review_sev.sh -- finding severities for the review queue (lib/review.sh), 0.17 lane S2.
#
# A finding is one top-level line of the verdict body (line 1 is the verdict) plus the indented lines
# under it. Its severity is the tag at its start, after list markup ("- ", "1.", "- [ ] ", "**"):
#   [must-fix] / must-fix: / [blocker] / blocker:   -> must-fix
#   [nit] / nit:                                     -> nit
#   [pre-existing] / pre-existing:                   -> pre-existing
#   no tag                                           -> must-fix (a finding nobody downgraded blocks)
# Routing (only must-fix sends a lane back):
#   CHANGES whose findings are ALL nit or pre-existing -> MERGE (verdict_raw keeps CHANGES)
#   MERGE that lists an explicitly tagged must-fix     -> CHANGES
#   BLOCK, and everything else                         -> the first line stands
# Pre-existing findings never block: each becomes a note in $OSRC_HOME/review/notes/<lane>.md.

# _osrc_sev_parse <verdict-file> -> one finding per record: "<severity>\t<explicit 0|1>\t<text>", the
# text's continuation lines joined with \037 (unit separator; never in review prose).
_osrc_sev_parse() {
  python3 - "$1" <<'PY' 2>/dev/null
import re, sys
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")[1:]
except OSError:
    sys.exit(0)
MARK = re.compile(r"^(?:[-*+]\s+|\d+[.)]\s+)?(?:\[[ xX]\]\s+)?")
TAG = re.compile(r"^(?:\*\*|__)?\[?\s*(must[- ]?fix|blocker|nit|pre-?existing)\s*\]?(?:\*\*|__)?\s*:?(?:\*\*|__)?\s*", re.I)
SEV = {"nit": "nit", "blocker": "must-fix"}
out = []
for raw in lines:
    if not raw.strip():
        continue
    if raw[0] in " \t" and out:
        out[-1][2] += "\x1f" + raw.rstrip()
        continue
    if raw.lstrip().startswith("#"):
        continue
    body = MARK.sub("", raw.strip(), count=1)
    m = TAG.match(body)
    if m:
        t = m.group(1).lower().replace(" ", "-")
        sev = SEV.get(t, "pre-existing" if t.startswith("pre") else "must-fix")
        out.append([sev, "1", raw.rstrip()])
    else:
        out.append(["must-fix", "0", raw.rstrip()])
for sev, exp, text in out:
    print("%s\t%s\t%s" % (sev, exp, text))
PY
}

_osrc_sev_counts() { # <verdict-file> -> "<must-fix> <nit> <pre-existing> <explicit-must-fix>"
  _osrc_sev_parse "$1" | awk -F'\t' '{c[$1]++; if ($1=="must-fix" && $2=="1") e++} END {printf "%d %d %d %d", c["must-fix"], c["nit"], c["pre-existing"], e}'
}

# The verdict that actually routes the lane. <raw> is MERGE|CHANGES|BLOCK from line 1.
_osrc_sev_route() { # <raw> <verdict-file>
  local raw="$1" mf nit pre emf
  read -r mf nit pre emf <<<"$(_osrc_sev_counts "$2")"
  case "$raw" in
    CHANGES) if [ "$mf" -eq 0 ] && [ $((nit + pre)) -gt 0 ]; then printf MERGE; return 0; fi ;;
    MERGE) if [ "$emf" -gt 0 ]; then printf CHANGES; return 0; fi ;;
  esac
  printf '%s' "$raw"
}

# Findings of one severity, continuation lines restored. <which>: must-fix | nit | pre-existing.
_osrc_sev_lines() { # <verdict-file> <which>
  _osrc_sev_parse "$1" | awk -F'\t' -v w="$2" '$1==w { t=$0; sub(/^[^\t]*\t[^\t]*\t/, "", t); gsub(/\037/, "\n", t); print t }'
}

# Pre-existing findings of one review item -> the lane's notes file, once per item.
_osrc_sev_note_preexisting() { # <lane> <item-id> <verdict-file>
  local d="$OSRC_HOME/review/notes" lines
  lines="$(_osrc_sev_lines "$3" pre-existing)"; [ -n "$lines" ] || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  grep -qxF "## $2" "$d/$1.md" 2>/dev/null && return 0
  { printf '## %s\n%s\n\n' "$2" "$lines"; } >> "$d/$1.md"
}

# What a re-review hands the reviewer from the previous round: every finding that blocks (tagged
# must-fix/blocker, and untagged), with its continuation lines.
_osrc_sev_prior() { # <verdict-file>
  _osrc_sev_lines "$1" must-fix
}

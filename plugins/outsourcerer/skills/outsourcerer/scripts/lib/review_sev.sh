# shellcheck shell=bash
# lib/review_sev.sh -- finding severities for the review queue (lib/review.sh), 0.17 lane S2.
#
# A verdict file's findings carry one tag each: [must-fix], [nit] or [pre-existing] (also accepted
# without brackets, followed by a colon). Only must-fix sends a lane back:
#   CHANGES with tagged findings and no must-fix -> routed to MERGE (verdict_raw keeps CHANGES)
#   MERGE that still lists a must-fix            -> routed to CHANGES (the must-fix wins)
#   untagged findings (older reviewers)          -> the first line stands, as before
#   BLOCK                                         -> always stands
# Pre-existing findings never block: each becomes a note in $OSRC_HOME/review/notes/<lane>.md, a
# separate task for later.

_OSRC_SEV_MF='^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\[must[- ]fix\]|must[- ]fix:)'
_OSRC_SEV_NIT='^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\[nit\]|nit:)'
_OSRC_SEV_PRE='^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\[pre-?existing\]|pre-?existing:)'

_osrc_sev_counts() { # <verdict-file> -> "<must-fix> <nit> <pre-existing>" (body only, line 1 is the verdict)
  local body; body="$(tail -n +2 "$1" 2>/dev/null)"
  printf '%s %s %s' "$(grep -ciE "$_OSRC_SEV_MF" <<<"$body")" "$(grep -ciE "$_OSRC_SEV_NIT" <<<"$body")" "$(grep -ciE "$_OSRC_SEV_PRE" <<<"$body")"
}

# The verdict that actually routes the lane. <raw> is MERGE|CHANGES|BLOCK from line 1.
_osrc_sev_route() { # <raw> <verdict-file>
  local raw="$1" mf nit pre
  read -r mf nit pre <<<"$(_osrc_sev_counts "$2")"
  case "$raw" in
    CHANGES) if [ "$mf" -eq 0 ] && [ $((nit + pre)) -gt 0 ]; then printf MERGE; return 0; fi ;;
    MERGE) if [ "$mf" -gt 0 ]; then printf CHANGES; return 0; fi ;;
  esac
  printf '%s' "$raw"
}

# Lines of one severity from a verdict file (body only). <which>: must-fix | nit | pre-existing.
_osrc_sev_lines() { # <verdict-file> <which>
  local re
  case "$2" in must-fix) re="$_OSRC_SEV_MF" ;; nit) re="$_OSRC_SEV_NIT" ;; *) re="$_OSRC_SEV_PRE" ;; esac
  tail -n +2 "$1" 2>/dev/null | grep -iE "$re"
}

# Pre-existing findings of one review item -> the lane's notes file, once per item.
_osrc_sev_note_preexisting() { # <lane> <item-id> <verdict-file>
  local d="$OSRC_HOME/review/notes" lines
  lines="$(_osrc_sev_lines "$3" pre-existing)"; [ -n "$lines" ] || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  grep -qxF "## $2" "$d/$1.md" 2>/dev/null && return 0
  { printf '## %s\n%s\n\n' "$2" "$lines"; } >> "$d/$1.md"
}

# What a re-review hands the reviewer from the previous round: its must-fix findings only. A round
# with no tags (older reviewer) falls back to every finding, so nothing is silently dropped.
_osrc_sev_prior() { # <verdict-file>
  local mf; mf="$(_osrc_sev_lines "$1" must-fix)"
  if [ -n "$mf" ]; then printf '%s\n' "$mf"
  elif [ -z "$(_osrc_sev_lines "$1" nit)$(_osrc_sev_lines "$1" pre-existing)" ]; then tail -n +2 "$1" | grep -v '^[[:space:]]*$'
  fi
}

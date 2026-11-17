# shellcheck shell=bash
# lib/review_sev.sh -- the stated verdict line of a review (lib/review.sh), 0.17 lane S2 (round 4).
#
# Severity is STATED by the reviewer, never inferred from the findings' wording. Line 1 of the
# verdict file must be exactly one of:
#   VERDICT: MERGE
#   VERDICT: CHANGES must-fix=<n> nit=<n> pre-existing=<n>
#   VERDICT: BLOCK
# Routing reads only that line (_osrc_sev_verdict):
#   CHANGES must-fix>=1 -> CHANGES (sendback)
#   CHANGES must-fix=0  -> MERGE with notes (verdict_raw CHANGES; nits/pre-existing stay on the item)
#   MERGE -> MERGE; BLOCK -> BLOCK
# Anything else is malformed: review.sh hands it back to the REVIEWER once, then to a person.
# The body below line 1 is free text for people. _osrc_sev_findings only cuts it into sections for the
# sendback and the re-review checklist; it never changes where the lane goes.

# _osrc_sev_verdict <verdict-file> -> "<VERDICT> <must-fix> <nit> <pre-existing> <raw>"; rc 1 = malformed.
_osrc_sev_verdict() {
  local l="" cr a b c x n
  cr="$(printf '\r')"
  IFS= read -r l < "$1" 2>/dev/null || [ -n "$l" ] || return 1
  l="${l%"$cr"}"; while [ "${l% }" != "$l" ]; do l="${l% }"; done
  case "$l" in
    "VERDICT: MERGE") printf 'MERGE 0 0 0 MERGE'; return 0 ;;
    "VERDICT: BLOCK") printf 'BLOCK 0 0 0 BLOCK'; return 0 ;;
    "VERDICT: CHANGES must-fix="*) ;;
    *) return 1 ;;
  esac
  read -r a b c x <<<"${l#VERDICT: CHANGES }"
  [ -z "$x" ] && [ "$l" = "VERDICT: CHANGES $a $b $c" ] || return 1
  a="${a#must-fix=}"; b="${b#nit=}"; c="${c#pre-existing=}"
  [ "$l" = "VERDICT: CHANGES must-fix=$a nit=$b pre-existing=$c" ] || return 1
  for n in "$a" "$b" "$c"; do case "$n" in ''|*[!0-9]*) return 1 ;; esac; [ "${#n}" -le 4 ] || return 1; done
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
  if [ "$a" -ge 1 ]; then printf 'CHANGES %s %s %s CHANGES' "$a" "$b" "$c"; else printf 'MERGE 0 %s %s CHANGES' "$b" "$c"; fi
}

# The exact text the reviewer is told (brief, review-next message, bounce).
_osrc_sev_format() { printf 'first line exactly "VERDICT: MERGE", "VERDICT: CHANGES must-fix=<n> nit=<n> pre-existing=<n>" or "VERDICT: BLOCK"'; }

# _osrc_sev_findings <verdict-file> <must-fix|nit|all> -> findings text for people.
# Sections are the headings the brief asks for: "## Must-fix", "## Nits", "## Pre-existing". Text outside
# those sections (or a body with no headings) counts as must-fix text: nothing is dropped. Checked items ("- [x] ... fixed",
# the engine's own re-review checklist) and their indented lines are notes, never re-sent as open work.
_osrc_sev_findings() {
  awk -v want="$2" '
    NR == 1 { next }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^#+[ \t]/ {
      h = tolower(line); sub(/^#+[ \t]+/, "", h); sub(/[ \t:]+$/, "", h)
      if (h ~ /^must[- ]?fix/) { sec = "must-fix"; skip = 0; next }
      if (h ~ /^nits?$|^nits? \(/) { sec = "nit"; skip = 0; next }
      if (h ~ /^pre[- ]?existing/) { sec = "pre"; skip = 0; next }
      sec = ""
    }
    line ~ /^[ \t]*[-*+][ \t]+\[[xX]\]/ { skip = 1; ind = match(line, /[^ \t]/); next }
    skip && line ~ /^[ \t]/ && match(line, /[^ \t]/) > ind { next }
    { skip = 0; n++; txt[n] = line; s[n] = sec }
    END {
      for (i = 1; i <= n; i++) {
        k = (s[i] == "") ? "must-fix" : s[i]
        if (want == "all" || k == want) { m++; out[m] = txt[i] }
      }
      lo = 1; while (lo <= m && out[lo] ~ /^[ \t]*$/) lo++
      hi = m; while (hi >= lo && out[hi] ~ /^[ \t]*$/) hi--
      for (i = lo; i <= hi; i++) print out[i]
    }' "$1" 2>/dev/null
}

# What a re-review hands the reviewer from the previous round: the open must-fix findings.
_osrc_sev_prior() { _osrc_sev_findings "$1" must-fix; }

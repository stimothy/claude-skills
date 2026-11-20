# shellcheck shell=bash
#
# Helpers shared by the story-review-swarm scripts. Source it; do not run it.
#
# These mirror code-review-swarm's lib.sh. Each skill is installed as its own
# directory, so one cannot source the other's scripts.

# The reviewers, in the order their briefs and reports are listed. Each is
# the agent story-review-<lens>.
srs_lenses="archivist heckler cartographer shrink dramaturg oathkeeper scholar librarian turing stylist stranger"

srs_die() {
  echo "$(basename "$0"): $1" >&2
  exit "${2:-1}"
}

# Checks that an option has a value; $1 is the option, $2 the count of
# arguments left including it.
srs_need_value() {
  if [ "$2" -lt 2 ]; then
    srs_die "$1 needs a value" 2
  fi
}

# Prints the lens if it is one of the roster, or fails.
srs_lens() {
  local lens
  for lens in $srs_lenses; do
    if [ "$1" = "$lens" ]; then
      echo "$lens"
      return 0
    fi
  done
  srs_die "unknown reviewer: $1 (expected one of: $srs_lenses)" 2
}

# A round directory is one that start-round.sh made.
srs_require_round() {
  if [ -z "${1:-}" ]; then
    srs_die "missing round directory" 2
  fi
  if [ ! -f "$1/meta" ] || [ ! -f "$1/diff.patch" ]; then
    srs_die "not a round directory: $1" 2
  fi
}

# Prints one value from a round's meta file.
srs_meta() {
  awk -F'\t' -v key="$2" '$1 == key { print $2 }' "$1/meta"
}

# Prints a report's finding counts as "total critical high medium low",
# counted from "- Severity:" lines in any case, by the first word after it.
# A line that lists levels with "|", such as a quoted format line, is not a
# finding.
srs_count() {
  awk '
    {
      line = tolower($0)
      if (line !~ /^- severity:/ || index(line, "|")) next
      sub(/^- severity:[^a-z]*/, "", line)
      match(line, /^[a-z]+/)
      n[substr(line, 1, RLENGTH)]++
    }
    END {
      c = n["critical"] + 0; h = n["high"] + 0; m = n["medium"] + 0; l = n["low"] + 0
      printf "%d %d %d %d %d\n", c + h + m + l, c, h, m, l
    }
  ' "$1"
}

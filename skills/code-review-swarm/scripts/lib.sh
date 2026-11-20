# shellcheck shell=bash
#
# Helpers shared by the code-review-swarm scripts. Source it; do not run it.

# The reviewers, in the order their reports are listed. Each is the agent
# code-review-<lens>.
crs_lenses="sleuth pedant advocate doubter locksmith minimalist skeptic"

crs_die() {
  echo "$(basename "$0"): $1" >&2
  exit "${2:-1}"
}

# Checks that an option has a value; $1 is the option, $2 the count of
# arguments left including it.
crs_need_value() {
  if [ "$2" -lt 2 ]; then
    crs_die "$1 needs a value" 2
  fi
}

# Prints the lens if it is one of the seven, or fails.
crs_lens() {
  local lens
  for lens in $crs_lenses; do
    if [ "$1" = "$lens" ]; then
      echo "$lens"
      return 0
    fi
  done
  crs_die "unknown reviewer: $1 (expected one of: $crs_lenses)" 2
}

# A round directory is one that start-round.sh made.
crs_require_round() {
  if [ -z "${1:-}" ]; then
    crs_die "missing round directory" 2
  fi
  if [ ! -f "$1/meta" ] || [ ! -f "$1/diff.patch" ]; then
    crs_die "not a round directory: $1" 2
  fi
}

# Prints one value from a round's meta file.
crs_meta() {
  awk -F'\t' -v key="$2" '$1 == key { print $2 }' "$1/meta"
}

# Prints a report's finding counts as "total critical high medium low",
# counted from "- Severity: <level>" lines in any case. A line holding more
# than the one level, such as a quoted format line, is not a finding.
crs_count() {
  awk '
    {
      line = tolower($0)
      sub(/[[:space:]]+$/, "", line)
      if (line !~ /^- severity:[[:space:]]*[a-z]+$/) next
      sub(/^- severity:[[:space:]]*/, "", line)
      n[line]++
    }
    END {
      c = n["critical"] + 0; h = n["high"] + 0; m = n["medium"] + 0; l = n["low"] + 0
      printf "%d %d %d %d %d\n", c + h + m + l, c, h, m, l
    }
  ' "$1"
}

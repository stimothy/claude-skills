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

# Prints the lens for a reviewer named "sleuth" or "code-review-sleuth", or
# fails if it is not one of the seven.
crs_lens() {
  local lens="${1#code-review-}"
  case " $crs_lenses " in
    *" $lens "*) echo "$lens" ;;
    *) crs_die "unknown reviewer: $1 (expected one of: $crs_lenses)" 2 ;;
  esac
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
# counted from its "- Severity:" lines.
crs_count() {
  awk '
    /^- Severity:[[:space:]]*critical/ { c++ }
    /^- Severity:[[:space:]]*high/ { h++ }
    /^- Severity:[[:space:]]*medium/ { m++ }
    /^- Severity:[[:space:]]*low/ { l++ }
    END { printf "%d %d %d %d %d\n", c + h + m + l, c, h, m, l }
  ' "$1"
}

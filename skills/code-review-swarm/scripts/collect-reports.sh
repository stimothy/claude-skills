#!/usr/bin/env bash
#
# Prints every reviewer's report for a round in one go, under a table of
# finding counts, once all seven have saved theirs.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: collect-reports.sh <round-dir> [--partial]

Prints a table of finding counts by severity, then each reviewer's full
report. Until all seven reports are saved it prints only which are missing
and exits 3; --partial prints what is there instead.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/code-review-swarm/scripts/lib.sh
. "$script_dir/lib.sh"

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

round="${1:-}"
crs_require_round "$round"
shift

partial=0
while [ $# -gt 0 ]; do
  case "$1" in
    --partial) partial=1 ;;
    *) crs_die "unknown option: $1" 2 ;;
  esac
  shift
done

missing=""
present=0
for lens in $crs_lenses; do
  if [ -f "$round/reports/$lens.md" ]; then
    present=$((present + 1))
  else
    missing="$missing $lens"
  fi
done

if [ -n "$missing" ] && [ "$partial" -eq 0 ]; then
  echo "waiting on:$missing"
  exit 3
fi

echo "# code-review-swarm $(basename "$round"): $present of 7 reports"
echo
echo "Diff: $round/diff.patch, from the $(crs_meta "$round" base_desc)"
echo
echo "| Reviewer | Findings | Critical | High | Medium | Low |"
echo "|---|---|---|---|---|---|"
sum_t=0 sum_c=0 sum_h=0 sum_m=0 sum_l=0
for lens in $crs_lenses; do
  report="$round/reports/$lens.md"
  if [ ! -f "$report" ]; then
    echo "| code-review-$lens | missing | | | | |"
    continue
  fi
  read -r t c h m l <<EOF
$(crs_count "$report")
EOF
  echo "| code-review-$lens | $t | $c | $h | $m | $l |"
  sum_t=$((sum_t + t)) sum_c=$((sum_c + c)) sum_h=$((sum_h + h))
  sum_m=$((sum_m + m)) sum_l=$((sum_l + l))
done
echo "| total | $sum_t | $sum_c | $sum_h | $sum_m | $sum_l |"

for lens in $crs_lenses; do
  report="$round/reports/$lens.md"
  if [ -f "$report" ]; then
    echo
    echo "## code-review-$lens"
    echo
    cat "$report"
  fi
done

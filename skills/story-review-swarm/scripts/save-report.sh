#!/usr/bin/env bash
#
# Saves a reviewer's report, read from stdin, into a round, and prints one
# line the reviewer can reply with in place of the report.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: save-report.sh <round-dir> <reviewer> <<'END_OF_REPORT'
<report>
END_OF_REPORT

Saves the report on stdin as <round-dir>/reports/<lens>.md, replacing any
earlier one, and prints a line with its finding counts. <reviewer> is a lens
such as "archivist".
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/story-review-swarm/scripts/lib.sh
. "$script_dir/lib.sh"

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

round="${1:-}"
srs_require_round "$round"
if [ -z "${2:-}" ]; then
  srs_die "missing reviewer name" 2
fi
lens="$(srs_lens "$2")"

mkdir -p "$round/reports"
report="$round/reports/$lens.md"
tmp="$report.tmp.$$"
cat >"$tmp"
if ! grep -q '[^[:space:]]' "$tmp"; then
  rm -f "$tmp"
  srs_die "empty report on stdin; nothing saved"
fi
mv "$tmp" "$report"

read -r total c h m l <<EOF
$(srs_count "$report")
EOF
echo "saved story-review-$lens: $total findings (critical $c, high $h, medium $m, low $l)"

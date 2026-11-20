#!/usr/bin/env bash
#
# Prints the prompt to give each code-review-swarm reviewer for a round, so
# the caller passes them on as they are instead of composing them.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: briefs.sh <round-dir> [<reviewer>...]

Prints one prompt per reviewer, each under a "=== code-review-<lens> ==="
heading. With no reviewers named, prints all seven. Give each reviewer the
text under its heading as its whole prompt.

The skeptic is told about the diff only. The others are also pointed at the
round's context.md, which must exist: write it with add-context.sh first.
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

if [ ! -f "$round/context.md" ]; then
  crs_die "no context for this round yet; write it with add-context.sh first" 2
fi

selected=""
for name in "$@"; do
  selected="$selected $(crs_lens "$name")"
done
if [ -z "$selected" ]; then
  selected="$crs_lenses"
fi

base_desc="$(crs_meta "$round" base_desc)"
base="$(crs_meta "$round" base)"

brief() {
  local lens="$1"
  echo "=== code-review-$lens ==="
  echo "Review the change in the diff file $round/diff.patch. The caller has already worked it out: it runs from the $base_desc to the working tree as it stands, including uncommitted and untracked files. Do not work out the change again."
  case "$lens" in
    skeptic)
      echo "Read that file and nothing else."
      ;;
    advocate)
      echo "Read $round/context.md for what was asked for. That file is the request: review the change against it."
      ;;
    *)
      echo "Read $round/context.md for what the change is for."
      ;;
  esac
  if [ "$lens" != "skeptic" ]; then
    echo "The diff's old side is git object $base: read a file as it was before the change with \`git show $base:<path>\`."
  fi
  cat <<EOF
When you have finished, do not reply with your report. Save it by running this command, with your whole report, in the format your instructions give, in place of the middle line:

$script_dir/save-report.sh $round $lens <<'END_OF_REPORT'
<your report>
END_OF_REPORT

Then reply with only the line the command prints.

EOF
}

for lens in $selected; do
  brief "$lens"
done

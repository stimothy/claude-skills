#!/usr/bin/env bash
#
# Prints the prompt to give each code-review-swarm reviewer for a round, so
# the caller passes them on as they are instead of composing them.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: briefs.sh <round-dir>

Prints one prompt for each of the seven reviewers, each under a
"=== code-review-<lens> ===" heading. Give each reviewer the text under its
heading as its whole prompt.

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
if [ $# -gt 1 ]; then
  crs_die "unexpected argument: $2" 2
fi

if [ ! -f "$round/context.md" ]; then
  crs_die "no context for this round yet; write it with add-context.sh first" 2
fi

base_desc="$(crs_meta "$round" base_desc)"
base="$(crs_meta "$round" base)"

# Paths go into commands the reviewers run, so they are shell-quoted.
q_save="$(printf '%q' "$script_dir/save-report.sh")"
q_round="$(printf '%q' "$round")"

brief() {
  local lens="$1" delim
  # A delimiter the diff's author cannot know, so no line quoted from the
  # diff can end the report early.
  delim="END_OF_REPORT_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
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

$q_save $q_round $lens <<'$delim'
<your report>
$delim

Then reply with only the line the command prints.

EOF
}

for lens in $crs_lenses; do
  brief "$lens"
done

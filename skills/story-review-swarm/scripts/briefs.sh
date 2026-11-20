#!/usr/bin/env bash
#
# Prints the prompt to give each chosen story-review-swarm reviewer for a
# round, so the caller passes them on as they are instead of composing them,
# and records which reviewers were chosen.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: briefs.sh <round-dir> --lenses <list> [--cold <path>]... [--intent <path>]

Prints one prompt for each chosen reviewer, each under a
"=== story-review-<lens> ===" heading, in roster order. Give each reviewer
the text under its heading as its whole prompt. Records the choice in the
round, so collect-reports.sh knows whose reports to wait for; running this
again replaces it.

  --lenses <list>  Reviewers to brief, separated by commas or spaces:
                   archivist heckler cartographer shrink dramaturg
                   oathkeeper scholar librarian turing stylist stranger,
                   or "all".
  --cold <path>    A file the stranger reads, as it now stands; repeat for
                   several, in reading order. Required with stranger and
                   only allowed with it. The stranger is told nothing else:
                   not the diff, not the context, nothing about the story.
  --intent <path>  The author's statement of intent, for oathkeeper. Leave it
                   out and oathkeeper looks for one itself.

Relative paths are taken from the top of the repository, as start-round.sh
lists them. Every other reviewer is pointed at the diff, and at context.md
when add-context.sh has written one.
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
shift

top="$(srs_meta "$round" repo)"

# Prints a path as an absolute one, taking a relative path from the top of
# the repository, or fails if no file is there.
resolve() {
  local path="$1"
  case "$path" in
    /*) ;;
    *) path="$top/$path" ;;
  esac
  if [ ! -f "$path" ]; then
    srs_die "no such file: $1" 2
  fi
  echo "$path"
}

requested=""
cold=()
intent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lenses)
      srs_need_value "$1" $#
      requested="$requested $(printf '%s' "$2" | tr ',' ' ')"
      ;;
    --cold)
      srs_need_value "$1" $#
      cold+=("$(resolve "$2")")
      ;;
    --intent)
      srs_need_value "$1" $#
      intent="$(resolve "$2")"
      ;;
    *) srs_die "unknown option: $1" 2 ;;
  esac
  shift 2
done

if [ -z "${requested// /}" ]; then
  srs_die "no reviewers chosen; pass --lenses (see --help)" 2
fi

# Validate every name before choosing, then keep roster order.
wanted=" "
for name in $requested; do
  if [ "$name" = "all" ]; then
    wanted=" $srs_lenses "
  else
    wanted="$wanted$(srs_lens "$name") "
  fi
done
chosen=""
for lens in $srs_lenses; do
  case "$wanted" in
    *" $lens "*) chosen="$chosen $lens" ;;
  esac
done

case "$chosen " in
  *" stranger "*)
    if [ "${#cold[@]}" -eq 0 ]; then
      srs_die "stranger needs the files it reads; pass them with --cold" 2
    fi
    ;;
  *)
    if [ "${#cold[@]}" -gt 0 ]; then
      srs_die "--cold is only for stranger, which is not chosen" 2
    fi
    ;;
esac
case "$chosen " in
  *" oathkeeper "*) ;;
  *)
    if [ -n "$intent" ]; then
      srs_die "--intent is only for oathkeeper, which is not chosen" 2
    fi
    ;;
esac

for lens in $chosen; do
  echo "$lens"
done >"$round/lenses"

base_desc="$(srs_meta "$round" base_desc)"

# Paths go into commands the reviewers run, so they are shell-quoted.
q_save="$(printf '%q' "$script_dir/save-report.sh")"
q_round="$(printf '%q' "$round")"

brief() {
  local lens="$1" delim file
  # A delimiter the bible's author cannot know, so no line quoted from the
  # bible can end the report early.
  delim="END_OF_REPORT_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  echo "=== story-review-$lens ==="
  if [ "$lens" = "stranger" ]; then
    echo "Read these files, in this order:"
    for file in "${cold[@]}"; do
      echo "- $file"
    done
  else
    echo "Review the change to this novel's story bible or manuscript in the diff file $round/diff.patch. The caller has already worked it out: it runs from the $base_desc to the files as they stand now, including uncommitted and untracked files, so the files on disk show the diff's new side. Paths in the diff are relative to $top. Do not ask for the change in another form."
    if [ -f "$round/context.md" ]; then
      echo "Read $round/context.md for what the author says about this change."
    fi
    if [ "$lens" = "oathkeeper" ] && [ -n "$intent" ]; then
      echo "The author's statement of intent is in $intent."
    fi
  fi
  cat <<EOF
When you have finished, do not reply with your report. Save it by running this command, with your whole report, in the format your instructions give, in place of the middle line:

$q_save $q_round $lens <<'$delim'
<your report>
$delim

Then reply with only the line the command prints.

EOF
}

for lens in $chosen; do
  brief "$lens"
done

#!/usr/bin/env bash
#
# Writes what the author says about a change into a round's context.md, from
# notes and files, so the caller never has to read them.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: add-context.sh <round-dir> <source>...

Adds what the author says about the change to <round-dir>/context.md, which
every reviewer but the stranger is pointed at. Sources are added in the order
given, and a later call appends to what is there. A round needs no context:
leave this out when the author has said nothing about the change.

Sources:
  --note <text>   What the author said. Use "-" to read it from stdin.
  --file <path>   A plan, note or other file, included whole.

Nothing is written unless every source can be read.
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

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
new="$scratch/new"
: >"$new"
sources=0

while [ $# -gt 0 ]; do
  case "$1" in
    --note)
      srs_need_value "$1" $#
      printf '## Note from the author\n\n' >>"$new"
      if [ "$2" = "-" ]; then
        cat >>"$new"
      else
        printf '%s\n' "$2" >>"$new"
      fi
      printf '\n' >>"$new"
      ;;
    --file)
      srs_need_value "$1" $#
      if [ ! -f "$2" ]; then
        srs_die "no such file: $2"
      fi
      printf '## From %s\n\n' "$2" >>"$new"
      cat "$2" >>"$new"
      printf '\n' >>"$new"
      ;;
    *) srs_die "unknown option: $1" 2 ;;
  esac
  sources=$((sources + 1))
  shift 2
done

if [ "$sources" -eq 0 ]; then
  srs_die "no sources given; see --help" 2
fi

context="$round/context.md"
if [ ! -f "$context" ]; then
  printf '# What the author says about this change\n\n' >"$context"
fi
cat "$new" >>"$context"
echo "context: $context ($sources source(s) added, $(wc -l <"$context" | tr -d ' ') lines)"

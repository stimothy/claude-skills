#!/usr/bin/env bash
#
# Writes what a change is for into a round's context.md, from notes, files,
# GitHub issues and pull requests, so the caller never has to read them.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: add-context.sh <round-dir> <source>...

Adds what the change is for to <round-dir>/context.md, which every reviewer
but the skeptic reads. Sources are added in the order given, and a later call
appends to what is there.

Sources:
  --note <text>   A statement of intent. Use "-" to read it from stdin.
  --file <path>   A spec, plan, ticket or other file, included whole.
  --issue <ref>   A GitHub issue: number or URL. Needs the GitHub CLI.
  --pr <ref>      A GitHub pull request's title and description.

Nothing is written unless every source can be read.
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

gh_cmd="${GH:-gh}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
new="$scratch/new"
: >"$new"
sources=0

# Appends a GitHub issue or pull request ($1 is "issue" or "pr").
add_github() {
  local kind="$1" ref="$2" label="Issue"
  if [ "$kind" = "pr" ]; then
    label="Pull request"
  fi
  if ! command -v "$gh_cmd" >/dev/null 2>&1; then
    crs_die "GitHub CLI not found; install gh or pass the text with --note"
  fi
  if ! "$gh_cmd" "$kind" view "$ref" --json title,url,body \
    --jq '"## '"$label"': " + .title + "\n" + .url + "\n\n" + .body' >>"$new"; then
    crs_die "could not read $kind $ref with the GitHub CLI"
  fi
  printf '\n' >>"$new"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --note)
      crs_need_value "$1" $#
      printf '## Note from the caller\n\n' >>"$new"
      if [ "$2" = "-" ]; then
        cat >>"$new"
      else
        printf '%s\n' "$2" >>"$new"
      fi
      printf '\n' >>"$new"
      ;;
    --file)
      crs_need_value "$1" $#
      if [ ! -f "$2" ]; then
        crs_die "no such file: $2"
      fi
      printf '## From %s\n\n' "$2" >>"$new"
      cat "$2" >>"$new"
      printf '\n' >>"$new"
      ;;
    --issue)
      crs_need_value "$1" $#
      add_github issue "$2"
      ;;
    --pr)
      crs_need_value "$1" $#
      add_github pr "$2"
      ;;
    *) crs_die "unknown option: $1" 2 ;;
  esac
  sources=$((sources + 1))
  shift 2
done

if [ "$sources" -eq 0 ]; then
  crs_die "no sources given; see --help" 2
fi

context="$round/context.md"
if [ ! -f "$context" ]; then
  printf '# What this change is for\n\n' >"$context"
fi
cat "$new" >>"$context"
echo "context: $context ($sources source(s) added, $(wc -l <"$context" | tr -d ' ') lines)"

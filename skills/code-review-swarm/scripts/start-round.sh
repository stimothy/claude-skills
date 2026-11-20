#!/usr/bin/env bash
#
# Starts a code-review-swarm round: snapshots the working tree, writes the
# diff the reviewers will read, and prints where it is. The diff itself is
# never printed, so it stays out of the caller's context.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: start-round.sh [--base <ref>] [--since <round-dir>] [--root <dir>]

Run from inside the repository under review. Snapshots the working tree -
commits, staged and unstaged edits, and untracked files that are not ignored -
without touching the index, and writes the diff from the base to that snapshot
into a new round directory.

  --base <ref>         Diff from the merge base of <ref> and HEAD. Default:
                       the default branch (origin/HEAD, else main or master).
  --since <round-dir>  Diff from the snapshot an earlier round took, so a
                       re-review reads only what changed since that round.
                       The new round goes next to it.
  --root <dir>         Where round directories go. Default:
                       $CLAUDE_JOB_DIR/tmp/code-review-swarm, else a new
                       temporary directory.

Prints the round directory, the diff's path and a summary of the change.
Exits 3 when there is nothing to review.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/code-review-swarm/scripts/lib.sh
. "$script_dir/lib.sh"

base_ref=""
since=""
root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      crs_need_value "$1" $#
      base_ref="$2"
      shift
      ;;
    --since)
      crs_need_value "$1" $#
      since="$2"
      shift
      ;;
    --root)
      crs_need_value "$1" $#
      root="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) crs_die "unknown option: $1" 2 ;;
  esac
  shift
done

if [ -n "$base_ref" ] && [ -n "$since" ]; then
  crs_die "give --base or --since, not both" 2
fi
if [ -n "$since" ]; then
  crs_require_round "$since"
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  crs_die "not inside a git work tree"
fi
top="$(git rev-parse --show-toplevel)"

# Prints the default branch: origin/HEAD, else main or master, else nothing.
default_branch() {
  local ref
  if ref="$(git symbolic-ref --short -q refs/remotes/origin/HEAD)"; then
    echo "$ref"
    return 0
  fi
  for ref in main master origin/main origin/master; do
    if git rev-parse --verify -q "$ref^{commit}" >/dev/null; then
      echo "$ref"
      return 0
    fi
  done
}

# Snapshot the working tree as a tree object, through a temporary copy of the
# index so the real one is never touched. The copy keeps the index's
# timestamp: git trusts cached file stats only when a file is older than the
# index, and a fresh timestamp would hide an edit made in the same second as
# the index was last written.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
real_index="$(git rev-parse --git-path index)"
if [ -f "$real_index" ]; then
  cp -p "$real_index" "$scratch/index"
fi
GIT_INDEX_FILE="$scratch/index" git -C "$top" add -A
snapshot="$(GIT_INDEX_FILE="$scratch/index" git write-tree)"

head=""
if git rev-parse --verify -q HEAD >/dev/null; then
  head="$(git rev-parse HEAD)"
fi

if [ -n "$since" ]; then
  base="$(crs_meta "$since" snapshot)"
  base_desc="snapshot of $(basename "$since")"
  if [ -z "$root" ]; then
    root="$(dirname "$since")"
  fi
elif [ -z "$head" ]; then
  base="$(git hash-object -t tree /dev/null)"
  base_desc="empty tree (the repository has no commits)"
else
  if [ -z "$base_ref" ]; then
    base_ref="$(default_branch)"
  fi
  if [ -z "$base_ref" ]; then
    base="$head"
    base_desc="HEAD (no default branch found, so only uncommitted work)"
  elif ! git rev-parse --verify -q "$base_ref^{commit}" >/dev/null; then
    crs_die "unknown ref: $base_ref"
  else
    base="$(git merge-base "$base_ref" HEAD)"
    base_desc="merge base of $base_ref and HEAD ($(git rev-parse --short "$base"))"
  fi
fi

if git diff --quiet "$base" "$snapshot"; then
  echo "nothing to review: no change from the $base_desc"
  exit 3
fi

if [ -z "$root" ]; then
  if [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    root="$CLAUDE_JOB_DIR/tmp/code-review-swarm"
  else
    root="$(mktemp -d "${TMPDIR:-/tmp}/code-review-swarm.XXXXXX")"
  fi
fi
mkdir -p "$root"
root="$(cd "$root" && pwd -P)"
n=1
while [ -e "$root/round-$n" ]; do
  n=$((n + 1))
done
round="$root/round-$n"
mkdir -p "$round/reports"

git diff -U20 --find-renames "$base" "$snapshot" >"$round/diff.patch"
{
  printf 'repo\t%s\n' "$top"
  printf 'head\t%s\n' "$head"
  printf 'base\t%s\n' "$base"
  printf 'base_desc\t%s\n' "$base_desc"
  printf 'snapshot\t%s\n' "$snapshot"
} >"$round/meta"

echo "round: $round"
echo "diff: $round/diff.patch"
echo "base: $base_desc"
echo "change:$(git diff --shortstat "$base" "$snapshot")"
echo "files:"
git diff --name-status --find-renames "$base" "$snapshot" >"$scratch/files"
head -n 40 "$scratch/files" | sed 's/^/  /'
total="$(wc -l <"$scratch/files" | tr -d ' ')"
if [ "$total" -gt 40 ]; then
  echo "  ... and $((total - 40)) more"
fi

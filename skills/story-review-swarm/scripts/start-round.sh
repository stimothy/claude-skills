#!/usr/bin/env bash
#
# Starts a story-review-swarm round: snapshots the working tree, writes the
# diff the reviewers will read, and prints where it is. The changed text is
# never printed, so it stays out of the caller's context; only the files and
# the Markdown headings of the sections the change touches are.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: start-round.sh [--base <ref> | --since <round-dir>]

Run from inside the repository under review. Snapshots the working tree -
commits, staged and unstaged edits, and untracked files that are not ignored -
without touching the index, and writes the diff from the base to that snapshot
into a new round directory.

  --base <ref>         Diff from the merge base of <ref> and HEAD. Default:
                       the default branch (origin/HEAD, else main or master).
  --since <round-dir>  Diff from the snapshot an earlier round took, so a
                       re-review reads only what changed since that round.
                       The new round goes next to it.

Rounds go in $CLAUDE_JOB_DIR/tmp/story-review-swarm, or in a new temporary
directory when CLAUDE_JOB_DIR is not set.

Prints the round directory, the diff's path, a summary of the change, the
changed files with their status and lines added and removed ("M +3 -1"), and for each changed Markdown file the headings of the
sections the change touches: "## Name" for a section with changed lines,
"+ ## Name" and "- ## Name" for a heading added or removed. None of the
changed text itself is printed. Exits 3 when there is nothing to review.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/story-review-swarm/scripts/lib.sh
. "$script_dir/lib.sh"

base_ref=""
since=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      srs_need_value "$1" $#
      base_ref="$2"
      shift
      ;;
    --since)
      srs_need_value "$1" $#
      since="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) srs_die "unknown option: $1" 2 ;;
  esac
  shift
done

if [ -n "$base_ref" ] && [ -n "$since" ]; then
  srs_die "give --base or --since, not both" 2
fi
if [ -n "$since" ]; then
  srs_require_round "$since"
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  srs_die "not inside a git work tree"
fi
top="$(git rev-parse --show-toplevel)"

# The diff is read as a plain patch of the whole repository, so the user's
# diff settings - an external diff tool, colour, other path prefixes, diffs
# relative to the current directory - must not apply. Markdown files use
# git's built-in markdown driver, so each hunk header names the heading the
# hunk sits under, and file names keep their non-ASCII characters unquoted.
plain_diff() {
  git -c diff.relative=false -c core.attributesFile="$scratch/attributes" -c core.quotePath=false \
    diff --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ "$@"
}

# Prints the default branch: origin/HEAD, else main or master, else nothing.
# An origin/HEAD that points at a branch that no longer exists is skipped.
default_branch() {
  local ref origin_head
  origin_head="$(git symbolic-ref --short -q refs/remotes/origin/HEAD || true)"
  for ref in $origin_head main master origin/main origin/master; do
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
# Attribute patterns match by case, so spell out every case of the
# extensions the sections parser below accepts.
printf '*.[mM][dD] diff=markdown\n*.[mM][aA][rR][kK][dD][oO][wW][nN] diff=markdown\n' >"$scratch/attributes"
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
  base="$(srs_meta "$since" snapshot)"
  base_desc="snapshot of $(basename "$since")"
  if [ -z "$base" ] || ! git cat-file -e "$base^{tree}" 2>/dev/null; then
    srs_die "the snapshot of $since is not in this repository; start a fresh round instead"
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
    srs_die "unknown ref: $base_ref"
  elif ! base="$(git merge-base "$base_ref" HEAD)"; then
    srs_die "no common history between $base_ref and HEAD; pass --base <ref>"
  else
    base_desc="merge base of $base_ref and HEAD ($(git rev-parse --short "$base"))"
  fi
fi

if plain_diff --quiet "$base" "$snapshot"; then
  echo "nothing to review: no change from the $base_desc"
  exit 3
fi

if [ -n "$since" ]; then
  root="$(dirname "$since")"
elif [ -n "${CLAUDE_JOB_DIR:-}" ]; then
  root="$CLAUDE_JOB_DIR/tmp/story-review-swarm"
else
  root="$(mktemp -d "${TMPDIR:-/tmp}/story-review-swarm.XXXXXX")"
fi
mkdir -p "$root"
root="$(cd "$root" && pwd -P)"
n=1
while [ -e "$root/round-$n" ]; do
  n=$((n + 1))
done
round="$root/round-$n"
mkdir -p "$round/reports"

# Bible entries are long paragraphs and every reviewer reads the files whole,
# so the diff needs only a little context to place each change.
plain_diff -U5 --find-renames "$base" "$snapshot" >"$round/diff.patch"
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
echo "change:$(plain_diff --shortstat "$base" "$snapshot")"
echo "files:"
# Each file with its lines added and removed, so the caller can tell a small
# edit from new material without the diff. Both listings come from the same
# diff, so their lines pair up in order.
plain_diff --numstat --find-renames "$base" "$snapshot" >"$scratch/counts"
plain_diff --name-status --find-renames "$base" "$snapshot" >"$scratch/names"
awk -F'\t' '
  NR == FNR {
    count[FNR] = ($1 == "-") ? "binary" : "+" $1 " -" $2
    next
  }
  {
    status = $1
    sub(/^[^\t]*\t/, "")
    print status "\t" count[FNR] "\t" $0
  }
' "$scratch/counts" "$scratch/names" >"$scratch/files"
head -n 40 "$scratch/files" | sed 's/^/  /'
total="$(wc -l <"$scratch/files" | tr -d ' ')"
if [ "$total" -gt 40 ]; then
  echo "  ... and $((total - 40)) more"
fi

# Lists, for each changed Markdown file, the headings of the sections the
# change touches, so the caller can choose reviewers without reading the
# diff. With no context lines, git's built-in markdown driver names the
# heading each hunk sits under; headings that are themselves added or
# removed are marked "+" or "-". The "---" and "+++" lines are file names
# only in a file's header, before its first hunk: inside a hunk they are a
# removed "--" line or an added "++" one. Git ends a name that has a space
# with a tab, and wraps one with a quote or backslash in C-style quotes.
plain_diff -U0 --find-renames "$base" "$snapshot" |
  awk -v max_files=40 -v max_sections=10 '
    function path(s) {
      sub(/[ \t]+$/, "", s)
      if (s ~ /^".*"$/) {
        s = substr(s, 2, length(s) - 2)
        gsub(/\\"/, "\"", s)
        gsub(/\\\\/, "\\", s)
      }
      sub(/^[ab]\//, "", s)
      return s
    }
    function add(h) {
      sub(/[ \t]+$/, "", h)
      if (h == "" || (file, h) in seen) return
      seen[file, h] = 1
      if (!(file in count)) order[++files] = file
      list[file, ++count[file]] = h
    }
    /^diff --git / { header = 1; md = 0; next }
    header && /^--- / { old = path(substr($0, 5)); next }
    header && /^\+\+\+ / {
      file = path(substr($0, 5))
      if (file == "/dev/null") file = old
      md = (tolower(file) ~ /\.(md|markdown)$/)
      next
    }
    /^@@/ {
      header = 0
      if (!md) next
      h = $0
      sub(/^@@ [^@]* @@ ?/, "", h)
      add(h)
      next
    }
    !header && md && /^[-+] ? ? ?#+[ \t]/ {
      h = substr($0, 2)
      sub(/^ +/, "", h)
      add(substr($0, 1, 1) " " h)
    }
    END {
      if (files == 0) exit
      print "sections:"
      for (i = 1; i <= files && i <= max_files; i++) {
        f = order[i]
        line = ""
        for (j = 1; j <= count[f] && j <= max_sections; j++)
          line = line (j > 1 ? "; " : "") list[f, j]
        if (count[f] > max_sections) line = line "; ... and " (count[f] - max_sections) " more"
        print "  " f ": " line
      }
      if (files > max_files) print "  ... and " (files - max_files) " more files"
    }
  '

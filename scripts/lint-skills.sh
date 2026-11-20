#!/usr/bin/env bash
#
# Checks that every skill is well formed: a SKILL.md with frontmatter whose
# name matches its directory and which has a description, and scripts that
# exist and can be run.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lint-skills.sh [<skills-dir>]

Checks every directory in <skills-dir> (default: this repository's skills/):

  - it has a SKILL.md that starts with --- frontmatter
  - the frontmatter's name matches the directory, and it has a description
  - every ${CLAUDE_SKILL_DIR}/scripts/<file> that SKILL.md mentions exists
  - every file in scripts/ that starts with #! is executable

Exits 1 if anything is wrong.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skills_dir="${1:-$script_dir/../skills}"

problems=0
checked=0

problem() {
  echo "  $1"
  problems=$((problems + 1))
}

# Prints a frontmatter field's value from a SKILL.md, or nothing.
field() {
  awk -v key="$2" '
    NR == 1 { next }
    /^---[[:space:]]*$/ { exit }
    index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$1"
}

check_skill() {
  local dir="$1" name skill_md ref script
  name="$(basename "$dir")"
  skill_md="$dir/SKILL.md"
  checked=$((checked + 1))

  if [ ! -f "$skill_md" ]; then
    problem "$name: no SKILL.md"
    return 0
  fi
  if [ "$(head -n 1 "$skill_md")" != "---" ]; then
    problem "$name: SKILL.md does not start with --- frontmatter"
    return 0
  fi
  if [ "$(field "$skill_md" name)" != "$name" ]; then
    problem "$name: name is \"$(field "$skill_md" name)\", expected \"$name\""
  fi
  if [ -z "$(field "$skill_md" description)" ]; then
    problem "$name: no description"
  fi

  # Each reference, with any sentence punctuation after it dropped. The
  # pattern matches the literal text ${CLAUDE_SKILL_DIR}.
  # shellcheck disable=SC2016
  while IFS= read -r ref; do
    ref="${ref#\$\{CLAUDE_SKILL_DIR\}/}"
    if [ ! -f "$dir/$ref" ]; then
      problem "$name: refers to $ref, which does not exist"
    fi
  done < <(grep -o '\${CLAUDE_SKILL_DIR}/scripts/[A-Za-z0-9._/-]*[A-Za-z0-9_]' "$skill_md" | sort -u)

  for script in "$dir"/scripts/*; do
    if [ -f "$script" ] && [ "$(head -c 2 "$script")" = "#!" ] && [ ! -x "$script" ]; then
      problem "$name: scripts/$(basename "$script") is not executable"
    fi
  done
}

for dir in "$skills_dir"/*/; do
  if [ -d "$dir" ]; then
    check_skill "${dir%/}"
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "no skills found in $skills_dir" >&2
  exit 1
fi

echo "$checked skill(s) checked, $problems problem(s)"
if [ "$problems" -gt 0 ]; then
  exit 1
fi

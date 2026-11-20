#!/usr/bin/env bash
#
# Runs every tests/test_*.sh file, then checks line coverage of every script
# in scripts/ and skills/*/scripts/.
#
# Needs only bash and the standard Unix tools.
#
# Usage: tests/run.sh
#   COVERAGE_MIN=80   Minimum line coverage per script, in percent (default 80).

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
coverage_min="${COVERAGE_MIN:-80}"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
COV_TRACE="$scratch/trace"
export COV_TRACE
: >"$COV_TRACE"

failed_files=0
for test_file in "$repo_root"/tests/test_*.sh; do
  echo "== ${test_file#"$repo_root"/}"
  if ! bash "$test_file"; then
    failed_files=$((failed_files + 1))
  fi
  echo
done

# --- Coverage ----------------------------------------------------------------
#
# A line counts as executable when it holds a command. Blank lines, comments,
# here-document bodies, the inside of a single-quoted string that spans lines
# (such as an awk program), function headers, case patterns, lone opening and
# closing keywords, and the continuation lines of a command split with a
# backslash are left out.
# Trace lines name each script by its path within the repository (see
# tests/lib.sh), so a test may run a copy from a throwaway layout.

executable_lines() {
  awk -v q="'" '
    heredoc != "" { if ($0 == heredoc) heredoc = ""; next }
    quoted { if (index($0, q)) quoted = 0; next }
    continued { continued = ($0 ~ /\\$/); next }
    /<<-?.?[A-Z_]+.?$/ {
      word = $0
      sub(/.*<<-?/, "", word)
      gsub(/[^A-Z_]/, "", word)
      heredoc = word
      print NR
      next
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*(\{|\(|\}|fi|done|esac|else|then|do|;;)[[:space:]]*$/ { next }
    /^[a-z_]+\(\) \{$/ { next }
    /^[[:space:]]*[-*a-z|" ]+\)$/ { next }
    {
      line = $0
      if (substr(line, length(line)) == q && gsub(q, q, line) % 2 == 1) quoted = 1
      if ($0 ~ /\\$/) continued = 1
      print NR
    }
  ' "$1"
}

coverage_failed=0
for script in "$repo_root"/scripts/*.sh "$repo_root"/skills/*/scripts/*.sh; do
  [ -f "$script" ] || continue
  rel="${script#"$repo_root"/}"
  # comm needs both lists in the same text order, not numeric order.
  executable_lines "$script" | LC_ALL=C sort -u >"$scratch/executable"
  grep -F "COV:$rel:" "$COV_TRACE" |
    sed -E 's/^\++COV:[^:]*:([0-9]+): .*/\1/' |
    LC_ALL=C sort -u >"$scratch/executed"
  total="$(grep -c . "$scratch/executable")"
  if [ "$total" -eq 0 ]; then
    echo "coverage: $rel has no executable lines that the measure recognises"
    coverage_failed=1
    continue
  fi
  missed_lines="$(comm -23 "$scratch/executable" "$scratch/executed" | sort -n | tr '\n' ' ')"
  missed="$(echo "$missed_lines" | wc -w | tr -d ' ')"
  covered=$((total - missed))
  percent=$((covered * 100 / total))
  echo "coverage: $rel $covered/$total lines ($percent%)"
  if [ "$missed" -gt 0 ]; then
    echo "          not executed: $missed_lines"
  fi
  if [ "$percent" -lt "$coverage_min" ]; then
    echo "          below the minimum of $coverage_min%"
    coverage_failed=1
  fi
done

if [ "$failed_files" -gt 0 ]; then
  echo "$failed_files test file(s) failed"
  exit 1
fi
if [ "$coverage_failed" -ne 0 ]; then
  echo "coverage is below the minimum"
  exit 1
fi
echo "all tests passed"

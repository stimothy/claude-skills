#!/usr/bin/env bash
#
# Tests for scripts/lint-skills.sh, against throwaway skills directories.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lint="$cov_root/scripts/lint-skills.sh"
skills=""

# One valid skill with a script it refers to.
setup() {
  skills="$work/skills"
  mkdir -p "$skills/good/scripts"
  cat >"$skills/good/SKILL.md" <<'EOF'
---
name: good
description: A good skill.
---

Run `${CLAUDE_SKILL_DIR}/scripts/run.sh` to start.
EOF
  printf '#!/bin/sh\n' >"$skills/good/scripts/run.sh"
  chmod +x "$skills/good/scripts/run.sh"
}

test_lint_help() {
  run_script "$lint" --help
  assert_status 0
  assert_contains "$out" "Usage: scripts/lint-skills.sh"
}

test_lint_passes_a_valid_skill() {
  run_script "$lint" "$skills"
  assert_status 0
  assert_contains "$out" "1 skill(s) checked, 0 problem(s)"
}

test_lint_checks_the_repository_by_default() {
  run_script "$lint"
  assert_status 0
  assert_contains "$out" "problem(s)"
}

test_lint_fails_on_a_missing_skill_file() {
  mkdir "$skills/empty"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$out" "empty: no SKILL.md"
}

test_lint_fails_without_frontmatter() {
  mkdir "$skills/bare"
  printf 'Just text.\n' >"$skills/bare/SKILL.md"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$out" "bare: SKILL.md does not start with --- frontmatter"
}

test_lint_fails_on_a_name_that_differs_from_the_directory() {
  mkdir "$skills/one"
  printf -- '---\nname: two\ndescription: x\n---\n' >"$skills/one/SKILL.md"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$out" "one: name is \"two\", expected \"one\""
}

test_lint_fails_without_a_description() {
  mkdir "$skills/nodesc"
  printf -- '---\nname: nodesc\n---\n' >"$skills/nodesc/SKILL.md"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$out" "nodesc: no description"
}

test_lint_fails_on_a_missing_script() {
  # shellcheck disable=SC2016
  printf 'Also `${CLAUDE_SKILL_DIR}/scripts/gone.sh`.\n' >>"$skills/good/SKILL.md"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$out" "good: refers to scripts/gone.sh, which does not exist"
}

test_lint_fails_on_a_script_that_is_not_executable() {
  chmod -x "$skills/good/scripts/run.sh"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$out" "good: scripts/run.sh is not executable"
}

test_lint_allows_a_sourced_library_that_is_not_executable() {
  printf '# shellcheck shell=bash\n' >"$skills/good/scripts/lib.sh"
  run_script "$lint" "$skills"
  assert_status 0
}

test_lint_fails_without_skills() {
  rm -rf "$skills/good"
  run_script "$lint" "$skills"
  assert_status 1
  assert_contains "$err" "no skills found"
}

run_tests

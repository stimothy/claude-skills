#!/usr/bin/env bash
#
# Tests for scripts/install.sh. Each test builds a throwaway copy of the
# repository layout and a throwaway config directory, so nothing touches the
# real ~/.claude.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The tests choose the config directory themselves.
unset CLAUDE_CONFIG_DIR

fixture=""
config=""
dest=""
manifest=""

setup() {
  work="$(cd "$work" && pwd -P)"
  fixture="$work/_cov_"
  config="$work/config"
  dest="$config/skills"
  manifest="$dest/.claude-skills-manifest"
  mkdir -p "$fixture/scripts" "$fixture/skills/alpha/scripts" "$fixture/skills/beta"
  cp "$repo_root/scripts/install.sh" "$fixture/scripts/install.sh"
  printf 'alpha skill\n' >"$fixture/skills/alpha/SKILL.md"
  printf '#!/bin/sh\necho hi\n' >"$fixture/skills/alpha/scripts/hi.sh"
  chmod +x "$fixture/skills/alpha/scripts/hi.sh"
  printf 'beta skill\n' >"$fixture/skills/beta/SKILL.md"
}

run_install() {
  CLAUDE_CONFIG_DIR="$config" run_script "$fixture/scripts/install.sh" "$@"
}

assert_dir_copy() {
  if [ -L "$1" ] || [ ! -d "$1" ]; then
    fail "expected a regular directory at $1"
  fi
}

# --- Installing with symlinks ------------------------------------------------

test_link_install_links_each_skill_directory() {
  run_install
  assert_status 0
  assert_link_to "$dest/alpha" "$fixture/skills/alpha"
  assert_link_to "$dest/beta" "$fixture/skills/beta"
  assert_contains "$out" "linked   alpha"
  assert_contains "$out" "Installed 2, skipped 0."
}

test_scripts_run_through_the_link() {
  run_install
  assert_equals "$("$dest/alpha/scripts/hi.sh")" "hi"
}

test_link_install_is_idempotent() {
  run_install
  run_install
  assert_status 0
  assert_contains "$out" "ok       alpha (already linked)"
  assert_contains "$out" "Installed 0, skipped 0."
}

test_installs_into_home_when_config_dir_is_unset() {
  HOME="$work/home" run_script "$fixture/scripts/install.sh"
  assert_status 0
  assert_link_to "$work/home/.claude/skills/alpha" "$fixture/skills/alpha"
}

test_handles_a_skill_name_with_a_space() {
  mkdir "$fixture/skills/two words"
  printf 'x\n' >"$fixture/skills/two words/SKILL.md"
  run_install
  assert_status 0
  assert_link_to "$dest/two words" "$fixture/skills/two words"
}

test_ignores_entries_that_are_not_skills() {
  mkdir "$fixture/skills/notes"
  printf 'x\n' >"$fixture/skills/README.md"
  run_install
  assert_status 0
  assert_absent "$dest/notes"
  assert_absent "$dest/README.md"
}

# Claude may name a script by its path through the link or in the clone, so
# both need allowing. Each rule names one script exactly: a wildcard in the
# path would also allow anything reachable through it.
test_prints_exact_rules_to_allow_skill_scripts() {
  run_install
  assert_contains "$out" "\"Bash($dest/alpha/scripts/hi.sh *)\","
  assert_contains "$out" "\"Bash($fixture/skills/alpha/scripts/hi.sh *)\""
  assert_not_contains "$out" "/*/"
}

test_prints_the_rules_as_a_json_list() {
  mkdir -p "$fixture/skills/beta/scripts"
  printf '#!/bin/sh\n' >"$fixture/skills/beta/scripts/go.sh"
  chmod +x "$fixture/skills/beta/scripts/go.sh"
  run_install
  assert_equals "$(printf '%s\n' "$out" | tail -n 4)" "$(
    printf '  "Bash(%s *)",\n' "$dest/alpha/scripts/hi.sh" "$fixture/skills/alpha/scripts/hi.sh" "$dest/beta/scripts/go.sh"
    printf '  "Bash(%s *)"' "$fixture/skills/beta/scripts/go.sh"
  )"
}

test_rules_leave_out_a_skill_that_was_skipped() {
  mkdir -p "$dest/alpha"
  printf 'mine\n' >"$dest/alpha/SKILL.md"
  run_install
  assert_status 1
  assert_not_contains "$out" "alpha/scripts/hi.sh"
}

test_rules_leave_out_sourced_libraries() {
  printf '# shellcheck shell=bash\n' >"$fixture/skills/alpha/scripts/lib.sh"
  run_install
  assert_not_contains "$out" "lib.sh"
}

# --- Installing copies -------------------------------------------------------

test_copy_install_creates_directories() {
  run_install --copy
  assert_status 0
  assert_dir_copy "$dest/alpha"
  assert_content "$dest/alpha/SKILL.md" "alpha skill"
  assert_equals "$("$dest/alpha/scripts/hi.sh")" "hi"
  assert_contains "$out" "copied   alpha"
}

test_copy_install_is_idempotent() {
  run_install --copy
  run_install --copy
  assert_status 0
  assert_contains "$out" "ok       alpha (already up to date)"
}

test_switching_from_link_to_copy_and_back() {
  run_install
  run_install --copy
  assert_status 0
  assert_dir_copy "$dest/alpha"
  run_install
  assert_status 0
  assert_link_to "$dest/alpha" "$fixture/skills/alpha"
}

test_copy_is_updated_after_the_source_changes() {
  run_install --copy
  printf 'alpha v2\n' >"$fixture/skills/alpha/SKILL.md"
  run_install --copy
  assert_status 0
  assert_content "$dest/alpha/SKILL.md" "alpha v2"
}

test_copy_drops_files_removed_from_the_source() {
  run_install --copy
  rm "$fixture/skills/alpha/scripts/hi.sh"
  run_install --copy
  assert_status 0
  assert_absent "$dest/alpha/scripts/hi.sh"
}

test_copy_is_updated_when_only_a_mode_changes() {
  printf '#!/bin/sh\n' >"$fixture/skills/alpha/scripts/later.sh"
  run_install --copy
  chmod +x "$fixture/skills/alpha/scripts/later.sh"
  run_install --copy
  assert_status 0
  if [ ! -x "$dest/alpha/scripts/later.sh" ]; then
    fail "expected the copy of later.sh to be executable"
  fi
}

test_copy_is_uninstalled_after_the_source_changes() {
  run_install --copy
  printf 'alpha v2\n' >"$fixture/skills/alpha/SKILL.md"
  run_install --uninstall
  assert_status 0
  assert_absent "$dest/alpha"
}

test_edited_copy_is_not_overwritten() {
  run_install --copy
  printf 'my edit\n' >"$dest/alpha/SKILL.md"
  run_install --copy
  assert_status 1
  assert_content "$dest/alpha/SKILL.md" "my edit"
  assert_contains "$err" "skipped  alpha"
}

test_edited_copy_is_not_uninstalled() {
  run_install --copy
  printf 'extra\n' >"$dest/alpha/mine.txt"
  run_install --uninstall
  assert_status 1
  assert_file "$dest/alpha/mine.txt"
}

test_copy_with_an_added_symlink_is_not_uninstalled() {
  run_install --copy
  ln -s "$work/anywhere" "$dest/alpha/custom-link"
  run_install --uninstall
  assert_status 1
  assert_link_to "$dest/alpha/custom-link" "$work/anywhere"
}

test_force_replaces_an_edited_copy() {
  run_install --copy
  printf 'my edit\n' >"$dest/alpha/SKILL.md"
  run_install --copy --force
  assert_status 0
  assert_content "$dest/alpha/SKILL.md" "alpha skill"
}

# --- Things this script did not install --------------------------------------

test_foreign_directory_is_skipped_even_with_force() {
  mkdir -p "$dest/alpha"
  printf 'mine\n' >"$dest/alpha/SKILL.md"
  run_install --force
  assert_status 1
  assert_content "$dest/alpha/SKILL.md" "mine"
  assert_contains "$err" "a directory this script did not install exists"
}

test_foreign_file_is_skipped() {
  mkdir -p "$dest"
  printf 'mine\n' >"$dest/alpha"
  run_install
  assert_status 1
  assert_content "$dest/alpha" "mine"
  assert_contains "$err" "use --force to replace it"
}

test_force_replaces_a_foreign_file() {
  mkdir -p "$dest"
  printf 'mine\n' >"$dest/alpha"
  run_install --force
  assert_status 0
  assert_link_to "$dest/alpha" "$fixture/skills/alpha"
}

test_foreign_symlink_is_skipped() {
  mkdir -p "$dest" "$work/elsewhere"
  ln -s "$work/elsewhere" "$dest/alpha"
  run_install
  assert_status 1
  assert_link_to "$dest/alpha" "$work/elsewhere"
}

test_force_replaces_a_foreign_dangling_symlink() {
  mkdir -p "$dest"
  ln -s "$work/missing" "$dest/alpha"
  run_install --force
  assert_status 0
  assert_link_to "$dest/alpha" "$fixture/skills/alpha"
}

test_foreign_dangling_symlink_is_not_uninstalled() {
  mkdir -p "$dest"
  ln -s "$work/missing" "$dest/alpha"
  run_install --uninstall
  assert_status 1
  assert_link_to "$dest/alpha" "$work/missing"
}

test_own_dangling_symlink_is_repaired_after_the_repository_moves() {
  run_install
  mv "$fixture" "$work/moved"
  fixture="$work/moved"
  run_install
  assert_status 0
  assert_link_to "$dest/alpha" "$work/moved/skills/alpha"
}

# --- Skills removed from the repository --------------------------------------

test_install_removes_a_link_to_a_skill_that_was_removed() {
  run_install
  rm -rf "$fixture/skills/beta"
  run_install
  assert_status 0
  assert_absent "$dest/beta"
  assert_contains "$out" "removed  beta (no longer in this repository)"
  assert_not_contains "$(cat "$manifest")" "beta"
}

test_install_removes_a_copy_of_a_skill_that_was_renamed() {
  run_install --copy
  mv "$fixture/skills/beta" "$fixture/skills/gamma"
  run_install --copy
  assert_status 0
  assert_absent "$dest/beta"
  assert_dir_copy "$dest/gamma"
}

test_install_keeps_an_edited_copy_of_a_removed_skill() {
  run_install --copy
  printf 'mine\n' >"$dest/beta/SKILL.md"
  rm -rf "$fixture/skills/beta"
  run_install --copy
  assert_status 1
  assert_content "$dest/beta/SKILL.md" "mine"
  assert_contains "$err" "skipped  beta"
}

test_install_forgets_a_removed_skill_that_is_already_gone() {
  run_install
  rm -rf "$fixture/skills/beta"
  rm "$dest/beta"
  run_install
  assert_status 0
  assert_not_contains "$(cat "$manifest")" "beta"
}

test_uninstall_removes_a_skill_that_was_removed() {
  run_install
  rm -rf "$fixture/skills/beta"
  run_install --uninstall
  assert_status 0
  assert_absent "$dest/beta"
  assert_absent "$dest/alpha"
  assert_absent "$manifest"
  assert_contains "$out" "Removed 2, skipped 0."
}

# Another clone or worktree that lacks a skill must not treat the skill this
# clone installed as removed upstream.
test_another_clone_leaves_skills_it_does_not_have() {
  run_install
  local other="$work/other/_cov_"
  mkdir -p "$other/scripts" "$other/skills/alpha"
  cp "$repo_root/scripts/install.sh" "$other/scripts/install.sh"
  printf 'alpha skill\n' >"$other/skills/alpha/SKILL.md"
  CLAUDE_CONFIG_DIR="$config" run_script "$other/scripts/install.sh"
  assert_status 0
  assert_link_to "$dest/beta" "$fixture/skills/beta"
  CLAUDE_CONFIG_DIR="$config" run_script "$other/scripts/install.sh" --uninstall
  assert_link_to "$dest/beta" "$fixture/skills/beta"
}

# --- Uninstalling ------------------------------------------------------------

test_uninstall_removes_links() {
  run_install
  run_install --uninstall
  assert_status 0
  assert_absent "$dest/alpha"
  assert_absent "$dest/beta"
  assert_contains "$out" "Removed 2, skipped 0."
}

test_uninstall_removes_copies() {
  run_install --copy
  run_install --uninstall
  assert_status 0
  assert_absent "$dest/alpha"
}

test_uninstall_without_a_destination_directory() {
  run_install --uninstall
  assert_status 0
  assert_contains "$out" "Removed 0, skipped 0."
}

test_manifest_records_installs_and_is_removed_on_uninstall() {
  run_install
  assert_contains "$(cat "$manifest")" "alpha	link	$fixture/skills/alpha"
  run_install --uninstall
  assert_absent "$manifest"
}

test_manifest_entry_is_dropped_when_the_skill_is_already_gone() {
  run_install
  rm "$dest/alpha"
  run_install --uninstall
  assert_status 0
  assert_absent "$manifest"
}

test_install_without_a_manifest_is_still_recognised() {
  run_install --copy
  rm "$manifest"
  run_install --uninstall
  assert_status 0
  assert_absent "$dest/alpha"
}

# --- Usage -------------------------------------------------------------------

test_help_prints_usage() {
  run_install --help
  assert_status 0
  assert_contains "$out" "Usage: scripts/install.sh"
}

test_unknown_option_fails() {
  run_install --bogus
  assert_status 2
  assert_contains "$err" "Unknown option: --bogus"
}

test_fails_when_there_are_no_skills() {
  rm -rf "$fixture/skills/"*
  run_install
  assert_status 1
  assert_contains "$err" "No skills found"
}

run_tests

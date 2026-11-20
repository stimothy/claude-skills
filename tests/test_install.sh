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
# both need allowing.
test_prints_how_to_allow_skill_scripts() {
  run_install
  assert_contains "$out" "\"Bash($dest/*/scripts/*)\","
  assert_contains "$out" "\"Bash($fixture/skills/*/scripts/*)\""
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

#!/usr/bin/env bash
#
# Tests for the story-review-swarm skill's scripts. Each test builds a
# throwaway git repository holding a small story bible; nothing touches a
# real one.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

skill_scripts="$cov_root/skills/story-review-swarm/scripts"
start="$skill_scripts/start-round.sh"
add_context="$skill_scripts/add-context.sh"
briefs="$skill_scripts/briefs.sh"
save="$skill_scripts/save-report.sh"
collect="$skill_scripts/collect-reports.sh"

all_lenses="archivist heckler cartographer shrink dramaturg oathkeeper scholar librarian turing stylist stranger"

repo=""
rounds=""

git_q() {
  git -C "$repo" "$@" >/dev/null 2>&1
}

characters_v1() {
  printf '# Characters\n\n## Mara Venn\n\nAge 30.\nA ferrywoman.\n\n## Tomas\n\nAge 40.\n'
}

# A repository on main with one commit of a small bible. Rounds go where a
# background job's would, under $CLAUDE_JOB_DIR/tmp.
setup() {
  repo="$work/repo"
  export CLAUDE_JOB_DIR="$work/job"
  rounds="$work/job/tmp/story-review-swarm"
  mkdir -p "$repo/bible" "$repo/chapters"
  git_q init -q -b main
  git_q config user.email test@example.com
  git_q config user.name Test
  git_q config commit.gpgsign false
  characters_v1 >"$repo/bible/characters.md"
  printf '# Outline\n\n1. Mara crosses the river.\n' >"$repo/bible/outline.md"
  printf 'Chapter one.\n' >"$repo/chapters/01.md"
  git_q add -A
  git_q commit -q -m initial
}

# Runs a script from inside the test repository.
run_in_repo() {
  local dir="$repo"
  if [ "$1" = "--dir" ]; then
    dir="$2"
    shift 2
  fi
  local here="$PWD"
  cd "$dir" || return 1
  run_script "$@"
  cd "$here" || return 1
}

edit_mara_age() {
  characters_v1 | sed 's/Age 30./Age 34./' >"$repo/bible/characters.md"
}

# Starts a round with an uncommitted edit and sets round to its directory.
round=""
start_round_with_change() {
  edit_mara_age
  run_in_repo "$start"
  round="$rounds/round-1"
}

# Prints the brief under one reviewer's heading from briefs.sh output.
brief_for() {
  printf '%s\n' "$out" | awk -v h="=== story-review-$1 ===" '
    $0 == h { p = 1; next }
    /^=== story-review-/ { p = 0 }
    p
  '
}

# --- start-round.sh ----------------------------------------------------------

test_start_round_help() {
  run_script "$start" --help
  assert_status 0
  assert_contains "$out" "Usage: start-round.sh"
}

test_start_round_rejects_unknown_option() {
  run_in_repo "$start" --bogus
  assert_status 2
  assert_contains "$err" "unknown option: --bogus"
}

test_start_round_rejects_option_without_value() {
  run_in_repo "$start" --base
  assert_status 2
  assert_contains "$err" "--base needs a value"
}

test_start_round_rejects_base_with_since() {
  run_in_repo "$start" --base main --since "$work"
  assert_status 2
  assert_contains "$err" "not both"
}

test_start_round_fails_outside_a_repository() {
  mkdir "$work/plain"
  run_in_repo --dir "$work/plain" "$start"
  assert_status 1
  assert_contains "$err" "not inside a git work tree"
}

test_start_round_captures_uncommitted_and_untracked_work() {
  edit_mara_age
  printf '# Places\n\n## Harrow\n\nA town.\n' >"$repo/bible/places.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-1"
  assert_contains "$out" "diff: $rounds/round-1/diff.patch"
  assert_contains "$out" "2 files changed"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+Age 34."
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+A town."
}

# An edit that keeps the size and the timestamp git cached must still be
# seen: git rechecks such a file only when the index is no newer than it.
test_start_round_sees_a_same_size_edit_in_the_same_second() {
  git_q config core.trustctime false
  touch -t 202601010000 "$repo/bible/characters.md"
  git_q add -A
  git_q commit -q -m "pin time"
  touch -t 202601010000 "$repo/.git/index"
  edit_mara_age
  touch -t 202601010000 "$repo/bible/characters.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch" 2>/dev/null)" "+Age 34."
}

test_start_round_never_prints_the_changed_text() {
  edit_mara_age
  run_in_repo "$start"
  assert_status 0
  assert_not_contains "$out" "Age 34"
  assert_not_contains "$out" "ferrywoman"
}

test_start_round_leaves_the_index_alone() {
  edit_mara_age
  printf 'new\n' >"$repo/bible/new.md"
  local before after
  before="$(git -C "$repo" status --porcelain)"
  run_in_repo "$start"
  after="$(git -C "$repo" status --porcelain)"
  assert_status 0
  assert_equals "$after" "$before"
}

test_start_round_keeps_ignored_files_out() {
  printf 'scratch/\n' >"$repo/.gitignore"
  mkdir "$repo/scratch"
  printf 'private notes\n' >"$repo/scratch/notes.md"
  run_in_repo "$start"
  assert_status 0
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "private notes"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+scratch/"
}

# The diff must be a plain patch whatever the user's git config says.
test_start_round_writes_a_plain_patch_despite_git_config() {
  git_q config color.ui always
  git_q config diff.noprefix true
  git_q config diff.external false
  edit_mara_age
  run_in_repo "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "--- a/bible/characters.md"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+++ b/bible/characters.md"
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "$(printf '\033')"
  assert_not_contains "$out" "$(printf '\033')"
}

test_start_round_reviews_the_whole_repository_from_a_subdirectory() {
  git_q config diff.relative true
  edit_mara_age
  run_in_repo --dir "$repo/chapters" "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+++ b/bible/characters.md"
  assert_contains "$out" "bible/characters.md: ## Mara Venn"
}

test_start_round_includes_branch_commits_against_main() {
  git_q switch -q -c draft
  edit_mara_age
  git_q commit -q -am "older Mara"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of main and HEAD"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+Age 34."
}

test_start_round_diffs_from_the_merge_base_not_the_tip() {
  git_q switch -q -c draft
  edit_mara_age
  git_q commit -q -am "older Mara"
  git_q switch -q main
  printf 'theirs\n' >"$repo/bible/main-only.md"
  git_q add -A
  git_q commit -q -m "main moves on"
  git_q switch -q draft
  run_in_repo "$start"
  assert_status 0
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "main-only.md"
}

test_start_round_prefers_origin_head() {
  git_q update-ref refs/remotes/origin/main HEAD
  git_q symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git_q switch -q -c draft
  edit_mara_age
  git_q commit -q -am "older Mara"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of origin/main and HEAD"
}

test_start_round_skips_an_origin_head_that_points_nowhere() {
  git_q symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
  git_q switch -q -c draft
  edit_mara_age
  git_q commit -q -am "older Mara"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of main and HEAD"
}

test_start_round_falls_back_to_origin_main() {
  git_q update-ref refs/remotes/origin/main HEAD
  git_q branch -m draft
  edit_mara_age
  git_q commit -q -am "older Mara"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of origin/main and HEAD"
}

test_start_round_falls_back_to_master() {
  git_q branch -m master
  git_q switch -q -c draft
  edit_mara_age
  git_q commit -q -am "older Mara"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of master and HEAD"
}

test_start_round_uses_a_named_base() {
  edit_mara_age
  git_q commit -q -am "older Mara"
  printf 'Chapter one, revised.\n' >"$repo/chapters/01.md"
  git_q commit -q -am "revise"
  run_in_repo "$start" --base HEAD~1
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+Chapter one, revised."
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "+Age 34."
}

test_start_round_rejects_an_unknown_base() {
  edit_mara_age
  run_in_repo "$start" --base no-such-ref
  assert_status 1
  assert_contains "$err" "unknown ref: no-such-ref"
}

test_start_round_explains_a_base_with_no_common_history() {
  git_q switch -q --orphan other
  printf 'other\n' >"$repo/other.md"
  git_q add other.md
  git_q commit -q -m other
  git_q switch -q main
  edit_mara_age
  run_in_repo "$start" --base other
  assert_status 1
  assert_contains "$err" "no common history between other and HEAD"
}

test_start_round_falls_back_to_head_without_a_default_branch() {
  git_q branch -m trunk
  edit_mara_age
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "no default branch found"
}

test_start_round_handles_a_repository_without_commits() {
  rm -rf "$repo"
  mkdir -p "$repo"
  git_q init -q -b main
  printf '# Premise\n\nA ferry story.\n' >"$repo/premise.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "repository has no commits"
  assert_contains "$out" "premise.md: + # Premise"
}

test_start_round_reports_nothing_to_review() {
  run_in_repo "$start"
  assert_status 3
  assert_contains "$out" "nothing to review"
  assert_absent "$rounds/round-1"
}

test_start_round_numbers_rounds() {
  edit_mara_age
  run_in_repo "$start"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
}

test_start_round_falls_back_to_a_temporary_directory() {
  edit_mara_age
  mkdir -p "$work/tmpdir"
  CLAUDE_JOB_DIR="" TMPDIR="$work/tmpdir" run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $work/tmpdir/story-review-swarm."
}

test_start_round_lists_changed_files_and_truncates() {
  local i=1
  while [ "$i" -le 45 ]; do
    printf 'x\n' >"$repo/bible/note$i.txt"
    i=$((i + 1))
  done
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "bible/note1.txt"
  assert_contains "$out" "... and 5 more"
}

# The sections list says where in each Markdown file the change sits, by
# heading, without any of the changed text.
test_start_round_lists_the_sections_a_change_touches() {
  {
    characters_v1 | sed 's/Age 30./Age 34./'
    printf '\n## Ilse\n\nA smuggler.\n'
  } >"$repo/bible/characters.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "sections:"
  assert_contains "$out" "bible/characters.md: ## Mara Venn; ## Tomas; + ## Ilse"
  assert_not_contains "$out" "smuggler"
}

test_start_round_marks_removed_headings() {
  printf '# Characters\n\n## Mara Venn\n\nAge 30.\nA ferrywoman.\n' >"$repo/bible/characters.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "- ## Tomas"
}

test_start_round_names_a_deleted_file_in_sections() {
  rm "$repo/bible/outline.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "bible/outline.md: - # Outline"
}

# Git matches attribute patterns by case, so an uppercase extension must
# still get the markdown driver, or the section is named by a prose line.
# On a case-insensitive file system git sets core.ignoreCase and matches
# either way; turning it off gives the case-sensitive matching Linux has.
test_start_round_lists_sections_of_files_with_uppercase_extensions() {
  local ext
  git_q config core.ignoreCase false
  for ext in MD Markdown; do
    printf '# World\n\n## Magic\n\nBlood binds.\nIt costs.\n' >"$repo/bible/world.$ext"
  done
  git_q add -A
  git_q commit -q -m world
  for ext in MD Markdown; do
    printf '# World\n\n## Magic\n\nBlood binds.\nIt costs years.\n' >"$repo/bible/world.$ext"
  done
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "  bible/world.MD: ## Magic"
  assert_contains "$out" "  bible/world.Markdown: ## Magic"
  assert_not_contains "$out" "Blood binds"
}

test_start_round_lists_no_sections_for_files_that_are_not_markdown() {
  printf 'Notes\n' >"$repo/bible/notes.txt"
  run_in_repo "$start"
  assert_status 0
  assert_not_contains "$out" "sections:"
}

test_start_round_lists_sections_of_a_renamed_file_under_its_new_name() {
  git_q mv bible/characters.md bible/people.md
  characters_v1 | sed 's/Age 30./Age 34./' >"$repo/bible/people.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "bible/people.md: ## Mara Venn"
}

test_start_round_truncates_a_long_section_list() {
  local i=1
  {
    printf '# Places\n'
    while [ "$i" -le 15 ]; do
      printf '\n## Place %d\n\nText.\n' "$i"
      i=$((i + 1))
    done
  } >"$repo/bible/places.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "+ ## Place 9; ... and 6 more"
  assert_not_contains "$out" "Place 10"
}

test_start_round_caps_the_files_in_the_section_list() {
  local i=1
  while [ "$i" -le 45 ]; do
    printf '# Note %d\n' "$i" >"$repo/bible/note$i.md"
    i=$((i + 1))
  done
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "... and 5 more files"
  assert_equals "$(printf '%s\n' "$out" | sed -n '/^sections:/,$p' | grep -c ': + # Note')" "40"
}

# Git ends a name that has a space with a tab, and C-quotes one with a quote
# or backslash; non-ASCII names stay as they are.
test_start_round_names_awkward_files_exactly_in_sections() {
  printf '# Mara\n\nx\n' >"$repo/bible/Mara Venn.md"
  printf '# Café\n\nx\n' >"$repo/bible/Café.md"
  printf '# Quote\n\nx\n' >"$repo/bible/say \"hi\".md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "  bible/Mara Venn.md: + # Mara"
  assert_contains "$out" "  bible/Café.md: + # Café"
  assert_contains "$out" "  bible/say \"hi\".md: + # Quote"
}

# Inside a hunk, a removed "-- " line reads "--- " and an added "++ " line
# reads "+++ "; neither is a file header.
test_start_round_does_not_take_hunk_lines_for_file_headers() {
  printf '# Notes\n\n## Aside\n\n-- aside\n' >"$repo/bible/notes.md"
  git_q add -A
  git_q commit -q -m notes
  printf '# Notes\n\n## Aside\n\n++ x\n' >"$repo/bible/notes.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "  bible/notes.md: ## Aside"
  assert_not_contains "$out" "aside:"
  assert_not_contains "$out" "x:"
}

# Reviewers see the heading each hunk sits under in the diff itself.
test_start_round_names_headings_in_the_diff_hunks() {
  characters_v1 | sed 's/Age 40./Age 41./' >"$repo/bible/characters.md"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "@@ ## Mara Venn"
}

test_start_round_counts_lines_per_file() {
  edit_mara_age
  printf '# Places\n\n## Harrow\n\nA town.\n' >"$repo/bible/places.md"
  printf '\000\001' >"$repo/map.bin"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "$(printf '  M\t+1 -1\tbible/characters.md')"
  assert_contains "$out" "$(printf '  A\t+5 -0\tbible/places.md')"
  assert_contains "$out" "$(printf '  A\tbinary\tmap.bin')"
}

test_start_round_counts_a_renamed_file_under_both_names() {
  git_q mv bible/characters.md bible/people.md
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "$(printf '\t+0 -0\tbible/characters.md\tbible/people.md')"
}

test_start_round_since_reads_only_what_changed_after_that_round() {
  edit_mara_age
  run_in_repo "$start"
  printf 'Chapter one, revised.\n' >"$repo/chapters/01.md"
  run_in_repo "$start" --since "$rounds/round-1"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
  assert_contains "$out" "snapshot of round-1"
  assert_contains "$(cat "$rounds/round-2/diff.patch")" "+Chapter one, revised."
  assert_not_contains "$(cat "$rounds/round-2/diff.patch")" "+Age 34."
}

test_start_round_since_puts_the_new_round_next_to_the_old_one() {
  edit_mara_age
  run_in_repo "$start"
  printf 'Chapter one, revised.\n' >"$repo/chapters/01.md"
  CLAUDE_JOB_DIR="$work/other-job" run_in_repo "$start" --since "$rounds/round-1"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
  assert_absent "$work/other-job"
}

test_start_round_since_with_no_new_change_has_nothing_to_review() {
  edit_mara_age
  run_in_repo "$start"
  run_in_repo "$start" --since "$rounds/round-1"
  assert_status 3
  assert_contains "$out" "nothing to review"
}

test_start_round_since_rejects_a_snapshot_from_another_repository() {
  edit_mara_age
  run_in_repo "$start"
  awk -F'\t' -v OFS='\t' '$1 == "snapshot" { $2 = "0123456789abcdef0123456789abcdef01234567" } 1' \
    "$rounds/round-1/meta" >"$work/meta" && mv "$work/meta" "$rounds/round-1/meta"
  run_in_repo "$start" --since "$rounds/round-1"
  assert_status 1
  assert_contains "$err" "is not in this repository"
  assert_absent "$rounds/round-2"
}

test_start_round_since_rejects_a_directory_that_is_not_a_round() {
  run_in_repo "$start" --since "$work"
  assert_status 2
  assert_contains "$err" "not a round directory"
}

# --- add-context.sh ----------------------------------------------------------

test_add_context_help() {
  run_script "$add_context" --help
  assert_status 0
  assert_contains "$out" "Usage: add-context.sh"
}

test_add_context_rejects_a_missing_round() {
  run_script "$add_context" "$work/none" --note x
  assert_status 2
  assert_contains "$err" "not a round directory"
}

test_add_context_needs_a_round_argument() {
  run_script "$add_context"
  assert_status 2
  assert_contains "$err" "missing round directory"
}

test_add_context_needs_a_source() {
  start_round_with_change
  run_script "$add_context" "$round"
  assert_status 2
  assert_contains "$err" "no sources given"
  assert_absent "$round/context.md"
}

test_add_context_rejects_unknown_option() {
  start_round_with_change
  run_script "$add_context" "$round" --issue 4
  assert_status 2
  assert_contains "$err" "unknown option: --issue"
}

test_add_context_rejects_option_without_value() {
  start_round_with_change
  run_script "$add_context" "$round" --note
  assert_status 2
  assert_contains "$err" "--note needs a value"
}

test_add_context_writes_a_note_from_stdin() {
  start_round_with_change
  printf 'Mara is older now on purpose.\n' >"$work/note"
  run_script "$add_context" "$round" --note - <"$work/note"
  assert_status 0
  assert_contains "$out" "context: $round/context.md (1 source(s) added"
  assert_contains "$(cat "$round/context.md")" "# What the author says about this change"
  assert_contains "$(cat "$round/context.md")" "## Note from the author"
  assert_contains "$(cat "$round/context.md")" "Mara is older now on purpose."
}

test_add_context_writes_an_inline_note() {
  start_round_with_change
  run_script "$add_context" "$round" --note "Retcon of Mara's age."
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "Retcon of Mara's age."
}

test_add_context_includes_a_file() {
  start_round_with_change
  printf 'Plan: age everyone up.\n' >"$work/plan.md"
  run_script "$add_context" "$round" --file "$work/plan.md"
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "## From $work/plan.md"
  assert_contains "$(cat "$round/context.md")" "Plan: age everyone up."
}

test_add_context_fails_on_a_missing_file_and_writes_nothing() {
  start_round_with_change
  run_script "$add_context" "$round" --note "kept?" --file "$work/none.md"
  assert_status 1
  assert_contains "$err" "no such file: $work/none.md"
  assert_absent "$round/context.md"
}

test_add_context_appends_across_calls() {
  start_round_with_change
  run_script "$add_context" "$round" --note first
  run_script "$add_context" "$round" --note second
  assert_status 0
  assert_equals "$(grep -c '^# What the author says' "$round/context.md")" "1"
  assert_contains "$(cat "$round/context.md")" "first"
  assert_contains "$(cat "$round/context.md")" "second"
}

# --- briefs.sh ---------------------------------------------------------------

test_briefs_help() {
  run_script "$briefs" --help
  assert_status 0
  assert_contains "$out" "Usage: briefs.sh"
}

test_briefs_rejects_a_missing_round() {
  run_script "$briefs" "$work/none" --lenses archivist
  assert_status 2
  assert_contains "$err" "not a round directory"
}

test_briefs_need_lenses() {
  start_round_with_change
  run_script "$briefs" "$round"
  assert_status 2
  assert_contains "$err" "--lenses"
}

test_briefs_reject_an_unknown_lens() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist,sleuth
  assert_status 2
  assert_contains "$err" "unknown reviewer: sleuth"
  assert_absent "$round/lenses"
}

test_briefs_reject_unknown_option() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist --bogus
  assert_status 2
  assert_contains "$err" "unknown option: --bogus"
}

test_briefs_reject_option_without_value() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses
  assert_status 2
  assert_contains "$err" "--lenses needs a value"
}

test_briefs_write_one_brief_per_chosen_lens_in_roster_order() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses "shrink, archivist heckler,archivist"
  assert_status 0
  assert_contains "$(brief_for archivist)" "$save $round archivist <<'END_OF_REPORT_"
  assert_contains "$(brief_for heckler)" "$save $round heckler <<'END_OF_REPORT_"
  assert_contains "$(brief_for shrink)" "$round/diff.patch"
  assert_not_contains "$out" "=== story-review-librarian ==="
  assert_equals "$(printf '%s\n' "$out" | grep '^=== ' | tr '\n' ' ')" "=== story-review-archivist === === story-review-heckler === === story-review-shrink === "
  assert_equals "$(tr '\n' ' ' <"$round/lenses")" "archivist heckler shrink "
}

test_briefs_all_means_every_lens() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses all --cold chapters/01.md
  assert_status 0
  local lens
  for lens in $all_lenses; do
    assert_contains "$out" "=== story-review-$lens ==="
  done
}

test_briefs_say_the_files_show_the_new_side() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist
  assert_status 0
  assert_contains "$(brief_for archivist)" "the files on disk show the diff's new side"
  assert_contains "$(brief_for archivist)" "merge base of main and HEAD"
  assert_contains "$(brief_for archivist)" "Paths in the diff are relative to $repo."
}

test_briefs_leave_out_context_when_there_is_none() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist
  assert_status 0
  assert_not_contains "$(brief_for archivist)" "context.md"
}

test_briefs_point_at_context_when_there_is_some() {
  start_round_with_change
  run_script "$add_context" "$round" --note "On purpose."
  run_script "$briefs" "$round" --lenses archivist
  assert_status 0
  assert_contains "$(brief_for archivist)" "Read $round/context.md for what the author says about this change."
}

# A fixed delimiter could be ended early by a line quoted from the bible.
test_briefs_use_an_unguessable_delimiter_that_opens_and_closes() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist,heckler
  local brief delim
  brief="$(brief_for archivist)"
  delim="$(printf '%s\n' "$brief" | sed -n "s/.*<<'\(END_OF_REPORT_[0-9a-f]\{16\}\)'.*/\1/p")"
  if [ -z "$delim" ]; then
    fail "no random delimiter in: $brief"
  fi
  assert_contains "$brief" "$(printf '\n%s\n' "$delim")"
  if [ "$(brief_for heckler | grep -c "$delim")" != "0" ]; then
    fail "expected each brief to get its own delimiter"
  fi
}

test_briefs_quote_paths_with_spaces() {
  export CLAUDE_JOB_DIR="$work/job with space"
  rounds="$CLAUDE_JOB_DIR/tmp/story-review-swarm"
  start_round_with_change
  ln -s "$skill_scripts" "$work/skill dir"
  run_script "$work/skill dir/briefs.sh" "$round" --lenses archivist
  assert_status 0
  assert_contains "$(brief_for archivist)" "skill\\ dir/save-report.sh"
  assert_contains "$(brief_for archivist)" "job\\ with\\ space/tmp/story-review-swarm/round-1 archivist"
}

test_briefs_give_the_stranger_only_its_files() {
  start_round_with_change
  run_script "$add_context" "$round" --note "Mara is older now."
  printf 'Chapter two.\n' >"$repo/chapters/02.md"
  run_in_repo "$briefs" "$round" --lenses stranger,archivist --cold bible/outline.md --cold "$repo/chapters/02.md"
  assert_status 0
  local brief
  brief="$(brief_for stranger)"
  assert_contains "$brief" "Read these files, in this order:"
  assert_contains "$brief" "$(printf -- '- %s\n- %s' "$repo/bible/outline.md" "$repo/chapters/02.md")"
  assert_contains "$brief" "$save $round stranger <<'END_OF_REPORT_"
  assert_not_contains "$brief" "diff.patch"
  assert_not_contains "$brief" "context.md"
  assert_not_contains "$brief" "Mara"
  assert_not_contains "$brief" "story bible"
}

# Relative paths are taken from the repository's top, as start-round.sh
# lists them, wherever the caller runs from.
test_briefs_resolve_cold_files_from_the_repository_top() {
  start_round_with_change
  run_in_repo --dir "$repo/chapters" "$briefs" "$round" --lenses stranger --cold chapters/01.md
  assert_status 0
  assert_contains "$(brief_for stranger)" "- $repo/chapters/01.md"
}

test_briefs_need_cold_files_for_the_stranger() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses stranger
  assert_status 2
  assert_contains "$err" "--cold"
  assert_absent "$round/lenses"
}

test_briefs_reject_cold_files_without_the_stranger() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist --cold chapters/01.md
  assert_status 2
  assert_contains "$err" "--cold is only for stranger"
}

test_briefs_reject_a_missing_cold_file() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses stranger --cold chapters/99.md
  assert_status 2
  assert_contains "$err" "no such file: chapters/99.md"
}

test_briefs_give_the_oathkeeper_the_intent() {
  start_round_with_change
  printf '# Premise\n' >"$repo/premise.md"
  run_in_repo "$briefs" "$round" --lenses oathkeeper,archivist --intent premise.md
  assert_status 0
  assert_contains "$(brief_for oathkeeper)" "The author's statement of intent is in $repo/premise.md."
  assert_not_contains "$(brief_for archivist)" "statement of intent"
}

test_briefs_reject_intent_without_the_oathkeeper() {
  start_round_with_change
  printf '# Premise\n' >"$repo/premise.md"
  run_in_repo "$briefs" "$round" --lenses archivist --intent premise.md
  assert_status 2
  assert_contains "$err" "--intent is only for oathkeeper"
}

test_briefs_reject_a_missing_intent_file() {
  start_round_with_change
  run_in_repo "$briefs" "$round" --lenses oathkeeper --intent premise.md
  assert_status 2
  assert_contains "$err" "no such file: premise.md"
}

test_briefs_replace_an_earlier_choice_of_lenses() {
  start_round_with_change
  run_script "$briefs" "$round" --lenses archivist,heckler
  run_script "$briefs" "$round" --lenses librarian
  assert_status 0
  assert_content "$round/lenses" "librarian"
}

# --- save-report.sh ----------------------------------------------------------

sample_report() {
  cat <<'EOF'
Reviewed round-1 diff, 1 file.

### Mara's age disagrees with the timeline
- Locations:
  - bible/characters.md:5 (Mara Venn): "Age 34."
- Severity: high
- Confidence: high

### Tomas spelled two ways
- Severity: low
- Confidence: medium
EOF
}

test_save_report_help() {
  run_script "$save" --help
  assert_status 0
  assert_contains "$out" "Usage: save-report.sh"
}

test_save_report_needs_two_arguments() {
  start_round_with_change
  run_script "$save" "$round" </dev/null
  assert_status 2
  assert_contains "$err" "missing reviewer name"
}

test_save_report_rejects_the_full_agent_name() {
  start_round_with_change
  run_script "$save" "$round" story-review-archivist </dev/null
  assert_status 2
  assert_contains "$err" "unknown reviewer: story-review-archivist"
}

test_save_report_rejects_several_names_in_one() {
  start_round_with_change
  run_script "$save" "$round" "archivist heckler" </dev/null
  assert_status 2
  assert_contains "$err" "unknown reviewer: archivist heckler"
}

test_save_report_saves_stdin_and_counts_findings() {
  start_round_with_change
  sample_report >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  assert_status 0
  assert_contains "$out" "saved story-review-archivist: 2 findings (critical 0, high 1, medium 0, low 1)"
  assert_contains "$(cat "$round/reports/archivist.md")" "### Mara's age"
}

# Counts ignore case and decoration, and a quoted format line is not a
# finding.
test_save_report_counts_every_severity() {
  start_round_with_change
  cat >"$work/report.md" <<'EOF'
- Severity: critical | high | medium | low
- Severity: high | medium | low
- Severity: Critical
- Severity: **high**
- Severity: medium (was low)
- Severity: low
EOF
  run_script "$save" "$round" turing <"$work/report.md"
  assert_status 0
  assert_contains "$out" "4 findings (critical 1, high 1, medium 1, low 1)"
}

test_save_report_replaces_an_earlier_report() {
  start_round_with_change
  printf 'first\n' >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  printf 'second\n' >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  assert_status 0
  assert_content "$round/reports/archivist.md" "second"
}

test_save_report_rejects_an_empty_report() {
  start_round_with_change
  printf '  \n\n' >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  assert_status 1
  assert_contains "$err" "empty report"
  assert_equals "$(ls "$round/reports")" ""
}

# --- collect-reports.sh ------------------------------------------------------

choose() {
  run_script "$briefs" "$round" --lenses "$1"
}

test_collect_help() {
  run_script "$collect" --help
  assert_status 0
  assert_contains "$out" "Usage: collect-reports.sh"
}

test_collect_rejects_unknown_option() {
  start_round_with_change
  choose archivist
  run_script "$collect" "$round" --bogus
  assert_status 2
  assert_contains "$err" "unknown option: --bogus"
}

test_collect_rejects_a_missing_round() {
  run_script "$collect" "$work/none"
  assert_status 2
  assert_contains "$err" "not a round directory"
}

test_collect_needs_briefs_first() {
  start_round_with_change
  run_script "$collect" "$round"
  assert_status 2
  assert_contains "$err" "briefs.sh"
}

test_collect_waits_only_for_the_chosen_lenses() {
  start_round_with_change
  choose archivist,heckler,shrink
  sample_report >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  run_script "$collect" "$round"
  assert_status 3
  assert_equals "$out" "waiting on: heckler shrink"
}

test_collect_prints_everything_once_the_chosen_are_in() {
  start_round_with_change
  choose archivist,librarian
  sample_report >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  printf 'Reviewed it.\n\nNo working-document findings.\n- Severity: medium\n' >"$work/report.md"
  run_script "$save" "$round" librarian <"$work/report.md"
  # A report from a lens not chosen for this round is left out.
  run_script "$save" "$round" turing <"$work/report.md"
  run_script "$collect" "$round"
  assert_status 0
  assert_contains "$out" "2 of 2 reports"
  assert_contains "$out" "| story-review-archivist | 2 | 0 | 1 | 0 | 1 |"
  assert_contains "$out" "| story-review-librarian | 1 | 0 | 0 | 1 | 0 |"
  assert_contains "$out" "| total | 3 | 0 | 1 | 1 | 1 |"
  assert_contains "$out" "## story-review-archivist"
  assert_contains "$out" "### Mara's age disagrees with the timeline"
  assert_not_contains "$out" "turing"
}

test_collect_partial_prints_what_is_there() {
  start_round_with_change
  choose archivist,heckler
  sample_report >"$work/report.md"
  run_script "$save" "$round" archivist <"$work/report.md"
  run_script "$collect" "$round" --partial
  assert_status 0
  assert_contains "$out" "1 of 2 reports"
  assert_contains "$out" "| story-review-heckler | missing |"
  assert_contains "$out" "### Mara's age"
}

run_tests

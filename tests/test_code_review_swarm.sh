#!/usr/bin/env bash
#
# Tests for the code-review-swarm skill's scripts. Each test builds a
# throwaway git repository; nothing touches a real one.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

skill_scripts="$cov_root/skills/code-review-swarm/scripts"
start="$skill_scripts/start-round.sh"
add_context="$skill_scripts/add-context.sh"
briefs="$skill_scripts/briefs.sh"
save="$skill_scripts/save-report.sh"
collect="$skill_scripts/collect-reports.sh"

lenses="sleuth pedant advocate doubter locksmith minimalist skeptic"

repo=""
rounds=""

git_q() {
  git -C "$repo" "$@" >/dev/null 2>&1
}

# A repository on main with one commit. Rounds go where a background job's
# would, under $CLAUDE_JOB_DIR/tmp.
setup() {
  repo="$work/repo"
  export CLAUDE_JOB_DIR="$work/job"
  rounds="$work/job/tmp/code-review-swarm"
  mkdir -p "$repo"
  git_q init -q -b main
  git_q config user.email test@example.com
  git_q config user.name Test
  git_q config commit.gpgsign false
  printf 'one\ntwo\nthree\n' >"$repo/app.txt"
  git_q add app.txt
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

# Starts a round with uncommitted work and sets round to its directory.
round=""
start_round_with_change() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  round="$rounds/round-1"
}

with_context() {
  start_round_with_change
  run_script "$add_context" "$round" --note "Make two loud." </dev/null
}

# Prints the brief under one reviewer's heading from briefs.sh output.
brief_for() {
  printf '%s\n' "$out" | awk -v h="=== code-review-$1 ===" '
    $0 == h { p = 1; next }
    /^=== code-review-/ { p = 0 }
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
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  printf 'new file\n' >"$repo/new.txt"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-1"
  assert_contains "$out" "diff: $rounds/round-1/diff.patch"
  assert_contains "$out" "2 files changed"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+TWO"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+new file"
}

# An edit that keeps the size and the timestamp git cached must still be
# seen: git rechecks such a file only when the index is no newer than it.
# Ignoring ctime, which touch cannot set, keeps the race independent of the
# wall clock.
test_start_round_sees_a_same_size_edit_in_the_same_second() {
  git_q config core.trustctime false
  touch -t 202601010000 "$repo/app.txt"
  git_q add app.txt
  git_q commit -q -m "pin time"
  touch -t 202601010000 "$repo/.git/index"
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  touch -t 202601010000 "$repo/app.txt"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch" 2>/dev/null)" "+TWO"
}

test_start_round_never_prints_the_diff() {
  printf 'one\nSECRET-LINE\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  assert_status 0
  assert_not_contains "$out" "SECRET-LINE"
}

test_start_round_leaves_the_index_alone() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  printf 'new file\n' >"$repo/new.txt"
  local before after
  before="$(git -C "$repo" status --porcelain)"
  run_in_repo "$start"
  after="$(git -C "$repo" status --porcelain)"
  assert_status 0
  assert_equals "$after" "$before"
}

test_start_round_keeps_ignored_files_out() {
  printf 'build/\n' >"$repo/.gitignore"
  mkdir "$repo/build"
  printf 'artifact\n' >"$repo/build/out.bin"
  run_in_repo "$start"
  assert_status 0
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "artifact"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+build/"
}

# The diff must be a plain patch whatever the user's git config says.
test_start_round_writes_a_plain_patch_despite_git_config() {
  git_q config color.ui always
  git_q config diff.noprefix true
  git_q config diff.external false
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "--- a/app.txt"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+++ b/app.txt"
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "$(printf '\033')"
}

# Run from a subdirectory with diff.relative set, git would leave out changes
# elsewhere in the repository.
test_start_round_reviews_the_whole_repository_from_a_subdirectory() {
  git_q config diff.relative true
  mkdir "$repo/sub"
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo --dir "$repo/sub" "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+++ b/app.txt"
  assert_contains "$out" "app.txt"
}

test_start_round_includes_branch_commits_against_main() {
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of main and HEAD"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+four"
}

# Work that landed on main after the branch forked is not part of the change.
test_start_round_diffs_from_the_merge_base_not_the_tip() {
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  git_q switch -q main
  printf 'theirs\n' >"$repo/main-only.txt"
  git_q add main-only.txt
  git_q commit -q -m "main moves on"
  git_q switch -q feature
  run_in_repo "$start"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+four"
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "main-only.txt"
  assert_contains "$(cat "$rounds/round-1/meta")" "$(git -C "$repo" merge-base main feature)"
}

test_start_round_prefers_origin_head() {
  git_q update-ref refs/remotes/origin/main HEAD
  git_q symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of origin/main and HEAD"
}

test_start_round_skips_an_origin_head_that_points_nowhere() {
  git_q symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of main and HEAD"
}

test_start_round_falls_back_to_master() {
  git_q branch -m master
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of master and HEAD"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+four"
}

test_start_round_falls_back_to_origin_main() {
  git_q update-ref refs/remotes/origin/main HEAD
  git_q branch -m feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "merge base of origin/main and HEAD"
}

test_start_round_uses_a_named_base() {
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  printf 'one\ntwo\nthree\nfour\nfive\n' >"$repo/app.txt"
  git_q commit -q -am "add five"
  run_in_repo "$start" --base HEAD~1
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+five"
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "+four"
}

test_start_round_rejects_an_unknown_base() {
  printf 'changed\n' >"$repo/app.txt"
  run_in_repo "$start" --base no-such-ref
  assert_status 1
  assert_contains "$err" "unknown ref: no-such-ref"
}

test_start_round_explains_a_base_with_no_common_history() {
  git_q switch -q --orphan pages
  printf 'page\n' >"$repo/page.txt"
  git_q add page.txt
  git_q commit -q -m pages
  git_q switch -q main
  printf 'changed\n' >"$repo/app.txt"
  run_in_repo "$start" --base pages
  assert_status 1
  assert_contains "$err" "no common history between pages and HEAD"
}

test_start_round_falls_back_to_head_without_a_default_branch() {
  git_q branch -m trunk
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "no default branch found"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+TWO"
}

test_start_round_handles_a_repository_without_commits() {
  rm -rf "$repo"
  mkdir -p "$repo"
  git_q init -q -b main
  printf 'first\n' >"$repo/first.txt"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "repository has no commits"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+first"
}

test_start_round_reports_nothing_to_review() {
  run_in_repo "$start"
  assert_status 3
  assert_contains "$out" "nothing to review"
  assert_absent "$rounds/round-1"
}

test_start_round_numbers_rounds() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
}

test_start_round_falls_back_to_a_temporary_directory() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  mkdir -p "$work/tmpdir"
  CLAUDE_JOB_DIR="" TMPDIR="$work/tmpdir" run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $work/tmpdir/code-review-swarm."
}

test_start_round_lists_changed_files_and_truncates() {
  local i=1
  while [ "$i" -le 45 ]; do
    printf 'x\n' >"$repo/file$i.txt"
    i=$((i + 1))
  done
  run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "file1.txt"
  assert_contains "$out" "... and 5 more"
}

test_start_round_since_reads_only_what_changed_after_that_round() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  printf 'one\nTWO\nTHREE\n' >"$repo/app.txt"
  run_in_repo "$start" --since "$rounds/round-1"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
  assert_contains "$out" "snapshot of round-1"
  assert_contains "$(cat "$rounds/round-2/diff.patch")" "+THREE"
  assert_not_contains "$(cat "$rounds/round-2/diff.patch")" "+TWO"
}

test_start_round_since_puts_the_new_round_next_to_the_old_one() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  printf 'one\nTWO\nTHREE\n' >"$repo/app.txt"
  CLAUDE_JOB_DIR="$work/other-job" run_in_repo "$start" --since "$rounds/round-1"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
  assert_absent "$work/other-job"
}

test_start_round_since_with_no_new_change_has_nothing_to_review() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start"
  run_in_repo "$start" --since "$rounds/round-1"
  assert_status 3
  assert_contains "$out" "nothing to review"
  assert_absent "$rounds/round-2"
}

test_start_round_since_rejects_a_directory_that_is_not_a_round() {
  run_in_repo "$start" --since "$work"
  assert_status 2
  assert_contains "$err" "not a round directory"
}

# --- add-context.sh ----------------------------------------------------------

# A stand-in for the GitHub CLI that logs its arguments and answers "view"
# with canned JSON, run through the --jq program it was given, as gh does.
make_gh_stub() {
  cat >"$work/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [ -n "${GH_FAIL:-}" ]; then
  echo "gh: not found" >&2
  exit 1
fi
program=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--jq" ]; then
    program="$2"
  fi
  shift
done
printf '%s' "$GH_JSON" | jq -r "$program"
EOF
  chmod +x "$work/gh"
  export GH="$work/gh" GH_LOG="$work/gh.log"
  export GH_JSON='{"title":"Shout line two","url":"https://example.com/42","body":"Make it loud."}'
}

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
}

test_add_context_rejects_unknown_option() {
  start_round_with_change
  run_script "$add_context" "$round" --bogus
  assert_status 2
  assert_contains "$err" "unknown option: --bogus"
}

test_add_context_rejects_option_without_value() {
  start_round_with_change
  run_script "$add_context" "$round" --file
  assert_status 2
  assert_contains "$err" "--file needs a value"
}

test_add_context_writes_a_note_from_stdin() {
  start_round_with_change
  run_script "$add_context" "$round" --note - <<'EOF'
Make the second line loud.
EOF
  assert_status 0
  assert_contains "$out" "context: $round/context.md"
  assert_contains "$(cat "$round/context.md")" "# What this change is for"
  assert_contains "$(cat "$round/context.md")" "Make the second line loud."
}

test_add_context_writes_an_inline_note() {
  start_round_with_change
  run_script "$add_context" "$round" --note "Inline intent."
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "Inline intent."
}

test_add_context_includes_a_file() {
  start_round_with_change
  printf 'Spec: lines must shout.\n' >"$work/spec.md"
  run_script "$add_context" "$round" --file "$work/spec.md"
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "## From $work/spec.md"
  assert_contains "$(cat "$round/context.md")" "Spec: lines must shout."
}

test_add_context_fails_on_a_missing_file_and_writes_nothing() {
  start_round_with_change
  run_script "$add_context" "$round" --note "kept out" --file "$work/missing.md"
  assert_status 1
  assert_contains "$err" "no such file: $work/missing.md"
  assert_absent "$round/context.md"
}

test_add_context_pulls_an_issue() {
  if ! command -v jq >/dev/null; then
    echo "        (skipped: jq not installed)"
    return 0
  fi
  start_round_with_change
  make_gh_stub
  run_script "$add_context" "$round" --issue 42
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "$(printf '## Issue: Shout line two\nhttps://example.com/42\n\nMake it loud.')"
  assert_contains "$(cat "$GH_LOG")" "issue view 42 --json title,url,body --jq"
}

test_add_context_pulls_a_pull_request() {
  if ! command -v jq >/dev/null; then
    echo "        (skipped: jq not installed)"
    return 0
  fi
  start_round_with_change
  make_gh_stub
  run_script "$add_context" "$round" --pr 7
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "## Pull request: Shout line two"
  assert_contains "$(cat "$GH_LOG")" "pr view 7 --json title,url,body --jq"
}

test_add_context_reports_a_failing_gh_and_writes_nothing() {
  start_round_with_change
  make_gh_stub
  GH_FAIL=1 run_script "$add_context" "$round" --issue 42
  assert_status 1
  assert_contains "$err" "could not read issue 42"
  assert_absent "$round/context.md"
}

test_add_context_reports_a_missing_gh() {
  start_round_with_change
  GH="$work/no-such-gh" run_script "$add_context" "$round" --pr 7
  assert_status 1
  assert_contains "$err" "GitHub CLI not found"
}

test_add_context_keeps_sources_in_the_order_given() {
  start_round_with_change
  run_script "$add_context" "$round" --note "First." --note "Second."
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "$(printf 'First.\n\n## Note from the caller\n\nSecond.')"
}

test_add_context_appends_across_calls() {
  start_round_with_change
  run_script "$add_context" "$round" --note "First."
  run_script "$add_context" "$round" --note "Second."
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "First."
  assert_contains "$(cat "$round/context.md")" "Second."
  assert_equals "$(grep -c '^# What this change is for' "$round/context.md")" "1"
}

# --- briefs.sh ---------------------------------------------------------------

test_briefs_help() {
  run_script "$briefs" --help
  assert_status 0
  assert_contains "$out" "Usage: briefs.sh"
}

test_briefs_needs_context_first() {
  start_round_with_change
  run_script "$briefs" "$round"
  assert_status 2
  assert_contains "$err" "add-context.sh"
}

test_briefs_rejects_extra_arguments() {
  with_context
  run_script "$briefs" "$round" sleuth
  assert_status 2
  assert_contains "$err" "unexpected argument: sleuth"
}

test_briefs_rejects_a_missing_round() {
  run_script "$briefs" "$work/none"
  assert_status 2
  assert_contains "$err" "not a round directory"
}

test_briefs_writes_one_brief_per_reviewer() {
  with_context
  run_script "$briefs" "$round"
  assert_status 0
  local lens
  for lens in $lenses; do
    assert_contains "$out" "=== code-review-$lens ==="
    assert_contains "$(brief_for "$lens")" "$save $round $lens <<'END_OF_REPORT_"
  done
  assert_contains "$out" "$round/diff.patch"
}

# A fixed delimiter could be ended early by a line quoted from the diff.
test_briefs_use_an_unguessable_delimiter_that_opens_and_closes() {
  with_context
  run_script "$briefs" "$round"
  local brief delim
  brief="$(brief_for sleuth)"
  delim="$(printf '%s\n' "$brief" | sed -n "s/.*<<'\(END_OF_REPORT_[0-9a-f]\{16\}\)'.*/\1/p")"
  if [ -z "$delim" ]; then
    fail "no random delimiter in: $brief"
  fi
  assert_contains "$brief" "$(printf '\n%s\n' "$delim")"
  if [ "$(brief_for pedant | grep -c "$delim")" != "0" ]; then
    fail "expected each brief to get its own delimiter"
  fi
}

test_briefs_quote_a_script_path_with_spaces() {
  with_context
  ln -s "$skill_scripts" "$work/skill dir"
  run_script "$work/skill dir/briefs.sh" "$round"
  assert_status 0
  assert_contains "$(brief_for sleuth)" "skill\\ dir/save-report.sh $round sleuth"
}

test_briefs_quote_paths_with_spaces() {
  export CLAUDE_JOB_DIR="$work/job with space"
  rounds="$CLAUDE_JOB_DIR/tmp/code-review-swarm"
  with_context
  run_script "$briefs" "$round"
  assert_status 0
  assert_contains "$(brief_for sleuth)" "job\\ with\\ space/tmp/code-review-swarm/round-1 sleuth"
}

test_briefs_keep_the_skeptic_blind() {
  with_context
  run_script "$briefs" "$round"
  assert_status 0
  assert_contains "$(brief_for skeptic)" "$round/diff.patch"
  assert_not_contains "$(brief_for skeptic)" "context.md"
  assert_not_contains "$(brief_for skeptic)" "git show"
}

test_briefs_give_the_advocate_the_request() {
  with_context
  run_script "$briefs" "$round"
  assert_status 0
  assert_contains "$(brief_for advocate)" "$round/context.md"
  assert_contains "$(brief_for advocate)" "is the request"
}

test_briefs_name_the_base_for_old_versions() {
  with_context
  local base
  base="$(awk -F'\t' '$1 == "base" { print $2 }' "$round/meta")"
  run_script "$briefs" "$round"
  assert_contains "$(brief_for sleuth)" "git show $base:<path>"
}

test_briefs_give_other_reviewers_the_context() {
  with_context
  run_script "$briefs" "$round"
  assert_status 0
  assert_contains "$(brief_for sleuth)" "Read $round/context.md for what the change is for."
  assert_not_contains "$(brief_for sleuth)" "is the request"
}

# --- save-report.sh ----------------------------------------------------------

sample_report() {
  cat <<'EOF'
Reviewed round-1 diff, 1 file.

### Inverted check
- Location: app.txt:2
- Severity: high
- Confidence: high

### Missed twin
- Location: app.txt:3
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

test_save_report_rejects_an_unknown_lens() {
  start_round_with_change
  run_script "$save" "$round" nosuch </dev/null
  assert_status 2
  assert_contains "$err" "unknown reviewer: nosuch"
}

test_save_report_rejects_the_full_agent_name() {
  start_round_with_change
  run_script "$save" "$round" code-review-sleuth </dev/null
  assert_status 2
  assert_contains "$err" "unknown reviewer: code-review-sleuth"
}

test_save_report_rejects_several_names_in_one() {
  start_round_with_change
  run_script "$save" "$round" "sleuth pedant" </dev/null
  assert_status 2
  assert_contains "$err" "unknown reviewer: sleuth pedant"
}

test_save_report_saves_stdin_and_counts_findings() {
  start_round_with_change
  sample_report >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 0
  assert_contains "$out" "saved code-review-sleuth: 2 findings (critical 0, high 1, medium 0, low 1)"
  assert_contains "$(cat "$round/reports/sleuth.md")" "### Inverted check"
}

# Counts ignore case, and a quoted format line is not a finding.
test_save_report_counts_every_severity() {
  start_round_with_change
  cat >"$work/report.md" <<'EOF'
Format: - Severity: critical | high | medium | low
- Severity: critical | high | medium | low
- Severity: critical
- Severity: Critical
- Severity: HIGH
- Severity: medium
- Severity: low
EOF
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 0
  assert_contains "$out" "5 findings (critical 2, high 1, medium 1, low 1)"
}

# A level followed by other words, decorated, or with trailing spaces still
# counts by its first word.
test_save_report_counts_a_decorated_severity_by_its_first_word() {
  start_round_with_change
  printf -- '- Severity: high (was medium)\n- Severity: **medium**\n- Severity: low  \n- Severity: high.\n' >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 0
  assert_contains "$out" "4 findings (critical 0, high 2, medium 1, low 1)"
}

test_save_report_replaces_an_earlier_report() {
  start_round_with_change
  printf 'first\n' >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  printf 'second\n' >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 0
  assert_content "$round/reports/sleuth.md" "second"
}

test_save_report_rejects_an_empty_report() {
  start_round_with_change
  printf '  \n\n' >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 1
  assert_contains "$err" "empty report"
  assert_absent "$round/reports/sleuth.md"
  assert_equals "$(ls "$round/reports")" ""
}

# --- collect-reports.sh ------------------------------------------------------

save_all_reports() {
  local lens
  for lens in $lenses; do
    if [ "$lens" = "sleuth" ]; then
      sample_report >"$work/report.md"
    else
      printf 'Reviewed it.\n\nNo findings for %s.\n' "$lens" >"$work/report.md"
    fi
    if [ "$lens" = "pedant" ]; then
      printf -- '- Severity: critical\n- Severity: medium\n' >>"$work/report.md"
    fi
    run_script "$save" "$round" "$lens" <"$work/report.md"
  done
}

test_collect_help() {
  run_script "$collect" --help
  assert_status 0
  assert_contains "$out" "Usage: collect-reports.sh"
}

test_collect_rejects_unknown_option() {
  start_round_with_change
  run_script "$collect" "$round" --bogus
  assert_status 2
  assert_contains "$err" "unknown option: --bogus"
}

test_collect_rejects_a_missing_round() {
  run_script "$collect" "$work/none"
  assert_status 2
  assert_contains "$err" "not a round directory"
}

test_collect_waits_for_missing_reports() {
  start_round_with_change
  sample_report >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  run_script "$collect" "$round"
  assert_status 3
  assert_contains "$out" "waiting on: pedant advocate doubter locksmith minimalist skeptic"
  assert_not_contains "$out" "Inverted check"
}

test_collect_prints_everything_once_all_are_in() {
  start_round_with_change
  save_all_reports
  run_script "$collect" "$round"
  assert_status 0
  assert_contains "$out" "7 of 7 reports"
  assert_contains "$out" "| code-review-sleuth | 2 | 0 | 1 | 0 | 1 |"
  assert_contains "$out" "| code-review-pedant | 2 | 1 | 0 | 1 | 0 |"
  assert_contains "$out" "| total | 4 | 1 | 1 | 1 | 1 |"
  assert_contains "$out" "## code-review-sleuth"
  assert_contains "$out" "### Inverted check"
  assert_contains "$out" "No findings for skeptic."
}

test_collect_partial_prints_what_is_there() {
  start_round_with_change
  sample_report >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  run_script "$collect" "$round" --partial
  assert_status 0
  assert_contains "$out" "1 of 7 reports"
  assert_contains "$out" "| code-review-pedant | missing |"
  assert_contains "$out" "### Inverted check"
}

run_tests

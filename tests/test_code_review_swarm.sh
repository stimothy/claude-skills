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

# The tests choose where rounds go themselves.
unset CLAUDE_JOB_DIR

repo=""
rounds=""

git_q() {
  git -C "$repo" "$@" >/dev/null 2>&1
}

# A repository on main with one commit, and a directory for rounds.
setup() {
  repo="$work/repo"
  rounds="$work/rounds"
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
  run_in_repo "$start" --root "$rounds"
  round="$rounds/round-1"
}

with_context() {
  start_round_with_change
  run_script "$add_context" "$round" --note "Make two loud." </dev/null
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
  run_in_repo --dir "$work/plain" "$start" --root "$rounds"
  assert_status 1
  assert_contains "$err" "not inside a git work tree"
}

test_start_round_captures_uncommitted_and_untracked_work() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  printf 'new file\n' >"$repo/new.txt"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-1"
  assert_contains "$out" "diff: $rounds/round-1/diff.patch"
  assert_contains "$out" "2 files changed"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+TWO"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+new file"
}

# An edit that keeps the size and the timestamp git cached must still be
# seen: git rechecks such a file only when the index is no newer than it.
test_start_round_sees_a_same_size_edit_in_the_same_second() {
  touch -t 202601010000 "$repo/app.txt"
  git_q add app.txt
  git_q commit -q -m "pin time"
  touch -t 202601010000 "$repo/.git/index"
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  touch -t 202601010000 "$repo/app.txt"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch" 2>/dev/null)" "+TWO"
}

test_start_round_never_prints_the_diff() {
  printf 'one\nSECRET-LINE\nthree\n' >"$repo/app.txt"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_not_contains "$out" "SECRET-LINE"
}

test_start_round_leaves_the_index_alone() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  printf 'new file\n' >"$repo/new.txt"
  local before after
  before="$(git -C "$repo" status --porcelain)"
  run_in_repo "$start" --root "$rounds"
  after="$(git -C "$repo" status --porcelain)"
  assert_status 0
  assert_equals "$after" "$before"
}

test_start_round_keeps_ignored_files_out() {
  printf 'build/\n' >"$repo/.gitignore"
  mkdir "$repo/build"
  printf 'artifact\n' >"$repo/build/out.bin"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "artifact"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+build/"
}

test_start_round_includes_branch_commits_against_main() {
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "merge base of main and HEAD"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+four"
}

test_start_round_prefers_origin_head() {
  git_q update-ref refs/remotes/origin/main HEAD
  git_q symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git_q switch -q -c feature
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "merge base of origin/main and HEAD"
}

test_start_round_uses_a_named_base() {
  printf 'one\ntwo\nthree\nfour\n' >"$repo/app.txt"
  git_q commit -q -am "add four"
  printf 'one\ntwo\nthree\nfour\nfive\n' >"$repo/app.txt"
  git_q commit -q -am "add five"
  run_in_repo "$start" --root "$rounds" --base HEAD~1
  assert_status 0
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+five"
  assert_not_contains "$(cat "$rounds/round-1/diff.patch")" "+four"
}

test_start_round_rejects_an_unknown_base() {
  printf 'changed\n' >"$repo/app.txt"
  run_in_repo "$start" --root "$rounds" --base no-such-ref
  assert_status 1
  assert_contains "$err" "unknown ref: no-such-ref"
}

test_start_round_falls_back_to_head_without_a_default_branch() {
  git_q branch -m trunk
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "no default branch found"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+TWO"
}

test_start_round_handles_a_repository_without_commits() {
  rm -rf "$repo"
  mkdir -p "$repo"
  git_q init -q -b main
  printf 'first\n' >"$repo/first.txt"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "repository has no commits"
  assert_contains "$(cat "$rounds/round-1/diff.patch")" "+first"
}

test_start_round_reports_nothing_to_review() {
  run_in_repo "$start" --root "$rounds"
  assert_status 3
  assert_contains "$out" "nothing to review"
  assert_absent "$rounds/round-1"
}

test_start_round_numbers_rounds() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start" --root "$rounds"
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
}

test_start_round_defaults_to_the_job_tmp_directory() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  mkdir -p "$work/job/tmp"
  CLAUDE_JOB_DIR="$work/job" run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $work/job/tmp/code-review-swarm/round-1"
}

test_start_round_falls_back_to_a_temporary_directory() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  mkdir -p "$work/tmpdir"
  TMPDIR="$work/tmpdir" run_in_repo "$start"
  assert_status 0
  assert_contains "$out" "round: $work/tmpdir/code-review-swarm."
}

test_start_round_lists_changed_files_and_truncates() {
  local i=1
  while [ "$i" -le 45 ]; do
    printf 'x\n' >"$repo/file$i.txt"
    i=$((i + 1))
  done
  run_in_repo "$start" --root "$rounds"
  assert_status 0
  assert_contains "$out" "file1.txt"
  assert_contains "$out" "... and 5 more"
}

test_start_round_since_reads_only_what_changed_after_that_round() {
  printf 'one\nTWO\nthree\n' >"$repo/app.txt"
  run_in_repo "$start" --root "$rounds"
  printf 'one\nTWO\nTHREE\n' >"$repo/app.txt"
  run_in_repo "$start" --since "$rounds/round-1"
  assert_status 0
  assert_contains "$out" "round: $rounds/round-2"
  assert_contains "$out" "snapshot of round-1"
  assert_contains "$(cat "$rounds/round-2/diff.patch")" "+THREE"
  assert_not_contains "$(cat "$rounds/round-2/diff.patch")" "+TWO"
}

test_start_round_since_rejects_a_directory_that_is_not_a_round() {
  run_in_repo "$start" --since "$work"
  assert_status 2
  assert_contains "$err" "not a round directory"
}

# --- add-context.sh ----------------------------------------------------------

# A stand-in for the GitHub CLI that logs its arguments and prints $GH_OUT.
make_gh_stub() {
  cat >"$work/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [ -n "${GH_FAIL:-}" ]; then
  echo "gh: not found" >&2
  exit 1
fi
printf '%s\n' "$GH_OUT"
EOF
  chmod +x "$work/gh"
  export GH="$work/gh" GH_LOG="$work/gh.log"
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
  start_round_with_change
  make_gh_stub
  GH_OUT="## Issue: Shout line two" run_script "$add_context" "$round" --issue 42
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "## Issue: Shout line two"
  assert_contains "$(cat "$GH_LOG")" "issue view 42 --json title,url,body"
}

test_add_context_pulls_a_pull_request() {
  start_round_with_change
  make_gh_stub
  GH_OUT="## Pull request: Shout" run_script "$add_context" "$round" --pr 7
  assert_status 0
  assert_contains "$(cat "$round/context.md")" "## Pull request: Shout"
  assert_contains "$(cat "$GH_LOG")" "pr view 7 --json title,url,body"
}

test_add_context_reports_a_failing_gh_and_writes_nothing() {
  start_round_with_change
  make_gh_stub
  GH_FAIL=1 GH_OUT="" run_script "$add_context" "$round" --issue 42
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

test_briefs_rejects_an_unknown_lens() {
  with_context
  run_script "$briefs" "$round" nosuch
  assert_status 2
  assert_contains "$err" "unknown reviewer: nosuch"
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
    assert_contains "$out" "$save $round $lens <<'END_OF_REPORT'"
  done
  assert_contains "$out" "$round/diff.patch"
}

test_briefs_keep_the_skeptic_blind() {
  with_context
  run_script "$briefs" "$round" skeptic
  assert_status 0
  assert_contains "$out" "=== code-review-skeptic ==="
  assert_contains "$out" "$round/diff.patch"
  assert_not_contains "$out" "context.md"
  assert_not_contains "$out" "=== code-review-sleuth ==="
}

test_briefs_give_the_advocate_the_request() {
  with_context
  run_script "$briefs" "$round" code-review-advocate
  assert_status 0
  assert_contains "$out" "$round/context.md"
  assert_contains "$out" "is the request"
}

test_briefs_name_the_base_for_old_versions_except_to_the_skeptic() {
  with_context
  local base
  base="$(awk -F'\t' '$1 == "base" { print $2 }' "$round/meta")"
  run_script "$briefs" "$round" sleuth
  assert_contains "$out" "git show $base:<path>"
  run_script "$briefs" "$round" skeptic
  assert_not_contains "$out" "git show"
}

test_briefs_give_other_reviewers_the_context() {
  with_context
  run_script "$briefs" "$round" sleuth
  assert_status 0
  assert_contains "$out" "Read $round/context.md for what the change is for."
  assert_not_contains "$out" "is the request"
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

test_save_report_saves_stdin_and_counts_findings() {
  start_round_with_change
  sample_report >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 0
  assert_contains "$out" "saved code-review-sleuth: 2 findings (critical 0, high 1, medium 0, low 1)"
  assert_contains "$(cat "$round/reports/sleuth.md")" "### Inverted check"
}

test_save_report_accepts_the_full_agent_name() {
  start_round_with_change
  sample_report >"$work/report.md"
  run_script "$save" "$round" code-review-pedant <"$work/report.md"
  assert_status 0
  assert_file "$round/reports/pedant.md"
}

test_save_report_rejects_an_empty_report() {
  start_round_with_change
  printf '  \n\n' >"$work/report.md"
  run_script "$save" "$round" sleuth <"$work/report.md"
  assert_status 1
  assert_contains "$err" "empty report"
  assert_absent "$round/reports/sleuth.md"
}

# --- collect-reports.sh ------------------------------------------------------

save_all_reports() {
  local lens
  for lens in $lenses; do
    if [ "$lens" = "sleuth" ]; then
      sample_report >"$work/report.md"
      run_script "$save" "$round" "$lens" <"$work/report.md"
    else
      printf 'Reviewed it.\n\nNo findings for %s.\n' "$lens" >"$work/report.md"
      run_script "$save" "$round" "$lens" <"$work/report.md"
    fi
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
  assert_contains "$out" "| total | 2 | 0 | 1 | 0 | 1 |"
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

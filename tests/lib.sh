# shellcheck shell=bash
#
# Test harness shared by the tests/test_*.sh files. Source it, define
# functions named test_*, then call run_tests.
#
# Scripts under test run through run_script, which runs them under xtrace and
# appends the lines they execute to $COV_TRACE. tests/run.sh reads that trace
# to measure line coverage across every test file.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT

# Scripts under test are run through this symlink to the repository, and the
# trace names each file by its path after it. Bash 3.2, the version macOS
# ships, truncates the trace prefix at about 100 characters, so it must stay
# short. A test that copies a script into a throwaway layout names that
# layout's root "_cov_" for the same reason.
cov_root="$scratch/_cov_"
ln -s "$repo_root" "$cov_root"

# Run on its own, a test file still traces into a throwaway file.
COV_TRACE="${COV_TRACE:-$scratch/trace}"
: >>"$COV_TRACE"

tests_run=0
tests_failed=0
current_test=""
current_failed=0

# Each test gets a fresh directory of its own.
work=""

# Set by run_script.
out=""
err=""
status=0

# Runs a script with the given arguments, under xtrace, with the caller's
# stdin. Sets out, err and status; the trace is split off from stderr.
run_script() {
  local raw="$work/.stderr.raw"
  out="$(PS4='+COV:${BASH_SOURCE#*/_cov_/}:${LINENO}: ' bash -x "$@" 2>"$raw")"
  status=$?
  grep -E '^\++COV:' "$raw" >>"$COV_TRACE"
  err="$(grep -vE '^\++COV:' "$raw")"
}

fail() {
  if [ "$current_failed" -eq 0 ]; then
    echo "FAIL  $current_test"
  fi
  echo "        $1"
  current_failed=1
}

assert_status() {
  if [ "$status" -ne "$1" ]; then
    fail "expected exit status $1, got $status (stdout: $out) (stderr: $err)"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected to find \"$2\" in: $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected not to find \"$2\" in: $1" ;;
  esac
}

assert_equals() {
  if [ "$1" != "$2" ]; then
    fail "expected \"$2\", got \"$1\""
  fi
}

assert_file() {
  if [ ! -f "$1" ]; then
    fail "expected a file at $1"
  fi
}

assert_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "expected nothing at $1"
  fi
}

assert_link_to() {
  if [ ! -L "$1" ]; then
    fail "expected a symlink at $1"
  elif [ "$(readlink "$1")" != "$2" ]; then
    fail "expected $1 to link to $2, got $(readlink "$1")"
  fi
}

assert_content() {
  if [ "$(cat "$1" 2>/dev/null)" != "$2" ]; then
    fail "expected $1 to contain \"$2\", got \"$(cat "$1" 2>/dev/null)\""
  fi
}

run_test() {
  current_test="$1"
  current_failed=0
  tests_run=$((tests_run + 1))
  work="$(mktemp -d "$scratch/test.XXXXXX")"
  if declare -F setup >/dev/null; then
    setup
  fi
  "$1"
  if [ "$current_failed" -eq 0 ]; then
    echo "ok    $1"
  else
    tests_failed=$((tests_failed + 1))
  fi
}

# Runs every test_* function, prints a summary, and exits 1 on any failure.
run_tests() {
  local name
  for name in $(declare -F | awk '{ print $3 }' | grep '^test_' | grep -e "${TEST_FILTER:-}"); do
    run_test "$name"
  done
  echo "$tests_run tests, $tests_failed failed"
  if [ "$tests_failed" -gt 0 ]; then
    exit 1
  fi
}

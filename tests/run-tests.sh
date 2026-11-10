#!/usr/bin/env bash
# Run the existing behavioral suites and the aggregate runner's own checks.
# Counts and skip reasons come from the suites themselves, not their exit codes.
set -u

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ $# -ne 0 ]]; then
  echo 'Usage: tests/run-tests.sh (no arguments; see tests/README.md for filtering)' >&2
  exit 2
fi

run_shell_suite() {
  local runner="$here/run-cross-compiler-tests.sh" names name found=0
  [[ -f "$runner" && -r "$runner" ]] || {
    echo "ERROR: mandatory shell runner is missing or unreadable: $runner" >&2
    return 1
  }
  # The existing runner can exit successfully after discovering no tests.
  names="$("$bash_bin" "$runner" -l)" || {
    echo 'ERROR: shell test discovery failed' >&2
    return 1
  }
  while IFS= read -r name; do
    [[ "$name" != t_* ]] || found=1
  done <<< "$names"
  [[ "$found" == 1 ]] || {
    echo 'ERROR: mandatory shell suite is empty (no t_* tests discovered)' >&2
    return 1
  }
  "$bash_bin" "$runner"
}

run_python_suite() {
  local python_bin
  python_bin="$(command -v python3)" || {
    echo 'ERROR: mandatory interpreter python3 was not found on PATH' >&2
    return 1
  }
  # Use the same unittest discovery as the separate command, but reject zero
  # tests. Verbosity 2 exposes skipped test IDs/reasons as well as the summary.
  "$python_bin" -B - "$here" <<'PY'
import sys
import unittest

suite = unittest.defaultTestLoader.discover(sys.argv[1], pattern="test_*.py")
if suite.countTestCases() == 0:
    sys.exit("ERROR: mandatory Python suite is absent or empty (no tests discovered)")
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY
}

run_runner_checks() {
  local runner="$here/runner/test_run_tests.sh"
  [[ -f "$runner" && -r "$runner" && -s "$runner" ]] || {
    echo "ERROR: mandatory runner checks are missing, empty or unreadable: $runner" >&2
    return 1
  }
  "$bash_bin" "$runner"
}

bash_bin="$(command -v bash)" || bash_bin=''
shell_rc=1
checks_rc=1
echo '=== Shell suite ==='
if [[ -z "$bash_bin" ]] || ! "$bash_bin" -c \
  '(( BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4 ))'; then
  echo 'ERROR: mandatory interpreter bash >= 4.4 is required on PATH' >&2
else
  run_shell_suite
  shell_rc=$?
fi

echo '=== Python suite ==='
run_python_suite
python_rc=$?

echo '=== Aggregate runner checks ==='
if [[ -n "$bash_bin" ]]; then
  run_runner_checks
  checks_rc=$?
fi

echo '=== Suite exit statuses (counts and skips are reported above) ==='
printf 'Shell suite: exit %s\nPython suite: exit %s\nRunner checks: exit %s\n' \
  "$shell_rc" "$python_rc" "$checks_rc"
[[ "$shell_rc" -eq 0 && "$python_rc" -eq 0 && "$checks_rc" -eq 0 ]]

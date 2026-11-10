#!/usr/bin/env bash
# Dispatcher regression checks: only disposable, lightweight fake suites run.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
real_bash="$BASH"
real_python="$(command -v python3)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/crs-runner-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
passed=0

fixture() {
  local name="$1"
  work="$scratch/$name/tests with spaces"
  mkdir -p "$work/runner" "$work/bin"
  cp "$here/../run-tests.sh" "$work/run-tests.sh"
  # Each aggregate invocation runs fake self-checks, avoiding recursion.
  printf '#!/bin/sh\nexit 0\n' > "$work/runner/test_run_tests.sh"
  cat > "$work/run-cross-compiler-tests.sh" <<'SH'
if [[ ${1:-} == -l ]]; then
  [[ ${DISCOVERY_RC:-0} == 0 ]] || exit "$DISCOVERY_RC"
  printf '%s\n' "${SHELL_NAMES-t_fake}"
  exit 0
fi
printf 'shell\n' >> "$EVENTS"
printf 'CRS_ROOT=%s\nTMPDIR=%s\n' "${CRS_ROOT:-}" "${TMPDIR:-}"
echo 'SKIP  t_fake_optional'
echo '        fake optional prerequisite'
echo 'passed: 2   failed: 0   advisory-failed: 0   skipped: 1   demos-reproduced: 0'
exit "${SHELL_RC:-0}"
SH
  cat > "$work/test_fake.py" <<'PY'
import unittest

class Fake(unittest.TestCase):
    def test_ok(self):
        pass

    @unittest.skip("fake Python prerequisite")
    def test_skip(self):
        pass
PY
  # Interpose a lightweight runner to observe continuation and launch behavior.
  cat > "$work/bin/python3" <<'SH'
#!/bin/sh
printf 'python\n' >> "$EVENTS"
printf 'CRS_ROOT=%s\nTMPDIR=%s\n' "${CRS_ROOT:-}" "${TMPDIR:-}"
if [ "${PYTHON_RC:-0}" != 0 ]; then exit "$PYTHON_RC"; fi
exec "$REAL_PYTHON" "$@"
SH
  chmod +x "$work/bin/python3"
  ln -s "$real_bash" "$work/bin/bash"
  ln -s "$(command -v dirname)" "$work/bin/dirname"
  : > "$work/events"
}

run() {
  rc=0
  # A restricted PATH makes missing interpreters deterministic on any host.
  ( cd "$scratch"; env -u SHELL_NAMES -u DISCOVERY_RC -u SHELL_RC -u PYTHON_RC \
      "PATH=$work/bin" "EVENTS=$work/events" "REAL_PYTHON=$real_python" \
      "PYTHONDONTWRITEBYTECODE=1" "$@" "$real_bash" "$work/run-tests.sh" \
      > "$work/output" 2>&1 ) || rc=$?
}

fail() { cat "$work/output" >&2; echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$work/output" || fail "missing output: $1"; }
events() { [[ "$(cat "$work/events")" == "$1" ]] || fail 'unexpected suite execution'; }
ok() { [[ "$rc" -eq 0 ]] || fail 'expected success'; }
bad() { [[ "$rc" -ne 0 ]] || fail 'expected failure'; }
pass() { passed=$((passed + 1)); printf 'PASS  %s\n' "$1"; }

fixture success
run "CRS_ROOT=$work/alternate root" "TMPDIR=$scratch"
ok; events $'shell\npython'
contains "CRS_ROOT=$work/alternate root"; contains "TMPDIR=$scratch"
[[ ! -d "$work/__pycache__" ]] || fail 'Python wrote bytecode'
contains 'passed: 2'; contains 'skipped: 1'; contains 'SKIP  t_fake_optional'
contains 'fake optional prerequisite'; contains 'fake Python prerequisite'
contains 'Ran 2 tests'; contains 'OK (skipped=1)'
contains 'Shell suite: exit 0'; contains 'Python suite: exit 0'
pass success_and_skip_reporting

fixture shell_failure
run SHELL_RC=9
bad; events $'shell\npython'; contains 'Shell suite: exit 9'
contains 'Python suite: exit 0'
pass shell_failure_still_runs_python

fixture python_failure
run PYTHON_RC=8
bad; events $'shell\npython'; contains 'Shell suite: exit 0'
contains 'Python suite: exit 8'
pass python_failure_preserves_shell_result

fixture both_fail
run SHELL_RC=9 PYTHON_RC=8
bad; events $'shell\npython'
contains 'Shell suite: exit 9'; contains 'Python suite: exit 8'
pass both_failures_reported

fixture missing_bash
rm "$work/bin/bash"
run
bad; events python; contains 'mandatory interpreter bash >= 4.4'
pass missing_bash_still_runs_python

fixture missing_python
rm "$work/bin/python3"
run
bad; events shell; contains 'mandatory interpreter python3'
pass missing_python_keeps_shell_result

fixture missing_shell_runner
rm "$work/run-cross-compiler-tests.sh"
run
bad; events python; contains 'mandatory shell runner is missing'
pass missing_shell_runner_still_runs_python

fixture empty_shell
run SHELL_NAMES=
bad; events python; contains 'mandatory shell suite is empty'
pass empty_shell_suite_rejected

fixture no_hard_shell_tests
run SHELL_NAMES=$'a_advisory\nd_demo'
bad; events python; contains 'mandatory shell suite is empty'
pass shell_suite_without_hard_tests_rejected

fixture discovery_failure
run DISCOVERY_RC=7
bad; events python; contains 'shell test discovery failed'
pass shell_discovery_failure_still_runs_python

fixture absent_python
rm "$work/test_fake.py"
run
bad; events $'shell\npython'; contains 'Python suite is absent or empty'
pass absent_python_suite_rejected

fixture empty_python
printf '# No test cases\n' > "$work/test_fake.py"
run
bad; events $'shell\npython'; contains 'Python suite is absent or empty'
pass empty_python_suite_rejected

fixture python_import_failure
printf 'raise RuntimeError("fake import failure")\n' > "$work/test_fake.py"
run
bad; events $'shell\npython'; contains 'fake import failure'
contains 'FAILED (errors=1)'
pass python_discovery_import_error_rejected

fixture python_test_failure
printf 'import unittest\nclass Fake(unittest.TestCase):\n    def test_fail(self): self.fail("fake assertion")\n' > "$work/test_fake.py"
run
bad; events $'shell\npython'; contains 'FAILED (failures=1)'
contains 'Python suite: exit 1'
pass python_test_failure_reported

fixture missing_checks
rm "$work/runner/test_run_tests.sh"
run
bad; events $'shell\npython'; contains 'mandatory runner checks are missing'
pass missing_runner_checks_rejected

fixture empty_checks
: > "$work/runner/test_run_tests.sh"
run
bad; events $'shell\npython'; contains 'mandatory runner checks are missing, empty'
pass empty_runner_checks_rejected

fixture failed_checks
printf '#!/bin/sh\nexit 6\n' > "$work/runner/test_run_tests.sh"
run
bad; events $'shell\npython'; contains 'Runner checks: exit 6'
pass runner_check_failure_reported

printf 'Runner checks passed: %s; failed: 0; skipped: 0\n' "$passed"

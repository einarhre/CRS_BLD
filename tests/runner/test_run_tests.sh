#!/usr/bin/env bash
# Dispatcher regression checks: only disposable, lightweight fake suites run.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
real_bash="$BASH"
real_python="$(command -v python3)" || {
  echo 'ERROR: standalone runner checks require python3 on PATH' >&2
  exit 1
}
scratch="$(mktemp -d "${TMPDIR:-/tmp}/crs-runner-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
passed=0

fixture() {
  local name="$1"
  work="$scratch/$name/tests with spaces"
  mkdir -p "$work/runner" "$work/bin" "$work/infrastructure"
  cp "$here/../run-tests.sh" "$work/run-tests.sh"
  # Each aggregate invocation runs fake self-checks, avoiding recursion.
  printf '#!/bin/sh\nprintf "checks\\n" >> "$EVENTS"\n[ -z "${ORDER:-}" ] || printf "checks\\n" >> "$ORDER"\nexit "${CHECKS_RC:-0}"\n' > "$work/runner/test_run_tests.sh"
  cat > "$work/run-cross-compiler-tests.sh" <<'SH'
if [[ $# == 1 && $1 == -l ]]; then
  [[ ${DISCOVERY_RC:-0} == 0 ]] || exit "$DISCOVERY_RC"
  printf '%s\n' "${SHELL_NAMES-t_fake}"
  exit 0
fi
[[ $# == 0 ]] || { echo "unexpected shell runner arguments: $*" >&2; exit 3; }
printf 'shell\n' >> "$EVENTS"
[[ -z ${ORDER:-} ]] || printf 'shell\n' >> "$ORDER"
printf 'CRS_ROOT=%s\nTMPDIR=%s\n' "${CRS_ROOT:-}" "${TMPDIR:-}"
echo 'SKIP  t_fake_optional'
echo '        fake optional prerequisite'
echo 'passed: 2   failed: 0   advisory-failed: 0   skipped: 1   demos-reproduced: 0'
exit "${SHELL_RC:-0}"
SH
  # Fake infrastructure runner: records to a separate file so the existing
  # three-phase event assertions are unchanged, and to the shared ORDER log
  # that every fake phase appends to (cross-phase ordering evidence).
  cat > "$work/infrastructure/run-infrastructure-tests.sh" <<'SH'
if [[ $# == 1 && $1 == -l ]]; then
  [[ ${INFRA_DISCOVERY_RC:-0} == 0 ]] || exit "$INFRA_DISCOVERY_RC"
  printf '%s\n' "${INFRA_NAMES-$'t_common_x\nt_diag_x\nt_harness_x\nt_pkgs_x\nt_pkgs_support_x'}"
  exit 0
fi
[[ $# == 0 ]] || { echo "unexpected infrastructure runner arguments: $*" >&2; exit 3; }
printf 'infra\n' >> "$EVENTS.infra"
[[ -z ${ORDER:-} ]] || printf 'infra\n' >> "$ORDER"
echo 'passed: 3   failed: 0   skipped: 0'
exit "${INFRA_RC:-0}"
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
[ -z "${ORDER:-}" ] || printf 'python\n' >> "$ORDER"
printf 'CRS_ROOT=%s\nTMPDIR=%s\n' "${CRS_ROOT:-}" "${TMPDIR:-}"
if [ "${PYTHON_RC:-0}" != 0 ]; then exit "$PYTHON_RC"; fi
exec "$REAL_PYTHON" "$@"
SH
  chmod +x "$work/bin/python3"
  ln -s "$real_bash" "$work/bin/bash"
  ln -s "$(command -v dirname)" "$work/bin/dirname"
  : > "$work/events"; : > "$work/events.infra"; : > "$work/order"
}

run() {
  rc=0
  # A restricted PATH makes missing interpreters deterministic on any host.
  ( cd "$scratch"; env -u SHELL_NAMES -u DISCOVERY_RC -u SHELL_RC -u PYTHON_RC \
      -u INFRA_NAMES -u INFRA_DISCOVERY_RC -u INFRA_RC -u CHECKS_RC \
      -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX \
      "PATH=$work/bin" "EVENTS=$work/events" "ORDER=$work/order" "REAL_PYTHON=$real_python" \
      "REAL_BASH=$real_bash" "$@" "$real_bash" "$work/run-tests.sh" \
      > "$work/output" 2>&1 ) || rc=$?
}

fail() { cat "$work/output" >&2; echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$work/output" || fail "missing output: $1"; }
lacks() { if grep -Fq -- "$1" "$work/output"; then fail "unexpected output: $1"; fi; }
events() { [[ "$(cat "$work/events")" == "$1" ]] || fail 'unexpected suite execution'; }
ok() { [[ "$rc" -eq 0 ]] || fail 'expected success'; }
bad() { [[ "$rc" -ne 0 ]] || fail 'expected failure'; }
pass() { passed=$((passed + 1)); printf 'PASS  %s\n' "$1"; }

fixture success
run "CRS_ROOT=$work/alternate root" "TMPDIR=$scratch"
ok; events $'shell\npython\nchecks'
contains "CRS_ROOT=$work/alternate root"; contains "TMPDIR=$scratch"
[[ ! -d "$work/__pycache__" ]] || fail 'Python wrote bytecode'
contains 'passed: 2'; contains 'skipped: 1'; contains 'SKIP  t_fake_optional'
contains 'fake optional prerequisite'; contains 'fake Python prerequisite'
contains 'Ran 2 tests'; contains 'OK (skipped=1)'
contains 'Shell suite: exit 0'; contains 'Python suite: exit 0'
pass success_and_skip_reporting

fixture shell_failure
run SHELL_RC=9
bad; events $'shell\npython\nchecks'; contains 'Shell suite: exit 9'
contains 'Python suite: exit 0'
pass shell_failure_still_runs_python

fixture python_failure
run PYTHON_RC=8
bad; events $'shell\npython\nchecks'; contains 'Shell suite: exit 0'
contains 'Python suite: exit 8'
pass python_failure_preserves_shell_result

fixture both_fail
run SHELL_RC=9 PYTHON_RC=8
bad; events $'shell\npython\nchecks'
contains 'Shell suite: exit 9'; contains 'Python suite: exit 8'
pass both_failures_reported

fixture missing_bash
rm "$work/bin/bash"
run
bad; events ''; contains 'mandatory interpreter bash >= 4.4'
contains 'Shell suite: not run'; contains 'Python suite: not run'
contains 'Runner checks: not run'; lacks ': exit '
pass missing_bash_marks_dependent_phases_not_run

fixture old_bash
# Replace the fixture symlink before writing; never overwrite the real Bash.
rm "$work/bin/bash"
cat > "$work/bin/bash" <<'SH'
#!/bin/sh
if [ "${1:-}" = -c ]; then exit 1; fi
exec "$REAL_BASH" "$@"
SH
chmod +x "$work/bin/bash"
run
bad; events ''; contains 'mandatory interpreter bash >= 4.4'
contains 'NOT RUN: shell suite'; contains 'NOT RUN: Python suite'
contains 'NOT RUN: runner checks'; lacks ': exit '
pass unsupported_bash_rejects_all_dependent_phases

fixture missing_python
rm "$work/bin/python3"
run
bad; events $'shell\nchecks'; contains 'mandatory interpreter python3'
pass missing_python_keeps_shell_result

fixture standalone_missing_python
cp "$here/test_run_tests.sh" "$work/runner/test_run_tests.sh"
rm "$work/bin/python3"
rc=0
env "PATH=$work/bin" "$real_bash" "$work/runner/test_run_tests.sh" \
  > "$work/output" 2>&1 || rc=$?
bad; contains 'ERROR: standalone runner checks require python3 on PATH'
pass standalone_missing_python_has_diagnostic

fixture missing_shell_runner
rm "$work/run-cross-compiler-tests.sh"
run
bad; events $'python\nchecks'; contains 'mandatory shell runner is missing'
pass missing_shell_runner_still_runs_python

fixture empty_shell
run SHELL_NAMES=
bad; events $'python\nchecks'; contains 'mandatory shell suite is empty'
pass empty_shell_suite_rejected

fixture no_hard_shell_tests
run SHELL_NAMES=$'a_advisory\nd_demo'
bad; events $'python\nchecks'; contains 'mandatory shell suite is empty'
pass shell_suite_without_hard_tests_rejected

fixture discovery_failure
run DISCOVERY_RC=7
bad; events $'python\nchecks'; contains 'shell test discovery failed'
pass shell_discovery_failure_still_runs_python

fixture absent_python
rm "$work/test_fake.py"
run
bad; events $'shell\npython\nchecks'; contains 'Python suite is absent or empty'
pass absent_python_suite_rejected

fixture empty_python
printf '# No test cases\n' > "$work/test_fake.py"
run
bad; events $'shell\npython\nchecks'; contains 'Python suite is absent or empty'
pass empty_python_suite_rejected

fixture python_import_failure
printf 'raise RuntimeError("fake import failure")\n' > "$work/test_fake.py"
run
bad; events $'shell\npython\nchecks'; contains 'fake import failure'
contains 'FAILED (errors=1)'
pass python_discovery_import_error_rejected

fixture python_test_failure
printf 'import unittest\nclass Fake(unittest.TestCase):\n    def test_fail(self): self.fail("fake assertion")\n' > "$work/test_fake.py"
run
bad; events $'shell\npython\nchecks'; contains 'FAILED (failures=1)'
contains 'Python suite: exit 1'
pass python_test_failure_reported

fixture python_warnings
cat > "$work/test_fake.py" <<'PY'
import unittest
import warnings

class Fake(unittest.TestCase):
    def test_warning(self):
        warnings.warn("fake deprecation warning", DeprecationWarning)
PY
run PYTHONWARNINGS=
ok; events $'shell\npython\nchecks'; contains 'DeprecationWarning: fake deprecation warning'
pass unittest_default_warning_filter_preserved

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
printf '#!/bin/sh\nprintf "checks\\n" >> "$EVENTS"\nexit 6\n' > "$work/runner/test_run_tests.sh"
run
bad; events $'shell\npython\nchecks'; contains 'Runner checks: exit 6'
pass runner_check_failure_reported

order() { [[ "$(cat "$work/order")" == "$1" ]] || fail "unexpected phase order: $(tr '\n' ' ' < "$work/order")"; }
all4=$'shell\npython\nchecks\ninfra'

infra_events() { [[ "$(cat "$work/events.infra")" == "$1" ]] || fail 'unexpected infrastructure suite execution'; }

fixture infra_success
run
ok; events $'shell\npython\nchecks'; infra_events infra; order "$all4"
contains '=== Infrastructure characterization suite ==='; contains 'Infrastructure suite: exit 0'
pass infrastructure_suite_runs_last_and_is_reported

fixture infra_failure
run INFRA_RC=5
bad; events $'shell\npython\nchecks'; infra_events infra
contains 'Infrastructure suite: exit 5'; contains 'Shell suite: exit 0'
pass infrastructure_failure_fails_aggregate

fixture infra_earlier_failure_still_runs_infra
run SHELL_RC=9
bad; infra_events infra; contains 'Shell suite: exit 9'; contains 'Infrastructure suite: exit 0'
pass earlier_failure_does_not_skip_infrastructure_suite

fixture infra_missing
rm "$work/infrastructure/run-infrastructure-tests.sh"
run
bad; events $'shell\npython\nchecks'; contains 'mandatory infrastructure runner is missing'
contains 'Infrastructure suite: exit 1'
pass missing_infrastructure_runner_rejected

fixture infra_empty_runner
: > "$work/infrastructure/run-infrastructure-tests.sh"
run
bad; contains 'mandatory infrastructure runner is missing, empty'
pass empty_infrastructure_runner_rejected

fixture infra_no_tests
run INFRA_NAMES=
bad; infra_events ''; contains 'mandatory infrastructure suite is empty'
pass empty_infrastructure_suite_rejected

fixture infra_component_missing
run INFRA_NAMES=$'t_common_x\nt_pkgs_x\nk_diag_demo'
bad; infra_events ''; contains 'no t_diag_* tests discovered'
pass infrastructure_component_without_hard_tests_rejected

fixture infra_support_missing
run INFRA_NAMES=$'t_common_x\nt_diag_x\nt_harness_x\nt_pkgs_x'
bad; infra_events ''; contains 'no t_pkgs_support_* tests discovered'
pass missing_package_support_component_rejected

fixture infra_discovery_failure
run INFRA_DISCOVERY_RC=4
bad; infra_events ''; contains 'infrastructure test discovery failed'
pass infrastructure_discovery_failure_rejected

fixture infra_bash_gate
rm "$work/bin/bash"
run
bad; infra_events ''; contains 'NOT RUN: infrastructure suite'; contains 'Infrastructure suite: not run'
pass missing_bash_marks_infrastructure_not_run

fixture order_after_python_failure
run PYTHON_RC=8
bad; order "$all4"; contains 'Python suite: exit 8'; contains 'Runner checks: exit 0'
contains 'Infrastructure suite: exit 0'
pass python_failure_still_runs_checks_and_infrastructure_in_order

fixture order_after_checks_failure
run CHECKS_RC=6
bad; order "$all4"; contains 'Runner checks: exit 6'; contains 'Infrastructure suite: exit 0'
pass runner_check_failure_still_runs_infrastructure

fixture order_after_shell_failure
run SHELL_RC=9
bad; order "$all4"; contains 'Shell suite: exit 9'; contains 'Python suite: exit 0'
contains 'Runner checks: exit 0'; contains 'Infrastructure suite: exit 0'
pass shell_failure_runs_all_later_phases_in_order

fixture order_all_fail
run SHELL_RC=9 PYTHON_RC=8 CHECKS_RC=6 INFRA_RC=5
bad; order "$all4"
contains 'Shell suite: exit 9'; contains 'Python suite: exit 8'
contains 'Runner checks: exit 6'; contains 'Infrastructure suite: exit 5'
pass every_phase_failing_still_runs_all_four_in_order

fixture order_infra_discovery_failure
run INFRA_DISCOVERY_RC=4
bad; order $'shell\npython\nchecks'; contains 'Infrastructure suite: exit 1'
pass infrastructure_discovery_failure_after_other_phases

fixture infra_harness_component_missing
run INFRA_NAMES=$'t_common_x\nt_diag_x\nt_pkgs_x'
bad; infra_events ''; contains 'no t_harness_* tests discovered'
pass infrastructure_without_harness_self_tests_rejected

printf 'Runner checks passed: %s; failed: 0; skipped: 0\n' "$passed"

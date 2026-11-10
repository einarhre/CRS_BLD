#!/usr/bin/env bash
# Run the infrastructure characterization tests for etc/common.sh,
# etc/diagnostics.sh and make_pkgs.sh.
#
#   tests/infrastructure/run-infrastructure-tests.sh [-k REGEX] [-l] [-v] [test-file ...]
#
#   -k REGEX  only run tests whose name matches REGEX
#   -l        list test names and exit
#   -v        show output of passing tests too
#
# Test names: t_* are hard characterizations of existing behavior.  k_* are
# known-defect demonstrations: they never affect the exit status and print
# KNOWN-DEFECT-REPRODUCED or KNOWN-DEFECT-NOT-REPRODUCED.  A test exiting with
# status 77 is reported as SKIP.  Every test runs in its own fresh bash process
# under a hard timeout.  The three mandatory suite files must exist, be
# non-empty and define at least one t_* test, otherwise the run fails.
# Nothing here builds, downloads or installs anything.
set -u
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_TIMEOUT="${INFRA_TEST_TIMEOUT:-120}"

pattern='.'; list=0; verbose=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k) pattern="$2"; shift 2 ;;
    -l) list=1; shift ;;
    -v) verbose=1; shift ;;
    *) files+=("$1"); shift ;;
  esac
done
mandatory=("$here/test_common.sh" "$here/test_diagnostics.sh" "$here/test_make_pkgs.sh")
if [[ ${#files[@]} -eq 0 ]]; then
  files=("${mandatory[@]}")
fi
[[ -f "$here/lib.sh" ]] || { echo "ERROR: missing $here/lib.sh" >&2; exit 2; }

# Discover names per file in a throwaway shell.
declare -a pairs=()   # "file<TAB>name"
errors=0
for f in "${files[@]}"; do
  if [[ ! -f "$f" || ! -r "$f" || ! -s "$f" ]]; then
    echo "ERROR: mandatory test file missing, empty or unreadable: $f" >&2
    errors=$((errors + 1)); continue
  fi
  mapfile -t found < <(bash -c 'source "$1"; source "$2"; compgen -A function | grep -E "^(t|k)_" | LC_ALL=C sort' _ "$here/lib.sh" "$f")
  hard=0
  for n in "${found[@]}"; do [[ "$n" == t_* ]] && hard=$((hard + 1)); done
  if [[ "$hard" -eq 0 ]]; then
    echo "ERROR: no t_* tests discovered in $f" >&2
    errors=$((errors + 1)); continue
  fi
  for n in "${found[@]}"; do
    [[ "$n" =~ $pattern ]] && pairs+=("$f"$'\t'"$n")
  done
done

if [[ "$list" -eq 1 ]]; then
  for p in "${pairs[@]}"; do printf '%s\n' "${p#*$'\t'}"; done
  exit $(( errors > 0 ))
fi
if [[ "$errors" -gt 0 ]]; then
  echo "ERROR: infrastructure suite discovery failed ($errors problem(s))" >&2
  exit 1
fi
if [[ ${#pairs[@]} -eq 0 ]]; then
  echo "ERROR: no infrastructure tests selected (pattern: $pattern)" >&2
  exit 1
fi

echo "Testing: $(cd -- "${CRS_ROOT:-$here/../..}" && pwd)"
pass=0; failed=0; skipped=0; kd_rep=0; kd_not=0
failed_names=(); kd_names=()
out="$(mktemp "${TMPDIR:-/tmp}/crs-infra-out.XXXXXX")"
trap 'rm -f -- "$out"' EXIT
for p in "${pairs[@]}"; do
  f="${p%%$'\t'*}"; n="${p#*$'\t'}"
  rc=0
  timeout -k 5 "$TEST_TIMEOUT" bash -c 'source "$1"; source "$2"; "$3"' _ "$here/lib.sh" "$f" "$n" >"$out" 2>&1 || rc=$?
  if [[ "$n" == k_* ]]; then
    if [[ $rc -eq 0 ]]; then
      kd_rep=$((kd_rep + 1)); echo "KNOWN-DEFECT-REPRODUCED      $n"
    else
      kd_not=$((kd_not + 1)); kd_names+=("$n"); echo "KNOWN-DEFECT-NOT-REPRODUCED  $n (exit $rc)"
    fi
    sed 's/^/        /' "$out" | head -n 6
  elif [[ $rc -eq 0 ]]; then
    pass=$((pass + 1)); echo "PASS  $n"
    [[ "$verbose" -eq 1 ]] && sed 's/^/        /' "$out"
  elif [[ $rc -eq 77 ]]; then
    skipped=$((skipped + 1)); echo "SKIP  $n"; sed 's/^/        /' "$out" | head -n 4
  else
    failed=$((failed + 1)); failed_names+=("$n"); echo "FAIL  $n (exit $rc)"
    sed 's/^/        /' "$out" | head -n 40
  fi
done
echo
echo "passed: $pass   failed: $failed   skipped: $skipped   known-defects-reproduced: $kd_rep   known-defects-not-reproduced: $kd_not"
[[ "$failed" -eq 0 ]] || { echo "failed: ${failed_names[*]}"; exit 1; }
exit 0

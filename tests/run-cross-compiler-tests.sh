#!/usr/bin/env bash
# Run the make_cross-compiler.sh regression tests.
#
#   tests/run-cross-compiler-tests.sh [-k REGEX] [-l] [-v] [test-file ...]
#
#   -k REGEX  only run tests whose name matches REGEX
#   -l        list test names and exit
#   -v        show output of passing tests too
#
# Environment:
#   CRS_ROOT      directory holding make_cross-compiler.sh and etc/ to test
#                 (default: this repository).  Point it at another checkout to
#                 run the same tests against a different implementation.
#   TMPDIR        where sandboxes are created
#   KEEP_SANDBOX  keep sandboxes for inspection
#
# Test names: t_rN_* are hard requirements derived from spec requirement RN;
# a_rN_* are advisory (spec wording is vague); t_000_* are harness sanity.
# Exit status is 1 if any t_* test fails.  Nothing here compiles anything.
set -u
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export CRS_ROOT="${CRS_ROOT:-$(cd -- "$here/.." && pwd)}"
CRS_ROOT="$(cd -- "$CRS_ROOT" && pwd)"
[[ -f "$CRS_ROOT/make_cross-compiler.sh" ]] || { echo "no make_cross-compiler.sh in $CRS_ROOT" >&2; exit 2; }

pattern='.'; list=0; verbose=0; files=()
while [[ $# -gt 0 ]]
do
  case "$1" in
    -k) pattern="$2"; shift 2 ;;
    -l) list=1; shift ;;
    -v) verbose=1; shift ;;
    *) files+=("$1"); shift ;;
  esac
done
if [[ ${#files[@]} -eq 0 ]]
then
  files=("$here"/cross-compiler/test_*.sh)
fi

# Never leak configuration from the caller's environment into the tests.
unset PREF NCRS MOCK_FAIL MOCK_DLL_MODE MOCK_MV_TOLERANT MOCK_MKDIR_FAIL_MATCH

# shellcheck source=cross-compiler/lib.sh
source "$here/cross-compiler/lib.sh"
for f in "${files[@]}"
do
  # shellcheck disable=SC1090
  source "$f"
done

mapfile -t names < <(compgen -A function | grep -E '^(t|a)_' | LC_ALL=C sort | grep -E -- "$pattern")
if [[ "$list" -eq 1 ]]
then
  printf '%s\n' "${names[@]}"
  exit 0
fi

echo "Testing: $CRS_ROOT/make_cross-compiler.sh"
pass=0; failed=0; advisory=0; failed_names=(); advisory_names=()
out="$(mktemp "${TMPDIR:-/tmp}/crs-test-out.XXXXXX")"
trap 'rm -f -- "$out"' EXIT
for n in "${names[@]}"
do
  ( "$n" ) > "$out" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]
  then
    pass=$((pass + 1))
    echo "PASS  $n"
    [[ $verbose -eq 1 ]] && sed 's/^/        /' "$out"
  elif [[ "$n" == a_* ]]
  then
    advisory=$((advisory + 1)); advisory_names+=("$n")
    echo "ADVISORY-FAIL  $n"
    sed 's/^/        /' "$out" | head -n 12
  else
    failed=$((failed + 1)); failed_names+=("$n")
    echo "FAIL  $n"
    sed 's/^/        /' "$out" | head -n 14
  fi
done
echo
echo "passed: $pass   failed: $failed   advisory-failed: $advisory"
[[ $failed -gt 0 ]] && printf '  FAIL: %s\n' "${failed_names[@]}"
[[ $advisory -gt 0 ]] && printf '  ADVISORY: %s\n' "${advisory_names[@]}"
[[ $failed -eq 0 ]]

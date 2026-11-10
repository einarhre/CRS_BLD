#!/usr/bin/env bash
# Run the infrastructure characterization tests for etc/common.sh,
# etc/diagnostics.sh and make_pkgs.sh, plus the runner's own harness tests.
#
#   tests/infrastructure/run-infrastructure-tests.sh [-k REGEX] [-l] [-v] [test-file ...]
#
#   -k REGEX  only run tests whose name matches REGEX
#   -l        list test names and exit (still fails on load/discovery errors)
#   -v        show output of passing tests too
#
# Discovery: without file arguments every tests/infrastructure/test_*.sh file
# is loaded (automatic discovery), and the four mandatory files test_common.sh,
# test_diagnostics.sh, test_make_pkgs.sh and test_harness.sh must be among
# them.  With file arguments only those files are loaded.  Every loaded file
# must pass `bash -n`, source with status 0 and no stderr output within the
# discovery deadline, and define at least one t_* test; otherwise the run fails.
#
# Test names: t_* gate the exit status.  k_* are known-defect demonstrations,
# reported as KNOWN-DEFECT-REPRODUCED (exit 0), KNOWN-DEFECT-NOT-REPRODUCED
# (exit 1), KNOWN-DEFECT-SKIPPED (exit 77, prerequisite unavailable) - all
# non-gating - or KNOWN-DEFECT-ERROR (timeout, signal, load or other failure),
# which gates.  A t_* test exiting 77 is SKIP.
#
# Supervision: each discovery step and each test runs in its own process group
# (job control) under a watchdog: TERM at the deadline, KILL after a grace
# period.  After the test ends for any reason the runner sweeps its process
# group and any process groups the test registered (GNU timeout groups started
# by lib.sh), then removes the per-test directory it created.  INT/TERM/HUP to
# the runner do the same for the current test before exiting.  Only groups
# created for this run are signalled.
#
# Environment: INFRA_TEST_TIMEOUT (default 120 s), INFRA_DISCOVERY_TIMEOUT
# (default 30 s), INFRA_KILL_GRACE (default 5 s), TMPDIR, CRS_ROOT,
# KEEP_SANDBOX (keep the run directory and print its path).
# Nothing here builds, downloads or installs anything.
set -u
set -m   # every background job gets its own process group

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_TIMEOUT="${INFRA_TEST_TIMEOUT:-120}"
DISCOVERY_TIMEOUT="${INFRA_DISCOVERY_TIMEOUT:-30}"
KILL_GRACE="${INFRA_KILL_GRACE:-5}"
bash_bin="${BASH:-$(command -v bash)}"

# Drop imported shell functions and startup hooks before anything is launched.
while IFS= read -r _f; do unset -f -- "$_f"; done < <(compgen -A function)
unset _f BASH_ENV ENV CDPATH GLOBIGNORE SB INFRA_TEST_ROOT

pattern='.'; list=0; verbose=0; files=(); explicit=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k) [[ $# -ge 2 ]] || { echo 'ERROR: -k needs a REGEX' >&2; exit 2; }; pattern="$2"; shift 2 ;;
    -l) list=1; shift ;;
    -v) verbose=1; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *) files+=("$1"); explicit=1; shift ;;
  esac
done
[[ "" =~ $pattern ]]; [[ $? -ne 2 ]] || { echo "ERROR: invalid -k regex: $pattern" >&2; exit 2; }

errors=0
err() { echo "ERROR: $*" >&2; errors=$((errors + 1)); }

mandatory=(test_pkgs_support.sh test_common.sh test_diagnostics.sh test_harness.sh test_make_pkgs.sh)
if [[ "$explicit" -eq 0 ]]; then
  for m in "${mandatory[@]}"; do
    [[ -e "$here/$m" ]] || err "mandatory test file missing: $here/$m"
  done
  shopt -s nullglob
  files=("$here"/test_*.sh)
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || err "no test files in $here"
fi
[[ -f "$here/lib.sh" && -s "$here/lib.sh" ]] || { echo "ERROR: missing $here/lib.sh" >&2; exit 2; }

# ---------------------------------------------------------------- run root
# A colon would split the controlled PATH built from sandbox paths (lib.sh),
# creating an unintended command search directory: refuse it up front.
case "${TMPDIR:-/tmp}" in
  *:*) echo "ERROR: unsupported TMPDIR (contains ':'): [${TMPDIR}]" >&2; exit 2 ;;
esac
run_root="$(mktemp -d "${TMPDIR:-/tmp}/crs-infra-run.XXXXXX")" || {
  echo 'ERROR: cannot allocate the run directory (mktemp -d failed)' >&2; exit 2; }
if [[ -z "$run_root" || "$run_root" != /* || ! -d "$run_root" || -L "$run_root" || ! -O "$run_root" ]]; then
  echo "ERROR: invalid run directory: [$run_root]" >&2; exit 2
fi
run_root="$(cd -P -- "$run_root" && pwd -P)" || { echo 'ERROR: cannot resolve run directory' >&2; exit 2; }
[[ "${run_root##*/}" == crs-infra-run.?* && -O "$run_root" && ! -L "$run_root" ]] || {
  echo "ERROR: unexpected run directory: [$run_root]" >&2; exit 2; }
if [[ "$run_root" == *:* ]]; then
  rmdir -- "$run_root"
  echo "ERROR: unsupported run directory path (contains ':'): [$run_root]" >&2; exit 2
fi

cur_pgid=''; wd_pid=''; cur_dir=''
cleanup_errors=0
# Remove a path this runner created.  Only DIRECT children of the physical
# run root are accepted, so no intermediate component can be a symlink.
remove_in_root() {
  local p="$1" name="${1##*/}"
  [[ "$p" == "$run_root/$name" && -n "$name" && "$name" != . && "$name" != .. ]] || {
    echo "refusing cleanup of [$p]" >&2; cleanup_errors=$((cleanup_errors + 1)); return 1; }
  [[ -e "$p" || -L "$p" ]] || return 0
  if [[ -d "$p" && ! -L "$p" ]]; then
    [[ -O "$p" ]] || { echo "refusing cleanup of foreign [$p]" >&2; cleanup_errors=$((cleanup_errors + 1)); return 1; }
    chmod -R u+rwx -- "$p" 2>/dev/null
    rm -rf -- "$p"
  else
    rm -f -- "$p"
  fi
  if [[ -e "$p" || -L "$p" ]]; then
    echo "ERROR: cleanup failed: [$p]" >&2; cleanup_errors=$((cleanup_errors + 1)); return 1
  fi
}
group_alive() { kill -0 -- "-$1" 2>/dev/null; }
sweep_group() {  # TERM, wait, KILL, wait; return 1 if members remain
  local g="$1" i
  group_alive "$g" || return 0
  kill -TERM -- "-$g" 2>/dev/null
  for ((i = 0; i < 30; i++)); do group_alive "$g" || return 0; sleep 0.1; done
  kill -KILL -- "-$g" 2>/dev/null
  for ((i = 0; i < 30; i++)); do group_alive "$g" || return 0; sleep 0.1; done
  return 1
}
stop_watchdog() {
  [[ -n "$wd_pid" ]] || return 0
  kill -TERM -- "-$wd_pid" 2>/dev/null
  wait "$wd_pid" 2>/dev/null
  wd_pid=''
}
reap_failed=0
reap_current() {  # sweep the current test's group and its registered groups
  local g
  stop_watchdog
  if [[ -n "$cur_pgid" ]]; then sweep_group "$cur_pgid" || reap_failed=1; fi
  if [[ -n "$cur_dir" && -f "$cur_dir/.pgids" ]]; then
    while IFS= read -r g; do
      [[ "$g" =~ ^[1-9][0-9]*$ ]] || continue
      sweep_group "$g" || reap_failed=1
    done < "$cur_dir/.pgids"
  fi
  cur_pgid=''
}
# Mandatory cleanup; returns 1 if anything could not be reaped or removed.
cleanup_run() {
  reap_current
  [[ "$reap_failed" -eq 0 ]] || { echo 'ERROR: processes could not be reaped' >&2; cleanup_errors=$((cleanup_errors + 1)); }
  if [[ -n "${KEEP_SANDBOX:-}" ]]; then
    echo "kept run directory: $run_root"
  else
    chmod -R u+rwx -- "$run_root" 2>/dev/null
    [[ "${run_root##*/}" == crs-infra-run.?* ]] && rm -rf -- "$run_root"
    if [[ -e "$run_root" || -L "$run_root" ]]; then
      echo "ERROR: cleanup failed: run directory remains: [$run_root]" >&2
      cleanup_errors=$((cleanup_errors + 1))
    fi
  fi
  [[ "$cleanup_errors" -eq 0 ]]
}
# Exit status: an existing failure status is kept; a cleanup failure turns an
# otherwise successful run (or listing) into exit 3.
on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if ! cleanup_run && [[ "$rc" -eq 0 ]]; then rc=3; fi
  exit "$rc"
}
on_signal() {
  trap - INT TERM HUP
  echo "INTERRUPTED: stopping current test and cleaning up" >&2
  trap - EXIT
  cleanup_run
  exit "$1"
}
trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# supervise SECS DIR OUT -- cmd...: run in its own process group; sets
# SUP_RC and SUP_TIMED_OUT, then sweeps the group (and registered groups).
supervise() {
  local secs="$1" dir="$2" out="$3"; shift 4
  local flag="$run_root/.timeout.$$.$RANDOM"
  rm -f -- "$flag"
  cur_dir="$dir"
  reap_failed=0
  "$@" < /dev/null > "$out" 2>&1 &
  cur_pgid=$!
  ( trap - INT TERM HUP
    sleep "$secs"; : > "$flag"
    kill -TERM -- "-$cur_pgid" 2>/dev/null
    sleep "$KILL_GRACE"
    kill -KILL -- "-$cur_pgid" 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
  wd_pid=$!
  SUP_RC=0
  wait "$cur_pgid" 2>/dev/null || SUP_RC=$?
  stop_watchdog
  SUP_TIMED_OUT=0
  [[ -e "$flag" ]] && { SUP_TIMED_OUT=1; rm -f -- "$flag"; }
  reap_current
  cur_dir=''
}

# ----------------------------------------------------------------- discovery
declare -a t_files=() t_names=()
declare -A seen=()
seq_no=0
new_dir() {  # create a fresh numbered directory inside run_root
  seq_no=$((seq_no + 1))
  NEW_DIR="$run_root/$seq_no"
  mkdir -- "$NEW_DIR" || { echo "ERROR: cannot create $NEW_DIR" >&2; exit 2; }
}
for f in "${files[@]}"; do
  if [[ ! -f "$f" || ! -r "$f" || ! -s "$f" ]]; then
    err "test file missing, empty or unreadable: $f"; continue
  fi
  new_dir
  d="$NEW_DIR"
  # The whole discovery step - syntax check, sourcing, listing and sorting -
  # runs inside one supervised, deadline-bounded process.  Its stdout/stderr
  # (file $d.discovery) must stay EMPTY: diagnostics are reported through
  # fd 4 ($d.diag); the sorted names go to $d.names.
  supervise "$DISCOVERY_TIMEOUT" "$d" "$d.discovery" -- \
    "$bash_bin" --noprofile --norc -c '
      exec 4>"$5"
      "$BASH" -n -- "$2" 2>&4 || { echo "syntax error in $2" >&4; exit 89; }
      source "$1" || { echo "lib.sh returned $?" >&4; exit 90; }
      source "$2"; rc=$?
      [[ $rc -eq 0 ]] || { echo "sourcing returned $rc" >&4; exit 91; }
      compgen -A function > "$3.raw" || { echo "compgen failed" >&4; exit 93; }
      LC_ALL=C sort -- "$3.raw" > "$4" || { echo "sort failed with status $?" >&4; exit 93; }
      mapfile -t raw < "$3.raw"; mapfile -t sorted < "$4"
      (( ${#raw[@]} == ${#sorted[@]} )) || { echo "sort lost names (${#raw[@]} -> ${#sorted[@]})" >&4; exit 94; }
      exit 0' _ "$here/lib.sh" "$f" "$d/names" "$d.names" "$d.diag"
  diag="$(cat -- "$d.diag" 2>/dev/null)"
  if [[ "$SUP_TIMED_OUT" -eq 1 ]]; then
    err "discovery of $f exceeded ${DISCOVERY_TIMEOUT}s"
  elif [[ "$SUP_RC" -ne 0 || "$reap_failed" -ne 0 ]]; then
    err "loading $f failed (exit $SUP_RC)${diag:+:$'\n'$diag}"$'\n'"$(cat -- "$d.discovery")"
  elif [[ -s "$d.discovery" ]]; then
    # byte size, not a newline-stripped string: a lone newline is output too
    err "loading $f failed: unexpected output ($(wc -c < "$d.discovery") byte(s)):"$'\n'"$(head -c 2000 -- "$d.discovery")"
  fi
  hard=0; found=()
  if [[ "$SUP_TIMED_OUT" -eq 0 && "$SUP_RC" -eq 0 && ! -s "$d.discovery" && "$reap_failed" -eq 0 ]]; then
    while IFS= read -r n; do
      [[ "$n" =~ ^[tk]_[A-Za-z0-9_]+$ ]] || continue
      found+=("$n")
      [[ "$n" == t_* ]] && hard=$((hard + 1))
    done < "$d.names"
    loaded=1
  else
    loaded=0
  fi
  remove_in_root "$d"; remove_in_root "$d.names"; remove_in_root "$d.discovery"; remove_in_root "$d.diag"
  [[ "$loaded" -eq 1 ]] || continue
  if [[ "$hard" -eq 0 ]]; then
    err "no t_* tests discovered in $f"; continue
  fi
  for n in "${found[@]}"; do
    if [[ -n "${seen[$n]:-}" ]]; then err "test $n defined in both ${seen[$n]} and $f"; continue; fi
    seen["$n"]="$f"
    if [[ "$n" =~ $pattern ]]; then t_files+=("$f"); t_names+=("$n"); fi
  done
done

if [[ "$list" -eq 1 ]]; then
  [[ ${#t_names[@]} -eq 0 ]] || printf '%s\n' "${t_names[@]}"
  [[ "$errors" -eq 0 ]] || { echo "ERROR: infrastructure suite discovery failed ($errors problem(s))" >&2; exit 1; }
  exit 0
fi
if [[ "$errors" -gt 0 ]]; then
  echo "ERROR: infrastructure suite discovery failed ($errors problem(s))" >&2
  exit 1
fi
if [[ ${#t_names[@]} -eq 0 ]]; then
  echo "ERROR: no infrastructure tests selected (pattern: $pattern)" >&2
  exit 1
fi

# ----------------------------------------------------------------- execution
echo "Testing: $(cd -- "${CRS_ROOT:-$here/../..}" && pwd)"
pass=0; failed=0; skipped=0; kd_rep=0; kd_not=0; kd_skip=0; kd_err=0
failed_names=()
show() { sed 's/^/        /' -- "$1" | head -n "$2"; }
for i in "${!t_names[@]}"; do
  f="${t_files[$i]}"; n="${t_names[$i]}"
  new_dir
  d="$NEW_DIR"
  supervise "$TEST_TIMEOUT" "$d" "$d.out" -- \
    env -u BASH_ENV -u ENV "INFRA_TEST_ROOT=$d" "$bash_bin" --noprofile --norc -c '
      set -u
      source "$1" || exit 90
      source "$2" || exit 91
      declare -F -- "$3" >/dev/null || exit 92
      "$3"' _ "$here/lib.sh" "$f" "$n"
  rc="$SUP_RC"
  why=''
  if [[ "$SUP_TIMED_OUT" -eq 1 ]]; then why="timed out after ${TEST_TIMEOUT}s (exit $rc)"
  elif [[ "$reap_failed" -ne 0 ]]; then why="left processes that could not be reaped"
  elif [[ "$rc" -ge 90 && "$rc" -le 92 ]]; then why="harness/load error (exit $rc)"
  elif [[ "$rc" -gt 128 ]]; then why="killed by signal $((rc - 128))"
  fi
  if [[ "$n" == k_* ]]; then
    if [[ -z "$why" && "$rc" -eq 0 ]]; then
      kd_rep=$((kd_rep + 1)); echo "KNOWN-DEFECT-REPRODUCED      $n"
    elif [[ -z "$why" && "$rc" -eq 77 ]]; then
      kd_skip=$((kd_skip + 1)); echo "KNOWN-DEFECT-SKIPPED         $n"
    elif [[ -z "$why" && "$rc" -eq 1 ]]; then
      kd_not=$((kd_not + 1)); echo "KNOWN-DEFECT-NOT-REPRODUCED  $n"
    else
      kd_err=$((kd_err + 1)); failed_names+=("$n")
      echo "KNOWN-DEFECT-ERROR           $n (${why:-exit $rc})"
    fi
    show "$d.out" 6
  elif [[ -z "$why" && "$rc" -eq 0 ]]; then
    pass=$((pass + 1)); echo "PASS  $n"
    [[ "$verbose" -eq 0 ]] || show "$d.out" 1000
  elif [[ -z "$why" && "$rc" -eq 77 ]]; then
    skipped=$((skipped + 1)); echo "SKIP  $n"; show "$d.out" 4
  else
    failed=$((failed + 1)); failed_names+=("$n"); echo "FAIL  $n (${why:-exit $rc})"
    show "$d.out" 40
  fi
  if [[ -z "${KEEP_SANDBOX:-}" ]]; then
    remove_in_root "$d" || { failed=$((failed + 1)); failed_names+=("$n:cleanup"); }
    remove_in_root "$d.out" || { failed=$((failed + 1)); failed_names+=("$n:cleanup"); }
  fi
done
echo
echo "passed: $pass   failed: $failed   skipped: $skipped   known-defects-reproduced: $kd_rep   known-defects-not-reproduced: $kd_not   known-defects-skipped: $kd_skip   known-defects-errors: $kd_err"
[[ ${#failed_names[@]} -eq 0 ]] || { echo "failed: ${failed_names[*]}"; exit 1; }
exit 0

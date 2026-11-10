# Self-tests of the infrastructure runner and lib.sh safety guarantees.
#
# Most tests copy the runner and lib.sh into the sandbox together with tiny
# synthetic test files, then run that copy with its own TMPDIR ($SB/stmp).
# Synthetic tests record process ids in $PIDDIR so this test can verify that
# the nested runner terminated and reaped them and removed its run directory.
# Every nested invocation is bounded by GNU timeout and registered for the
# outer runner's sweep.  Nothing here touches the scripts under test, except
# the M3 checks, which run a few real characterization tests under unusual
# TMPDIR paths.

# suite_new: copy runner + lib into $SB/suite with trivial mandatory files.
suite_new() {
  sandbox_new
  SUITE="$SB/suite"; PIDDIR="$SB/pids"
  mkdir -p "$SUITE" "$PIDDIR" "$SB/stmp"
  cp -- "$INFRA_HERE/run-infrastructure-tests.sh" "$INFRA_HERE/lib.sh" "$SUITE/"
  local f
  for f in common diagnostics harness make_pkgs; do
    printf 't_%s_ok() { :; }\n' "$f" > "$SUITE/test_$f.sh"
  done
}

# host_bounded SECS [NAME=value...] -- cmd...: run on the host PATH (not the
# controlled environment) under timeout; registered; sets RC, OUT.
host_bounded() {
  local secs="$1"; shift
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  ( exec "$TIMEOUT_BIN" -k 5 "$secs" "$ENV_BIN" -u BASH_ENV -u ENV -u INFRA_TEST_ROOT "${envs[@]}" "$@" ) \
    < /dev/null > "$SB/.run/host.out" 2>&1 &
  local p=$!
  [[ -z "${INFRA_TEST_ROOT:-}" ]] || printf '%s\n' "$p" >> "$INFRA_TEST_ROOT/.pgids"
  RC=0
  wait "$p" || RC=$?
  drain_group "$p"
  OUT="$(< "$SB/.run/host.out")"
}

# run_suite [NAME=value...] -- [runner args...]
run_suite() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  host_bounded "${SUITE_TIMEOUT:-90}" "TMPDIR=$SB/stmp" "PIDDIR=$PIDDIR" "${envs[@]}" -- \
    "$BASH_BIN" "$SUITE/run-infrastructure-tests.sh" "$@"
}

pid_gone() {  # pid_gone PID: wait up to 3 s for the process to disappear
  local i
  for ((i = 0; i < 30; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}
assert_pids_gone() {
  local f p
  for f in "$@"; do
    [[ -s "$PIDDIR/$f" ]] || fail "pid file $f was not written"
    p="$(< "$PIDDIR/$f")"
    pid_gone "$p" || { kill -KILL "$p" 2>/dev/null; fail "process $f ($p) survived the runner"; }
  done
}
assert_run_dir_removed() {
  assert_eq '' "$(ls -A "$SB/stmp")" 'nested runner left files in its TMPDIR'
}

# --------------------------------------------------------------- H4: loading

t_harness_syntax_error_after_valid_definition_fails() {
  suite_new
  printf 't_common_ok() { :; }\nif true; then\n' > "$SUITE/test_common.sh"
  run_suite --
  assert_rc 1 "$RC" 'suite must fail'
  assert_contains "$OUT" "syntax error in $SUITE/test_common.sh"
  assert_not_contains "$OUT" 'PASS  t_common_ok' 'earlier definition must not run'
  run_suite -- -l
  assert_rc 1 "$RC" 'listing must fail too'
  assert_run_dir_removed
}

t_harness_source_returning_nonzero_fails() {
  suite_new
  printf 't_common_ok() { :; }\nreturn 42\n' > "$SUITE/test_common.sh"
  run_suite --
  assert_rc 1 "$RC" 'suite must fail'
  assert_contains "$OUT" 'sourcing returned 42'
  assert_not_contains "$OUT" 'PASS  t_common_ok'
  run_suite -- -l
  assert_rc 1 "$RC" 'listing must fail too'
}

t_harness_failing_top_level_command_fails_even_if_masked() {
  # A failing command followed by a successful one leaves source status 0;
  # its diagnostic on stderr still rejects the file.
  suite_new
  printf 't_common_ok() { :; }\nno_such_command_xyz_12\ntrue\n' > "$SUITE/test_common.sh"
  run_suite --
  assert_rc 1 "$RC" 'suite must fail'
  assert_contains "$OUT" "loading $SUITE/test_common.sh failed"
  assert_contains "$OUT" 'command not found'
}

t_harness_hanging_discovery_is_bounded_and_reaped() {
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_ok() { :; }
echo "$$" > "$PIDDIR/discovery"
( exec sleep 300 ) & echo "$!" > "$PIDDIR/discovery-child"
sleep 300
EOF
  local t0=$SECONDS
  run_suite INFRA_DISCOVERY_TIMEOUT=2 INFRA_KILL_GRACE=1 --
  assert_rc 1 "$RC" 'suite must fail'
  assert_contains "$OUT" 'exceeded 2s'
  (( SECONDS - t0 < 30 )) || fail "discovery was not bounded ($((SECONDS - t0)) s)"
  assert_pids_gone discovery discovery-child
  assert_run_dir_removed
}

t_harness_missing_and_empty_mandatory_files_fail() {
  suite_new
  rm "$SUITE/test_diagnostics.sh"
  run_suite --
  assert_rc 1 "$RC" 'missing file'
  assert_contains "$OUT" "mandatory test file missing: $SUITE/test_diagnostics.sh"
  run_suite -- -l
  assert_rc 1 "$RC" 'missing file (listing)'
  printf 't_diagnostics_ok() { :; }\n' > "$SUITE/test_diagnostics.sh"
  : > "$SUITE/test_make_pkgs.sh"
  run_suite --
  assert_rc 1 "$RC" 'empty file'
  assert_contains "$OUT" "test file missing, empty or unreadable: $SUITE/test_make_pkgs.sh"
  printf 'k_make_pkgs_demo() { :; }\n' > "$SUITE/test_make_pkgs.sh"
  run_suite --
  assert_rc 1 "$RC" 'file without hard tests'
  assert_contains "$OUT" "no t_* tests discovered in $SUITE/test_make_pkgs.sh"
}

t_harness_conventional_extra_file_is_discovered() {
  suite_new
  printf 't_extra_fails() { false; }\n' > "$SUITE/test_extra.sh"
  run_suite --
  assert_rc 1 "$RC" 'failing extra test must gate'
  assert_contains "$OUT" 'FAIL  t_extra_fails'
  # explicit file arguments load only those files
  run_suite -- "$SUITE/test_common.sh"
  assert_rc 0 "$RC" "explicit selection ($OUT)"
  assert_not_contains "$OUT" t_extra_fails
}

t_harness_duplicate_test_names_are_rejected() {
  suite_new
  printf 't_common_ok() { :; }\n' > "$SUITE/test_diagnostics.sh"
  run_suite --
  assert_rc 1 "$RC" 'duplicate'
  assert_contains "$OUT" 'test t_common_ok defined in both'
}

t_harness_invalid_arguments_are_rejected() {
  suite_new
  run_suite -- -k '('
  assert_rc 2 "$RC" 'invalid regex'
  run_suite -- --bogus
  assert_rc 2 "$RC" 'unknown option'
  run_suite -- -k 'no_such_test_name'
  assert_rc 1 "$RC" 'empty selection'
  assert_contains "$OUT" 'no infrastructure tests selected'
}

# ------------------------------------------- H1: supervision and cleanup

t_harness_children_of_a_failing_test_are_reaped() {
  # Reproduces review H1: a test fails while its background workers (and an
  # orphaned grandchild reparented away from the test) are still running.
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_fails_early() {
  sandbox_new
  ( exec sleep 300 ) & echo "$!" > "$PIDDIR/child"
  ( ( exec sleep 300 ) & echo "$!" > "$PIDDIR/orphan" ) &
  bash -c 'sleep 300 & echo "$!" > "$PIDDIR/grandchild"; wait' &
  printf '%s\n' "$SB" > "$PIDDIR/sandbox"
  sleep 0.5
  fail 'early failure with workers still running'
}
EOF
  run_suite --
  assert_rc 1 "$RC" 'failing test'
  assert_contains "$OUT" 'FAIL  t_common_fails_early (exit 1)'
  assert_pids_gone child orphan grandchild
  assert_absent "$(< "$PIDDIR/sandbox")" 'failed test sandbox removed'
  assert_run_dir_removed
}

t_harness_term_ignoring_test_is_killed_and_cleaned_by_supervisor() {
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_ignores_term() {
  sandbox_new
  trap '' TERM
  echo "$$" > "$PIDDIR/test"
  printf '%s\n' "$SB" > "$PIDDIR/sandbox"
  : > "$SB/tmp/leftover"
  ( exec sleep 300 ) & echo "$!" > "$PIDDIR/child"
  sleep 300
}
# Runs next (sorted): the killed test's sandbox must already be gone, i.e.
# removed per test by the supervisor, not only at the end of the run.
t_common_next_test_sees_cleanup() {
  [[ ! -e "$(< "$PIDDIR/sandbox")" ]] || fail 'previous test sandbox still present'
}
EOF
  local t0=$SECONDS
  run_suite INFRA_TEST_TIMEOUT=2 INFRA_KILL_GRACE=1 --
  assert_rc 1 "$RC" 'timed-out test gates'
  assert_contains "$OUT" 'FAIL  t_common_ignores_term (timed out after 2s'
  assert_contains "$OUT" 'PASS  t_common_next_test_sees_cleanup' 'per-test cleanup before the next test'
  (( SECONDS - t0 < 30 )) || fail 'kill escalation took too long'
  assert_pids_gone test child
  assert_absent "$(< "$PIDDIR/sandbox")" 'sandbox of a SIGKILLed test removed by the runner'
  assert_run_dir_removed
}

t_harness_registered_timeout_groups_are_swept_after_kill() {
  # run_ctl/spawn_ctl commands run in GNU timeout's own process group; the
  # runner must sweep those groups too when the test itself is killed.
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_spawns_bounded_group() {
  sandbox_new
  spawn_ctl "$SB/.run/x" -t 300 -- sleep 300
  echo "$SPAWN_PID" > "$PIDDIR/group"
  trap '' TERM
  sleep 300
}
EOF
  run_suite INFRA_TEST_TIMEOUT=2 INFRA_KILL_GRACE=1 --
  assert_rc 1 "$RC" 'timed out'
  local g; g="$(< "$PIDDIR/group")"
  local i
  for ((i = 0; i < 30; i++)); do kill -0 -- "-$g" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 -- "-$g" 2>/dev/null || { kill -KILL -- "-$g" 2>/dev/null; fail "registered group $g survived"; }
  assert_run_dir_removed
}

t_harness_interrupted_runner_reaps_current_test_and_cleans() {
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_long() {
  sandbox_new
  echo "$$" > "$PIDDIR/test"
  ( exec sleep 300 ) & echo "$!" > "$PIDDIR/child"
  printf '%s\n' "$SB" > "$PIDDIR/sandbox"
  sleep 300
}
EOF
  local sig
  for sig in TERM INT; do
    rm -f -- "$PIDDIR"/*
    local -a pre=()
    if [[ "$sig" == INT ]]; then
      # Background jobs start with SIGINT ignored; restore it for the runner.
      "$ENV_BIN" --default-signal=INT true 2>/dev/null || { echo "env --default-signal unsupported; INT case skipped"; continue; }
      pre=("$ENV_BIN" --default-signal=INT)
    fi
    ( exec "$TIMEOUT_BIN" -k 5 60 "$ENV_BIN" "TMPDIR=$SB/stmp" "PIDDIR=$PIDDIR" \
        "${pre[@]}" "$BASH_BIN" "$SUITE/run-infrastructure-tests.sh" ) < /dev/null > "$SB/.run/int.out" 2>&1 &
    local p=$! i
    printf '%s\n' "$p" >> "$INFRA_TEST_ROOT/.pgids"
    for ((i = 0; i < 100; i++)); do [[ -s "$PIDDIR/sandbox" ]] && break; sleep 0.1; done
    [[ -s "$PIDDIR/sandbox" ]] || fail "$sig: nested test never started: $(cat "$SB/.run/int.out")"
    # signal the runner itself (timeout's only child)
    local runner; runner="$(ps -o pid= --ppid "$p" 2>/dev/null | tr -d ' ' | head -n 1)"
    [[ -n "$runner" ]] || skip 'cannot locate the nested runner process (ps --ppid unsupported)'
    kill -"$sig" "$runner"
    RC=0; wait "$p" || RC=$?
    drain_group "$p"
    OUT="$(< "$SB/.run/int.out")"
    [[ "$RC" -ne 0 ]] || fail "$sig: interrupted runner reported success"
    assert_contains "$OUT" 'INTERRUPTED' "$sig: interruption message"
    assert_pids_gone test child
    assert_absent "$(< "$PIDDIR/sandbox")" "$sig: sandbox removed"
    assert_run_dir_removed
  done
}

# ---------------------------------------------------- H2: sandbox allocation

# _fresh_lib_bash SCRIPT [NAME=value...]: run SCRIPT in a new bash that has
# sourced lib.sh with nounset, as a test process would.
_fresh_lib_bash() {
  local script="$1"; shift
  host_bounded 20 "MARK=$SB/body-ran" "$@" -- "$BASH_BIN" --noprofile --norc -c \
    'set -u; source "$1"; '"$script" _ "$INFRA_HERE/lib.sh"
}

t_harness_failing_mktemp_aborts_before_the_test_body() {
  sandbox_new
  mkdir "$SB/failbin" "$SB/emptybin" "$SB/rootbin"
  printf '#!/bin/sh\nexit 1\n' | write_exe "$SB/failbin/mktemp"
  printf '#!/bin/sh\nexit 0\n' | write_exe "$SB/emptybin/mktemp"
  printf '#!/bin/sh\necho /\n' | write_exe "$SB/rootbin/mktemp"
  local case_ expect
  for case_ in "failbin:mktemp -d failed" "emptybin:mktemp -d returned an empty path" \
               "rootbin:sandbox root is not an owned directory"; do
    _fresh_lib_bash 'sandbox_new; touch "$MARK"' "PATH=$SB/${case_%%:*}:$PATH"
    assert_rc 90 "$RC" "${case_%%:*}: harness abort"
    expect="${case_#*:}"
    assert_contains "$OUT" "HARNESS-ERROR: $expect" "${case_%%:*}: diagnostic"
    assert_absent "$SB/body-ran" "${case_%%:*}: test body must not run"
  done
}

t_harness_invalid_runner_supplied_root_aborts() {
  sandbox_new
  mkdir "$SB/real"; ln -s real "$SB/link"
  local root
  for root in "$SB/does-not-exist" "$SB/link" relative/path /; do
    _fresh_lib_bash 'sandbox_new; touch "$MARK"' "INFRA_TEST_ROOT=$root"
    assert_rc 90 "$RC" "root [$root] rejected"
    assert_absent "$SB/body-ran" "body must not run for [$root]"
  done
  assert_eq '' "$(ls -A "$SB/real")" 'nothing created through the symlink'
}

t_harness_sb_is_unset_not_empty_before_allocation() {
  _fresh_lib_bash_nosb() {
    host_bounded 20 -- "$BASH_BIN" --noprofile --norc -c \
      'set -u; source "$1"; printf "%s\n" "$SB/x"; echo reached' _ "$INFRA_HERE/lib.sh"
  }
  sandbox_new
  SB_SAVED="$SB"
  _fresh_lib_bash_nosb
  [[ "$RC" -ne 0 ]] || fail 'use of SB before sandbox_new must abort'
  assert_contains "$OUT" 'SB: unbound variable'
  assert_not_contains "$OUT" reached
  assert_not_contains "$OUT" '/x' 'no path was built from an empty SB'
}

t_harness_runner_run_directory_allocation_failure_is_fatal() {
  suite_new
  mkdir "$SB/failbin"
  printf '#!/bin/sh\nexit 1\n' | write_exe "$SB/failbin/mktemp"
  run_suite "PATH=$SB/failbin:$PATH" --
  assert_rc 2 "$RC" 'fatal'
  assert_contains "$OUT" 'cannot allocate the run directory'
  assert_not_contains "$OUT" PASS
}

t_harness_safe_rm_tree_refuses_unsafe_paths() {
  sandbox_new
  local r="$SB/root" outside="$SB/outside"
  mkdir -p "$r/ok/sub" "$outside/keep"
  ln -s "$outside" "$r/link"
  local p
  for p in '' / "$r" "$r/../outside" "$r/./ok" "$outside" "$r/link" relative; do
    safe_rm_tree "$r" "$p" 2>/dev/null && fail "accepted unsafe path [$p]"
  done
  safe_rm_tree '' "$r/ok" 2>/dev/null && fail 'accepted an empty root'
  safe_rm_tree / /tmp 2>/dev/null && fail 'accepted / as root'
  assert_exists "$outside/keep" 'outside tree intact'
  assert_exists "$r/ok/sub" 'nothing removed yet'
  safe_rm_tree "$r" "$r/ok" || fail 'refused a valid path'
  assert_absent "$r/ok" 'valid path removed'
  assert_exists "$r/link" 'symlink left alone'
}

# --------------------------------------------- outcome classification

t_harness_known_defect_and_skip_outcomes_are_classified() {
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_ok() { :; }
t_common_skips() { skip 'not available'; }
k_common_reproduced() { :; }
k_common_unavailable() { skip 'prerequisite missing'; }
k_common_not_reproduced() { fail 'defect gone'; }
EOF
  run_suite --
  assert_rc 0 "$RC" "non-gating outcomes ($OUT)"
  assert_contains "$OUT" 'KNOWN-DEFECT-REPRODUCED      k_common_reproduced'
  assert_contains "$OUT" 'KNOWN-DEFECT-SKIPPED         k_common_unavailable'
  assert_contains "$OUT" 'KNOWN-DEFECT-NOT-REPRODUCED  k_common_not_reproduced'
  assert_contains "$OUT" 'SKIP  t_common_skips'
  assert_contains "$OUT" 'known-defects-reproduced: 1   known-defects-not-reproduced: 1   known-defects-skipped: 1   known-defects-errors: 0'
}

t_harness_broken_known_defect_demos_and_signals_gate() {
  suite_new
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_ok() { :; }
t_common_segv() { kill -SEGV "$$"; }
k_common_crashes() { exit 5; }
k_common_hangs() { sleep 300; }
k_common_harness() { sandbox_new; sandbox_new; }
EOF
  run_suite INFRA_TEST_TIMEOUT=2 INFRA_KILL_GRACE=1 --
  assert_rc 1 "$RC" 'errors gate'
  assert_contains "$OUT" 'KNOWN-DEFECT-ERROR           k_common_crashes (exit 5)'
  assert_contains "$OUT" 'KNOWN-DEFECT-ERROR           k_common_hangs (timed out after 2s'
  assert_contains "$OUT" 'KNOWN-DEFECT-ERROR           k_common_harness (harness/load error (exit 90))'
  assert_contains "$OUT" 'FAIL  t_common_segv (killed by signal 11)'
  assert_run_dir_removed
}

# ------------------------------------------------- M3: unusual temp paths

t_harness_real_tests_pass_under_unusual_tmpdir_paths() {
  # Representative real tests under TMPDIRs containing a space, apostrophe,
  # tab and (second run) a newline.  Diagnostics tests skip under a newline
  # because .pc files cannot represent it; a colon is unsupported (PATH).
  sandbox_new
  local sel='^(t_common_trash_put_and_empty_removes_paths|t_common_lock_run_success_passes_arguments_and_releases|t_common_lock_contention_blocks_until_release|t_pkgs_autotools_exact_argv_hook_order_and_kinds|t_pkgs_success_cleans_temp_files_work_dirs_and_generated_configs|t_diag_valid_package_reports_only_header|t_diag_symlinked_root_reports_false_location_mismatch)$'
  local odd1="$SB/odd dir/it's"$'\t'"x" odd2="$SB/new"$'\n'"line/it's dir"
  mkdir -p -- "$odd1" "$odd2"
  host_bounded 240 "TMPDIR=$odd1" -- "$BASH_BIN" "$INFRA_HERE/run-infrastructure-tests.sh" -k "$sel"
  assert_rc 0 "$RC" "apostrophe/space/tab TMPDIR ($OUT)"
  assert_contains "$OUT" 'passed: 7   failed: 0   skipped: 0'
  assert_eq '' "$(ls -A "$odd1")" 'run directory removed (apostrophe path)'
  host_bounded 240 "TMPDIR=$odd2" -- "$BASH_BIN" "$INFRA_HERE/run-infrastructure-tests.sh" -k "$sel"
  assert_rc 0 "$RC" "newline TMPDIR ($OUT)"
  assert_contains "$OUT" 'passed: 5   failed: 0   skipped: 2'
  assert_contains "$OUT" 'sandbox path contains a newline'
  assert_eq '' "$(ls -A "$odd2")" 'run directory removed (newline path)'
}

# ------------------------------------- final verification findings N1 - N5

# _probe_suite: one passing and one failing test in test_common.sh
_probe_suite() {
  suite_new
  printf 't_common_probe_a() { :; }\nt_common_probe_b() { fail probe_b; }\n' > "$SUITE/test_common.sh"
}

t_harness_n1_failing_sort_fails_discovery() {
  # Review N1: a sort that drops the failing test, emits the rest and exits
  # 42 must not produce a green, incomplete suite.
  _probe_suite
  local real_sort; real_sort="$(command -v sort)"
  mkdir "$SB/sortbin"
  printf '#!/bin/sh\n%s "$@" | grep -v "^t_common_probe_b$"\nexit 42\n' "$real_sort" | write_exe "$SB/sortbin/sort"
  run_suite "PATH=$SB/sortbin:$PATH" --
  assert_rc 1 "$RC" 'failed sort must fail the suite'
  assert_contains "$OUT" 'sort failed with status 42'
  assert_not_contains "$OUT" 'PASS  t_common_probe_a' 'no test runs from a partial list'
  run_suite "PATH=$SB/sortbin:$PATH" -- -l
  assert_rc 1 "$RC" 'listing fails too'
  # A sort that "succeeds" but drops a name is caught by the count check.
  printf '#!/bin/sh\n%s "$@" | grep -v "^t_common_probe_b$"\nexit 0\n' "$real_sort" | write_exe "$SB/sortbin/sort"
  run_suite "PATH=$SB/sortbin:$PATH" --
  assert_rc 1 "$RC" 'silently lossy sort must fail the suite'
  assert_contains "$OUT" 'sort lost names'
  assert_run_dir_removed
}

t_harness_n1_slow_sort_is_bounded_by_discovery_deadline() {
  _probe_suite
  local real_sort; real_sort="$(command -v sort)"
  mkdir "$SB/sortbin"
  printf '#!/bin/sh\necho $$ > "$PIDDIR/sort"\nsleep 30\nexec %s "$@"\n' "$real_sort" | write_exe "$SB/sortbin/sort"
  local t0=$SECONDS
  run_suite "PATH=$SB/sortbin:$PATH" INFRA_DISCOVERY_TIMEOUT=2 INFRA_KILL_GRACE=1 --
  assert_rc 1 "$RC" 'stuck sort must fail discovery'
  assert_contains "$OUT" 'exceeded 2s'
  (( SECONDS - t0 < 25 )) || fail "sorting was not bounded ($((SECONDS - t0)) s)"
  assert_pids_gone sort
  assert_run_dir_removed
}

t_harness_n2_safe_rm_tree_rejects_intermediate_symlink() {
  # Review N2, exact layout: guard-root/alias -> guard-outside, and
  # safe_rm_tree guard-root guard-root/alias/victim must not delete anything.
  sandbox_new
  local root="$SB/review/guard-root" outside="$SB/review/guard-outside"
  mkdir -p "$root" "$outside/victim"
  : > "$outside/victim/sentinel"
  ln -s "$outside" "$root/alias"
  safe_rm_tree "$root" "$root/alias/victim" 2>"$SB/err" && fail 'intermediate symlink accepted'
  assert_exists "$outside/victim/sentinel" 'sentinel outside the root survives'
  assert_contains "$(cat "$SB/err")" 'symlinked or unresolvable ancestor'
  # deeper chains and a symlinked root are rejected as well
  mkdir -p "$outside/victim/deeper"
  safe_rm_tree "$root" "$root/alias/victim/deeper" 2>/dev/null && fail 'deeper path through symlink accepted'
  ln -s guard-root "$SB/review/root-link"
  mkdir -p "$root/inside"
  safe_rm_tree "$SB/review/root-link" "$SB/review/root-link/inside" 2>/dev/null && fail 'symlinked root accepted'
  assert_exists "$outside/victim/deeper" 'outside tree intact'
  assert_exists "$root/inside" 'nothing removed through a symlinked root'
  # an ordinary contained path is still removed
  safe_rm_tree "$root" "$root/inside" || fail 'refused a physically contained path'
  assert_absent "$root/inside"
}

t_harness_n3_colon_tmpdir_is_rejected_before_any_command() {
  # Review N3: a colon in TMPDIR would split the controlled PATH and expose
  # an outside directory.  A harmless recording "clang" waits there.
  suite_new
  mkdir -p "$SB/colon" "$SB/colon:tmp"
  printf '#!/bin/sh\necho "clang $*" >> "%s/escape.log"\n' "$SB" | write_exe "$SB/colon/clang"
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_calls_clang() {
  sandbox_new
  run_ctl -- "$BASH_BIN" --noprofile --norc -c 'clang --version'
}
EOF
  run_suite "TMPDIR=$SB/colon:tmp" --
  assert_rc 2 "$RC" 'runner must refuse the TMPDIR'
  assert_contains "$OUT" "unsupported TMPDIR (contains ':')"
  assert_not_contains "$OUT" PASS
  assert_absent "$SB/escape.log" 'outside command never reached'
  assert_eq '' "$(ls -A "$SB/colon:tmp")" 'nothing created in the rejected TMPDIR'
  # lib.sh refuses it too, without the runner (fallback allocation) ...
  _fresh_lib_bash 'sandbox_new; touch "$MARK"; run_ctl -- "$BASH_BIN" -c "clang --version"' "TMPDIR=$SB/colon:tmp"
  assert_rc 90 "$RC" 'fallback sandbox must refuse'
  assert_contains "$OUT" "HARNESS-ERROR: unsupported TMPDIR (contains ':')"
  assert_absent "$SB/body-ran"; assert_absent "$SB/escape.log"
  assert_eq '' "$(ls -A "$SB/colon:tmp")" 'nothing created by the fallback either'
  # ... and a runner-supplied root containing a colon
  mkdir "$SB/colon:root"
  _fresh_lib_bash 'sandbox_new; touch "$MARK"' "INFRA_TEST_ROOT=$SB/colon:root"
  assert_rc 90 "$RC" 'colon root must be refused'
  assert_contains "$OUT" "unsupported sandbox path (contains ':')"
  assert_absent "$SB/body-ran"
  assert_eq '' "$(ls -A "$SB/colon:root")" 'no sandbox created inside the colon root'
}

# _rm_wrapper: rm that fails (88) for arguments whose basename matches
# RM_FAIL_BASENAME, and otherwise runs the real rm.
_rm_wrapper() {
  local real_rm; real_rm="$(command -v rm)"
  mkdir -p "$SB/rmbin"
  cat > "$SB/rmbin/rm" <<EOF
#!$BASH_BIN
for a; do
  case "\${a##*/}" in \$RM_FAIL_BASENAME) echo "INJECTED CLEANUP FAILURE: \$a" >&2; exit 88 ;; esac
done
exec $(printf '%q' "$real_rm") "\$@"
EOF
  chmod +x "$SB/rmbin/rm"
}

t_harness_n4_final_cleanup_failure_is_never_green() {
  suite_new
  _rm_wrapper
  # passing run whose final run-directory removal fails -> exit 3
  run_suite "PATH=$SB/rmbin:$PATH" 'RM_FAIL_BASENAME=crs-infra-run.*' --
  assert_rc 3 "$RC" 'cleanup failure must turn success into failure'
  assert_contains "$OUT" 'INJECTED CLEANUP FAILURE'
  assert_contains "$OUT" 'cleanup failed: run directory remains'
  run_suite "PATH=$SB/rmbin:$PATH" 'RM_FAIL_BASENAME=crs-infra-run.*' -- -l
  assert_rc 3 "$RC" 'listing with failed cleanup is not green'
  # an existing failure status is preserved, not replaced
  printf 't_common_ok() { :; }\nt_common_bad() { fail bad; }\n' > "$SUITE/test_common.sh"
  run_suite "PATH=$SB/rmbin:$PATH" 'RM_FAIL_BASENAME=crs-infra-run.*' --
  assert_rc 1 "$RC" 'original failure status kept'
  assert_contains "$OUT" 'FAIL  t_common_bad'
  assert_contains "$OUT" 'cleanup failed: run directory remains'
  # discovery-file cleanup failures also count
  printf 't_common_ok() { :; }\n' > "$SUITE/test_common.sh"
  run_suite "PATH=$SB/rmbin:$PATH" 'RM_FAIL_BASENAME=*.discovery' --
  assert_rc 3 "$RC" 'discovery cleanup failure is not green'
  # leftovers are inside this sandbox and are removed with it by the runner
}

t_harness_n5_newline_only_source_output_fails_discovery() {
  suite_new
  local where
  for where in '' '>&2'; do
    printf 't_common_ok() { :; }\nprintf "\\n" %s\n' "$where" > "$SUITE/test_common.sh"
    run_suite --
    assert_rc 1 "$RC" "newline-only output [$where] must fail"
    assert_contains "$OUT" "loading $SUITE/test_common.sh failed: unexpected output (1 byte(s))"
    assert_not_contains "$OUT" 'PASS  t_common_ok'
  done
  assert_run_dir_removed
}

t_harness_n1_every_discovered_test_runs_despite_later_sort_misbehavior() {
  # Sorting happens once per file, inside the supervised discovery step.  A
  # sort that behaves on its first call for an input but drops the failing
  # test (exit 42) on any later call must not change the outcome: an
  # unchecked second sort outside discovery would silently lose t_common_probe_b.
  _probe_suite
  local real_sort; real_sort="$(command -v sort)"
  mkdir "$SB/sortbin"
  cat > "$SB/sortbin/sort" <<EOF
#!/bin/sh
for last; do :; done
key=\$(printf '%s' "\$last" | tr '/ ' '__')
if [ -e "\$PIDDIR/sort.\$key" ]; then
  $real_sort "\$@" | grep -v '^t_common_probe_b\$'; exit 42
fi
: > "\$PIDDIR/sort.\$key"
exec $real_sort "\$@"
EOF
  chmod +x "$SB/sortbin/sort"
  run_suite "PATH=$SB/sortbin:$PATH" --
  assert_rc 1 "$RC" 'the failing probe must still gate'
  assert_contains "$OUT" 'PASS  t_common_probe_a'
  assert_contains "$OUT" 'FAIL  t_common_probe_b' 'no discovered test may be dropped'
}

t_harness_runner_cleanup_does_not_follow_a_swapped_test_root() {
  # A test replaces its own per-test directory with a symlink to an outside
  # directory.  The runner removes the symlink only, never the target.
  suite_new
  mkdir -p "$SB/outside/keep"; : > "$SB/outside/keep/sentinel"
  cat > "$SUITE/test_common.sh" <<'EOF'
t_common_swaps_root() {
  rm -rf -- "${INFRA_TEST_ROOT:?}" && ln -s -- "$OUTSIDE" "$INFRA_TEST_ROOT"
}
EOF
  run_suite "OUTSIDE=$SB/outside" -- "$SUITE/test_common.sh"
  assert_rc 0 "$RC" "swap test ($OUT)"
  assert_exists "$SB/outside/keep/sentinel" 'outside target untouched'
  assert_run_dir_removed
}

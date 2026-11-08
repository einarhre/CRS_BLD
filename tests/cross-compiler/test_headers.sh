# shellcheck shell=bash
# Completion cache: real GNU make dependency evaluation with fake compilation
# recipes (see use_real_make_fixture in lib_completion.sh).
#
# MinGW-w64 14.0.0 installs placeholder pthread_{signal,time,unistd}.h
# (84/82/84 bytes) which winpthreads later overwrites with the full versions
# (1304/4768/5012 bytes).  Replaying the stage sequence on a completed tree
# therefore rewrites the headers (twice, with different content) and make
# rebuilds every dependent object, although nothing changed.  `install -C`
# cannot prevent that: the content really differs at each step.

fx_sandbox() {
  new_sandbox
  use_real_make_fixture
  default_sources
}

# ---- fixture self-checks (hold for any implementation) ------------------------

t_000_header_fixture_completed_sysroots_hold_full_headers() {
  fx_sandbox
  build_ok "$CCV"
  local t
  for t in "$T32" "$T64"
  do
    assert_full_headers "$(hdr_dir cross "$t")" "cross sysroot"
    assert_full_headers "$(hdr_dir native "$t")" "native sysroot"
  done
  assert_packaged
  assert_eq "$(count cc 1 | awk '$1 > 0 {print "compiled"}')" compiled "the fixture compiled objects"
}

# The placeholder/full transition, driven by hand with the fixture's make.
t_000_header_fixture_placeholder_full_transition_and_install_C() {
  fx_sandbox
  build_ok "$CCV"
  local dir ref="$SB/hdr.ref" h
  dir="$(hdr_dir cross "$T32")"
  touch -r "$dir/pthread_time.h" "$ref"
  # Identical content: install -C leaves the file alone.
  fx_make "cross/$T32/winpthreads" install
  [[ ! "$dir/pthread_time.h" -nt "$ref" && ! "$ref" -nt "$dir/pthread_time.h" ]] \
    || fail "install -C rewrote an identical header"
  # stage 2 again: the placeholders come back and are newer ...
  fx_make "cross/$T32/mingw-w64-headers" install
  assert_placeholder_headers "$dir"
  [[ "$dir/pthread_time.h" -nt "$ref" ]] || fail "placeholder header is not newer than the full one"
  # ... and stage 6 restores the full content, again with a new mtime.
  touch -r "$dir/pthread_time.h" "$ref"
  fx_make "cross/$T32/winpthreads" install
  assert_full_headers "$dir"
  for h in $HDR_NAMES
  do
    [[ "$dir/$h" -nt "$ref" || "$(hdr_sizes "$dir")" == "$HDR_FULL_SIZES" ]] || true
  done
  [[ "$dir/pthread_time.h" -nt "$ref" ]] \
    || fail "full header restored by winpthreads did not get a new mtime (content-aware install -C cannot help here)"
}

t_000_header_fixture_header_flip_invalidates_dependent_objects() {
  fx_sandbox
  build_ok "$CCV"
  : > "$LOG"
  fx_make "cross/$T32/mingw-w64-headers" install
  fx_make "cross/$T32/mingw-w64" all
  fx_make "cross/$T32/gcc" all
  fx_make "cross/$T32/binutils" all
  assert_eq "$(awk -F'\t' '$1=="cc" && $2 ~ /mingw-w64$/' "$LOG" | wc -l | tr -d ' ')" 3 "CRT objects rewritten by make"
  assert_eq "$(awk -F'\t' '$1=="cc" && $2 ~ /\/gcc$/' "$LOG" | wc -l | tr -d ' ')" 3 "gcc library objects rewritten by make"
  assert_eq "$(awk -F'\t' '$1=="cc" && $2 ~ /\/binutils$/' "$LOG" | wc -l | tr -d ' ')" 0 "binutils has no header dependency"
}

t_000_header_fixture_interrupted_compile_failure_injection() {
  fx_sandbox
  run_crs "MOCK_FAIL=cc:cross/$T32/mingw-w64:obj2.o" -- "$CCV"
  assert_rc_nonzero "compile failure"
  assert_no_file "$PREF/build/cross/$T32/mingw-w64/obj2.o" "the failed object"
  assert_file "$PREF/build/cross/$T32/mingw-w64/obj1.o" "objects compiled before the failure are kept"
}

# ---- demonstration on the implementation under test -----------------------------

# Not a pass/fail test: reports how much work an unchanged completed repeat does.
d_unchanged_completed_repeat_rewrites_objects() {
  fx_sandbox
  build_ok "$CCV"
  local first
  first="$(objects_rewritten 1)"
  build_ok "$CCV"
  local second; second="$(objects_rewritten 2)"
  local third; build_ok "$CCV"; third="$(objects_rewritten 3)"
  echo "objects compiled by the first build: $first; by an unchanged completed repeat: $second; by a second one: $third"
  echo "make invocations in the repeat: $(count make 2); zip invocations: $(count zip 2); configure: $(count configure 2)"
  [[ "$second" -gt 0 ]]
}

# ---- completion cache -------------------------------------------------------------

t_hdr_unchanged_repeat_rewrites_no_objects() {
  fx_sandbox
  build_ok "$CCV"
  plant_sentinels                                # changes the tree: record it again
  build_ok "$CCV"
  discover_records
  hdr_remember
  cc_expect_hit
  assert_eq "$(objects_rewritten "$RUNNO")" 0 "objects rewritten by an unchanged completed repeat"
  assert_hdr_mtimes_unchanged
  assert_sentinels_intact
}

t_hdr_two_unchanged_repeats_rewrite_no_objects() {
  fx_sandbox
  build_ok "$CCV"
  discover_records
  hdr_remember
  cc_expect_hit
  assert_eq "$(objects_rewritten "$RUNNO")" 0 "objects rewritten by the first repeat"
  cc_expect_hit
  assert_eq "$(objects_rewritten "$RUNNO")" 0 "objects rewritten by the second repeat"
  assert_hdr_mtimes_unchanged
}

t_hdr_repeat_never_leaves_placeholder_headers() {
  fx_sandbox
  build_ok "$CCV"
  local t i
  for i in 1 2
  do
    build_ok "$CCV"
    for t in "$T32" "$T64"
    do
      assert_full_headers "$(hdr_dir cross "$t")" "cross sysroot after repeat $i"
      assert_full_headers "$(hdr_dir native "$t")" "native sysroot after repeat $i"
    done
  done
}

# First target complete, second interrupted: the retry must not rewrite the
# first target's objects (its headers must not be flipped again either).
t_hdr_second_target_interruption_keeps_first_target_objects() {
  fx_sandbox
  run_crs "MOCK_FAIL=make:cross/$T64/gcc:all-gcc" -- "$CCV"
  assert_rc_nonzero "first run"
  hdr_remember
  run_ref -- "$CCV"
  assert_rc0 "retry"
  assert_eq "$(lines cc "$RUNNO" | awk -F'\t' -v t="$T32" 'index($2, t)' | wc -l | tr -d ' ')" 0 \
    "objects of the finished first target rewritten by the retry"
  assert_target_idle "$RUNNO" "$T32"
  assert_full_headers "$(hdr_dir cross "$T64")"
  assert_full_headers "$(hdr_dir native "$T64")"
  assert_packaged
  # and once the second target is done as well, everything is idle
  discover_records
  cc_expect_hit
  assert_eq "$(objects_rewritten "$RUNNO")" 0
}

# Interrupted compilation: the retry completes the build, and only then is the
# target recorded as complete.
t_hdr_interrupted_compilation_is_not_recorded_as_complete() {
  fx_sandbox
  run_crs "MOCK_FAIL=cc:cross/$T32/gcc:lib2.o" -- "$CCV"
  assert_rc_nonzero "interrupted compilation"
  run_crs -- "$CCV"
  assert_rc0 "retry"
  assert_packaged
  discover_records
  assert_records_per_target
  cc_expect_hit
  assert_eq "$(objects_rewritten "$RUNNO")" 0
}

# A modified target is recovered by the existing procedure; the other target
# is left alone and the sysroots end with the full headers.
t_hdr_modified_target_recovers_and_other_target_untouched() {
  fx_sandbox
  build_ok "$CCV"
  discover_records
  cc_expect_hit
  echo extra > "$PREF/install/native/$T32/bin/added-by-test.txt"
  run_ref -- "$CCV"
  assert_rc0 "repeat after a change"
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_idle "$RUNNO" "$T64"
  assert_eq "$(lines cc "$RUNNO" | awk -F'\t' -v t="$T64" 'index($2, t)' | wc -l | tr -d ' ')" 0 \
    "objects of the unchanged target rewritten"
  assert_full_headers "$(hdr_dir cross "$T32")"
  assert_full_headers "$(hdr_dir native "$T32")"
  cc_expect_hit
  assert_eq "$(objects_rewritten "$RUNNO")" 0 "objects rewritten once the target was recorded again"
}

# A header that is back to its full content is still a change for make: mtime
# differs.  A cache hit must therefore not depend on make at all, and a replay
# must still be possible (the fixture's make works on the stale tree).
t_hdr_missing_record_replays_even_though_artifacts_are_complete() {
  fx_sandbox
  build_ok "$CCV"
  discover_records
  assert_records_per_target
  each_record "$T32" rm -f --
  run_crs -- "$CCV"
  assert_rc0 "repeat without a record"
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_idle "$RUNNO" "$T64"
  assert_full_headers "$(hdr_dir cross "$T32")"
  cc_expect_hit
}

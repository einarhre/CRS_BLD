# shellcheck shell=bash
# R6: repeated DLL relocation, installation and packaging.
#
# These tests run with MOCK_MV_TOLERANT=0 (strict mv) and MOCK_DLL_MODE=keep
# (an install that does not recreate an already relocated DLL), so a second
# relocation of the same DLL meets the file already at its destination.

STRICT=(MOCK_MV_TOLERANT=0 MOCK_DLL_MODE=keep)

t_r6_dll_relocated_to_bin_per_target() {
  new_sandbox; default_sources
  build_ok 13.2.0 "${STRICT[@]}"
  assert_file "$PREF/install/native/$T32/bin/libgcc_s_sjlj-1.dll"
  assert_no_file "$PREF/install/native/$T32/bin/libgcc_s_seh-1.dll"
  assert_file "$PREF/install/native/$T64/bin/libgcc_s_seh-1.dll"
  assert_no_file "$PREF/install/native/$T64/bin/libgcc_s_sjlj-1.dll"
  assert_no_file "$PREF/install/native/$T32/$T32/lib/libgcc_s_sjlj-1.dll" "moved, not copied"
}

t_r6_missing_dll_is_an_error() {
  new_sandbox; default_sources
  run_crs MOCK_DLL_MODE=nodll -- 13.2.0
  assert_rc_nonzero
  assert_output_matches 'missing.*libgcc_s_sjlj-1\.dll'
  assert_eq "$(lines make 1 | awk -F'\t' -v r="native/$T32/mingw-w64" '$2==r' | wc -l | tr -d ' ')" 0 \
    "no later stages after the missing DLL"
  assert_no_file "$PREF/install/native/$T32.zip"
}

# DLL already at its destination (finished earlier run, nothing recreates it).
t_r6_repeated_invocation_after_complete_build_succeeds() {
  new_sandbox; default_sources
  build_ok 13.2.0 "${STRICT[@]}"
  touch "$PREF/install/native/$T32/recovery-trigger" # Require replay.
  run_crs "${STRICT[@]}" -- 13.2.0
  assert_rc0 "second invocation after a successful build"
  assert_packaged
}

# Failure after the DLL was relocated (stage 9), then the same command again.
t_r6_retry_after_failure_following_dll_relocation() {
  new_sandbox; default_sources
  run_crs "${STRICT[@]}" "MOCK_FAIL=make:native/$T32/mingw-w64:all" -- 13.2.0
  assert_rc_nonzero "first run"
  assert_file "$PREF/install/native/$T32/bin/libgcc_s_sjlj-1.dll"
  run_crs "${STRICT[@]}" -- 13.2.0
  assert_rc0 "retry must cope with the DLL already in bin/"
  assert_packaged
}

# First target complete, failure in the second, then retry (the first target's
# stages are revisited, including DLL relocation).
t_r6_retry_after_second_target_failure_revisits_first_target() {
  new_sandbox; default_sources
  run_crs "${STRICT[@]}" "MOCK_FAIL=make:cross/$T64/gcc:all-gcc" -- 13.2.0
  assert_rc_nonzero "first run"
  touch "$PREF/install/native/$T32/recovery-trigger" # Require replay.
  run_crs "${STRICT[@]}" -- 13.2.0
  assert_rc0 "retry"
  assert_packaged
}

# ---- packaging --------------------------------------------------------------

t_r6_package_format_and_target_architecture() {
  new_sandbox; default_sources
  build_ok 13.2.0
  assert_packaged
  grep -q "^$T32/bin/" "$PREF/install/native/$T32.zip" || fail "i686 package content"
  grep -q "^$T64/bin/" "$PREF/install/native/$T64.zip" || fail "x86_64 package content"
  ! grep -q "^$T64/" "$PREF/install/native/$T32.zip" || fail "packages must not mix targets"
}

# Final archive state: absent or a complete archive, never a partial one.
assert_no_partial_archive() { # target
  local z="$PREF/install/native/$1.zip"
  if [[ -e "$z" ]]
  then
    [[ "$(head -n 1 "$z")" == MOCKZIP ]] || fail "partial/corrupt archive left at its final name: $z"
  fi
}

# First-time packaging failure (no earlier archive for the target).
check_zip_interruption_recovers() { # target
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=zip:$1" -- 13.2.0
  assert_rc_nonzero "first run (packaging interrupted)"
  assert_output_matches 'simulated interruption' "test bug: zip failure was not injected"
  assert_no_partial_archive "$1"
  assert_output_matches "pack|zip|archive|$1" "diagnostic mentions the packaging failure"
  plant_sentinels
  run_crs -- 13.2.0
  assert_rc0 "second run"
  assert_packaged
  assert_sentinels_intact
}
t_r6_interrupted_packaging_first_target_recovers() { check_zip_interruption_recovers "$T32"; }
t_r6_interrupted_packaging_second_target_recovers() { check_zip_interruption_recovers "$T64"; }

# Packaging fails although a previous valid archive exists: that archive must
# stay byte-for-byte unchanged and must not list the changes that failed to be
# packed.  The same command afterwards produces the correct archive.
check_zip_failure_keeps_previous_archive() { # target
  local t="$1" other
  new_sandbox; default_sources
  build_ok 13.2.0
  assert_packaged
  cp "$PREF/install/native/$t.zip" "$SB/previous.zip"
  for other in "$T32" "$T64"; do [[ "$other" == "$t" ]] || break; done
  cp "$PREF/install/native/$other.zip" "$SB/other.zip"
  echo new > "$PREF/install/native/$t/bin/added-after-first-build.txt"
  run_crs "MOCK_FAIL=zip:$t" -- 13.2.0
  assert_rc_nonzero "run whose packaging of $t fails"
  assert_output_matches 'simulated interruption' "test bug: zip failure was not injected"
  assert_file "$PREF/install/native/$t.zip" "previous archive removed by the failed run"
  assert_same_snapshot "$SB/previous.zip" "$PREF/install/native/$t.zip" \
    "previous valid archive was modified by a failed packaging run"
  if grep -q 'added-after-first-build' "$PREF/install/native/$t.zip"
  then
    fail "previous archive claims to contain files that were never packed"
  fi
  # the install tree itself is untouched by the failure
  assert_file "$PREF/install/native/$t/bin/added-after-first-build.txt"
  assert_file "$PREF/install/native/$t/bin/$(dll_for "$t")"
  run_crs -- 13.2.0
  assert_rc0 "repeat after the packaging failure"
  assert_packaged
  grep -q "added-after-first-build" "$PREF/install/native/$t.zip" \
    || fail "repeated build did not produce the up-to-date archive"
}
t_r6_failed_packaging_keeps_previous_archive_first_target() { check_zip_failure_keeps_previous_archive "$T32"; }
t_r6_failed_packaging_keeps_previous_archive_second_target() { check_zip_failure_keeps_previous_archive "$T64"; }

# A failure while packaging the second target must not disturb the finished
# archive of the first target (and the first target is not rebuilt).
t_r6_second_target_packaging_failure_keeps_first_archive() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=zip:$T64" -- 13.2.0
  assert_rc_nonzero "first run"
  assert_eq "$(head -n 1 "$PREF/install/native/$T32.zip")" MOCKZIP "first target archive is complete"
  cp "$PREF/install/native/$T32.zip" "$SB/first.zip"
  assert_no_partial_archive "$T64"
  run_crs -- 13.2.0
  assert_rc0 "second run"
  assert_packaged
  assert_eq "$(lines make 2 | awk -F'\t' -v t="$T32" 'index($2,t) && $5=="built"' | wc -l | tr -d ' ')" 0 \
    "first target must not be recompiled"
}

# The archive is created at a staging path and only then put under its final
# name (never written to the final name directly).
t_r6_zip_writes_to_staging_path() {
  new_sandbox; default_sources
  build_ok 13.2.0
  local t line args operand
  for t in "$T32" "$T64"
  do
    line="$(lines zip 1 | awk -F'\t' -v t="$t" '$3 ~ (t "$")')"
    args="$(printf '%s' "$line" | cut -f3)"
    operand="$(printf '%s\n' "$args" | awk '{print $3}')"
    operand="${operand/@PREF@/$PREF}"
    [[ "$operand" == /* ]] || operand="$PREF/install/native/$operand"
    [[ "${operand%.zip}.zip" != "$PREF/install/native/$t.zip" ]] \
      || fail "zip writes straight to the final archive $operand (no staging)"
    assert_file "$PREF/install/native/$t.zip" "staged archive was never published"
  done
}

# Staging leaves no stray archives in the final install location.
t_r6_no_staging_leftovers_after_success() {
  new_sandbox; default_sources
  build_ok 13.2.0
  find "$PREF/install/native" -maxdepth 1 -type f | LC_ALL=C sort > "$SB/native.files"
  assert_eq "$(cat "$SB/native.files")" "$(printf '%s\n%s' "$PREF/install/native/$T32.zip" "$PREF/install/native/$T64.zip" | LC_ALL=C sort)" \
    "files next to the final archives"
}

# ---- DLL precedence -----------------------------------------------------------

# A freshly installed DLL outside bin/ replaces a stale copy already in bin/.
check_fresh_dll_replaces_stale() { # extra-env...
  local t f
  new_sandbox; default_sources
  build_ok 13.2.0 "$@"
  for t in "$T32" "$T64"
  do
    echo STALE > "$PREF/install/native/$t/bin/$(dll_for "$t")"
  done
  run_crs "$@" MOCK_DLL_MODE=reinstall MOCK_DLL_CONTENT=FRESH -- 13.2.0
  assert_rc0 "run installing a fresh DLL over a stale bin copy"
  for t in "$T32" "$T64"
  do
    f="$PREF/install/native/$t/bin/$(dll_for "$t")"
    assert_eq "$(cat "$f")" FRESH "bin/ DLL of $t must be the freshly installed one"
    assert_no_file "$PREF/install/native/$t/$t/lib/$(dll_for "$t")" "fresh DLL moved, not copied"
    grep -q "^$t/bin/$(dll_for "$t")\$" "$PREF/install/native/$t.zip" || fail "package lacks the DLL"
  done
}
t_r6_fresh_dll_takes_precedence_over_stale_bin_copy() { check_fresh_dll_replaces_stale "${STRICT[@]}"; }
t_r6_fresh_dll_precedence_with_tolerant_mv() { check_fresh_dll_replaces_stale MOCK_MV_TOLERANT=1; }

# Stale copy in bin/ and nothing newly installed: the existing DLL is kept.
t_r6_existing_bin_dll_kept_when_nothing_reinstalled() {
  new_sandbox; default_sources
  build_ok 13.2.0 "${STRICT[@]}"
  echo KEPT > "$PREF/install/native/$T32/bin/$(dll_for "$T32")"
  run_crs "${STRICT[@]}" -- 13.2.0
  assert_rc0
  assert_eq "$(cat "$PREF/install/native/$T32/bin/$(dll_for "$T32")")" KEPT
}

t_r6_repeated_packaging_is_stable() {
  new_sandbox; default_sources
  build_ok 13.2.0
  cp "$PREF/install/native/$T32.zip" "$SB/first.zip"
  rm -- "$PREF/build/.cross-complete-$T32" # Repackage identical artifacts.
  build_ok 13.2.0
  assert_same_snapshot "$SB/first.zip" "$PREF/install/native/$T32.zip" "package changed on repeat"
  assert_packaged
}

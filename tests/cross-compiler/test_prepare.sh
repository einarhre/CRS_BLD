# shellcheck shell=bash
# R2: source preparation and its recovery.

t_r2_fresh_preparation_complete() {
  new_sandbox; default_sources
  build_ok 13.2.0
  assert_sources_ready 13.2.0
  assert_eq "$(count prereq 1)" 1 "prerequisites downloaded once"
}

# The gcc symlink alone is not evidence of finished preparation: here the link
# and an extracted gcc tree exist, but prerequisites were never fetched and
# binutils/mingw-w64 were never prepared.
t_r2_gcc_symlink_alone_is_not_preparation() {
  new_sandbox; default_sources
  craft_sources 13.2.0 no
  rm -f "$PREF/src/cpl/binutils" "$PREF/src/cpl/mingw-w64"
  sb_rm "$PREF"/src/cpl/binutils-2.42 "$PREF"/src/cpl/mingw-w64-v11.0.0
  run_crs -- 13.2.0
  assert_rc0 "run with only a gcc symlink present"
  assert_sources_ready 13.2.0
  assert_packaged
}

# Interrupted while fetching gcc prerequisites (after the gcc link exists).
t_r2_interrupted_prerequisite_download_is_redone() {
  new_sandbox; default_sources
  run_crs MOCK_FAIL=prereq -- 13.2.0
  assert_rc_nonzero "first run (prerequisite download fails)"
  assert_eq "$(count make 1)" 0 "no build may start on unprepared sources"
  run_crs -- 13.2.0
  assert_rc0 "second run"
  assert_eq "$(count prereq 2)" 1 "prerequisite download repeated"
  assert_sources_ready 13.2.0
  assert_packaged
}

# Interrupted while (re)creating the build/install directory skeleton, after the
# sources are complete.
t_r2_interrupted_build_skeleton_creation_is_redone() {
  new_sandbox; default_sources
  run_crs MOCK_MKDIR_FAIL_MATCH=/build/ -- 13.2.0
  assert_rc_nonzero "first run (directory creation interrupted)"
  run_crs -- 13.2.0
  assert_rc0 "second run"
  assert_packaged
}

# Interrupted while switching versions (binutils archive unreadable) and the
# user then retries the version that was previously prepared.
t_r2_interrupted_version_switch_then_retry_previous_version() {
  new_sandbox; default_sources
  build_ok 13.2.0
  cp "$PREF/src/cpl/binutils-2.42.tar.gz" "$SB/binutils.good"
  echo "not an archive" > "$PREF/src/cpl/binutils-2.42.tar.gz"
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- 14.1.0
  assert_rc_nonzero "switch with corrupt binutils archive"
  # Safety (not wording): nothing built or configured, artifacts untouched,
  # and the message points at the cause.
  assert_eq "$(count make 2)" 0 "no build after the failed switch"
  assert_eq "$(count configure 2)" 0 "no configuration after the failed switch"
  snapshot_dir "$PREF/build" "$SB/build.after"
  assert_same_snapshot "$SB/build.before" "$SB/build.after" "failed switch must not modify build artifacts"
  assert_output_matches 'binutils' "diagnostic names the unusable binutils archive"
  cp "$SB/binutils.good" "$PREF/src/cpl/binutils-2.42.tar.gz"
  run_crs -- 13.2.0
  assert_rc0 "retry of previous version"
  assert_sources_ready 13.2.0
}

check_corrupt_archive_then_fix() { # archive-file-name
  new_sandbox; default_sources
  cp "$PREF/src/cpl/$1" "$SB/good.archive"
  echo "not an archive" > "$PREF/src/cpl/$1"
  run_crs -- 13.2.0
  assert_rc_nonzero "corrupt $1"
  # The diagnostic must identify the unusable archive (no fixed wording).
  assert_output_matches "${1//./\\.}" "diagnostic names the corrupt archive $1"
  assert_eq "$(count make 1)" 0 "no build after failed extraction"
  cp "$SB/good.archive" "$PREF/src/cpl/$1"
  run_crs -- 13.2.0
  assert_rc0 "run after repairing $1"
  assert_sources_ready 13.2.0
  assert_packaged
}
t_r2_corrupt_mingw_archive_recovers() { check_corrupt_archive_then_fix mingw-w64-v11.0.0.tar.gz; }
t_r2_corrupt_binutils_archive_recovers() { check_corrupt_archive_then_fix binutils-2.42.tar.gz; }
t_r2_corrupt_gcc_archive_recovers() { check_corrupt_archive_then_fix gcc-13.2.0.tar.gz; }

# A locally maintained gcc-git checkout must survive building a release.
t_r2_gcc_git_checkout_survives_release_build() {
  new_sandbox; default_sources
  add_gcc_git_checkout
  build_ok 13.2.0
  assert_file "$PREF/src/cpl/gcc-git/LOCAL_WORK" "gcc-git checkout destroyed"
}

# Selected archive identities: if the newest mingw-w64 / binutils archive no
# longer matches what the existing trees were configured from, the old results
# may not be reused silently.
t_r2_newer_mingw_archive_not_silently_ignored() {
  populate_state 13.2.0
  snapshot_dir "$PREF/build" "$SB/build.before"
  add_mingw_archive 12.0.0
  run_crs -- 13.2.0
  assert_safe_input_change "$SB/build.before" "mingw-w64-v12.0.0" \
    "cross/$T32/mingw-w64-headers cross/$T32/mingw-w64 cross/$T32/winpthreads native/$T32/mingw-w64 cross/$T64/mingw-w64-headers cross/$T64/mingw-w64 cross/$T64/winpthreads native/$T64/mingw-w64"
}
t_r2_newer_binutils_archive_not_silently_ignored() {
  populate_state 13.2.0
  snapshot_dir "$PREF/build" "$SB/build.before"
  add_binutils_archive 2.43
  run_crs -- 13.2.0
  assert_safe_input_change "$SB/build.before" "binutils-2.43" \
    "cross/$T32/binutils native/$T32/binutils cross/$T64/binutils native/$T64/binutils"
}

# Switching gcc version must not reuse trees configured for the other version.
t_r2_gcc_version_switch_does_not_reuse_stale_trees() {
  populate_state 13.2.0
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- 14.1.0
  assert_safe_input_change "$SB/build.before" "gcc-14.1.0" \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
}

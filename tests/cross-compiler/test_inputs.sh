# shellcheck shell=bash
# R5: changed and unchanged build inputs.

t_r5_changing_only_job_count_keeps_build() {
  new_sandbox; default_sources
  build_ok 13.2.0 NCRS=2
  plant_sentinels
  snapshot_build_artifacts "$SB/build.before"
  run_crs NCRS=5 -- 13.2.0
  assert_rc0 "replay with different NCRS"
  assert_target_replayed 2 "$T32"
  assert_target_replayed 2 "$T64"
  assert_eq "$(git_mutation_count 2)" 0 "no source refresh"
  assert_eq "$(lines make 2 | awk -F'\t' '$5=="built"' | wc -l | tr -d ' ')" 0 "nothing recompiled"
  assert_eq "$(count configure 2)" 0 "different -j must not trigger reconfiguration"
  assert_eq "$(count prereq 2)" 0 "different -j must not trigger source preparation"
  snapshot_build_artifacts "$SB/build.after"
  assert_same_snapshot "$SB/build.before" "$SB/build.after" "build tree must be untouched"
  assert_sentinels_intact
  lines make 2 | awk -F'\t' '$4!=""{print $4}' | sort -u > "$SB/jobs"
  assert_eq "$(cat "$SB/jobs")" 5 "recovery used the new job count"
  run_crs NCRS=7 -- 13.2.0
  assert_rc0 "completed repeat with another job count"
  assert_run_idle 3
  assert_sentinels_intact
}

t_r5_decreasing_job_count_keeps_build() {
  new_sandbox; default_sources
  build_ok 13.2.0 NCRS=8
  plant_sentinels
  run_crs NCRS=1 -- 13.2.0
  assert_rc0
  assert_eq "$(count configure 2)" 0
  assert_sentinels_intact
}

# Build configuration changed (the configure options in the script): a tree
# configured with the old options may not be reused silently.
t_r5_changed_gcc_languages_not_silently_reused() {
  new_sandbox; default_sources
  build_ok 13.2.0
  plant_sentinels
  snapshot_dir "$PREF/build" "$SB/build.before"
  make_script_variant 's/--enable-languages=c,c++,fortran/--enable-languages=c,c++/'
  run_crs -- 13.2.0
  assert_safe_input_change "$SB/build.before" 'gcc-13\.2\.0' \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
  if [[ "$RC" -eq 0 ]]
  then
    lines configure "$RUNNO" | awk -F'\t' '$3=="gcc"{print $5}' | grep -q 'enable-languages=c,c++$' \
      || fail "gcc was not configured with the new language list"
  fi
}

t_r5_changed_binutils_options_not_silently_reused() {
  new_sandbox; default_sources
  build_ok 13.2.0
  plant_sentinels
  snapshot_dir "$PREF/build" "$SB/build.before"
  make_script_variant 's/--without-zstd/--with-zstd/'
  run_crs -- 13.2.0
  assert_safe_input_change "$SB/build.before" 'binutils-2\.42' \
    "native/$T32/binutils native/$T64/binutils"
}

# Compatibility cannot be established (a tree from before any bookkeeping
# existed): it must not be deleted merely for that reason.
t_r5_tree_of_unknown_provenance_is_not_deleted() {
  new_sandbox; default_sources
  craft_sources 13.2.0 yes
  craft_build_tree
  local rel
  for rel in $(all_rels); do echo "compiled object for $rel" > "$PREF/build/$rel/artifact.o"; echo "$rel" >> "$SB/sentinels.list"; done
  run_crs -- 13.2.0
  if [[ "$RC" -ne 0 ]]
  then
    assert_output_matches 'compat|chang|differ|mismatch|stale|reus|inconsist|unknown|incomplete' "rejection must explain itself"
  fi
  assert_sentinels_intact "pre-existing build artifact (provenance unknown)"
}

# Rejection after the user removed the gcc symlink is NOT required (the original
# documents that as the way to force a clean rebuild); see report.

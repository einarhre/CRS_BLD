# shellcheck shell=bash
# Git source policy ("git" instead of a release version).
#
#   * A fresh build fetches the GCC sources from upstream.
#   * If compatible build/installation artifacts exist, the verified checkout
#     and its pinned commit are reused: nothing is fetched and no source
#     timestamp changes.
#   * An old checkout may be replaced for a fresh build, but valuable build and
#     installation artifacts are never deleted, and artifacts with
#     incompatible inputs are never silently reused.
#
# The simulated upstream is advanced between runs, so any fetch is visible as
# a changed commit id or changed checkout contents.

UP1=aaaa1111
UP2=bbbb2222

# Give every file of a tree an old timestamp, and create a reference file
# that is newer than those but older than "now".
age_tree() { # dir
  find "$1" -exec touch -h -t 200001010000 {} +
  touch -t 200101010000 "$SB/ref-time"
}
assert_tree_timestamps_unchanged() { # dir message
  local newer
  newer="$(find "$1" -newer "$SB/ref-time" | head -n 3)"
  [[ -z "$newer" ]] || fail "${2:-source timestamps changed}: $newer"
}

# ---- fresh builds fetch from upstream ------------------------------------------

t_git_fresh_build_fetches_upstream() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  build_ok git
  assert_eq "$(git_head)" "$UP1" "checkout is at the upstream commit"
  assert_eq "$(cat "$PREF/src/cpl/gcc-git/UPSTREAM_REV")" "$UP1" "checkout has the upstream contents"
  assert_link "$PREF/src/cpl/gcc" gcc-git
  assert_sources_ready git
  [[ "$(git_mutation_count 1)" -ge 1 ]] || fail "nothing was fetched from upstream"
  lines configure 1 | awk -F'\t' '$3=="gcc"{print $4}' | sort -u > "$SB/gcc.ids"
  assert_eq "$(cat "$SB/gcc.ids")" gcc-git "gcc configured from the git sources"
  assert_packaged
}

t_git_fresh_build_replaces_old_checkout_with_upstream() {
  new_sandbox; default_sources
  add_gcc_git_checkout old00000
  add_git_upstream "$UP1"
  build_ok git
  assert_eq "$(git_head)" "$UP1" "old checkout was not refreshed from upstream"
  assert_eq "$(cat "$PREF/src/cpl/gcc-git/UPSTREAM_REV")" "$UP1"
  assert_sources_ready git
  assert_packaged
}

# A fresh build over leftover empty directory scaffolding is still fresh.
t_git_fresh_build_after_interrupted_skeleton_creation() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  run_crs MOCK_MKDIR_FAIL_MATCH=/install/ -- git
  assert_rc_nonzero "first run (directory creation interrupted)"
  run_crs -- git
  assert_rc0 "second run"
  assert_sources_ready git
  assert_packaged
}

# ---- failed fetch / preparation ------------------------------------------------

check_clone_failure() { # MOCK_FAIL value
  new_sandbox; default_sources
  add_gcc_git_checkout old00000
  add_git_upstream "$UP1"
  snapshot_dir "$PREF/src/cpl/gcc-git" "$SB/gcc-git.before"
  run_crs "MOCK_FAIL=$1" -- git
  assert_rc_nonzero "run whose fetch fails"
  assert_output_matches 'git|clone|fetch|fatal' "diagnostic mentions the failed fetch"
  assert_eq "$(count make 1)" 0 "no build on missing sources"
  assert_eq "$(count configure 1)" 0 "no configuration on missing sources"
  # the old checkout (possibly holding local work) is not lost on a failed fetch
  snapshot_dir "$PREF/src/cpl/gcc-git" "$SB/gcc-git.after"
  assert_same_snapshot "$SB/gcc-git.before" "$SB/gcc-git.after" "old checkout damaged by a failed fetch"
  assert_no_file "$PREF/src/cpl/gcc-git/PARTIAL_CLONE" "partial clone published"
  run_crs -- git
  assert_rc0 "same command once the network works"
  assert_eq "$(git_head)" "$UP1"
  assert_no_file "$PREF/src/cpl/gcc-git/PARTIAL_CLONE" "partial clone published"
  assert_sources_ready git
  assert_packaged
}
t_git_failed_clone_keeps_old_checkout_and_recovers() { check_clone_failure git-clone; }
t_git_partial_clone_is_not_used_and_recovers() { check_clone_failure git-clone-partial; }

t_git_partial_clone_without_old_checkout_recovers() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  run_crs MOCK_FAIL=git-clone-partial -- git
  assert_rc_nonzero "first run"
  assert_eq "$(count make 1)" 0
  assert_no_file "$PREF/src/cpl/gcc-git/PARTIAL_CLONE" "partial clone published"
  run_crs -- git
  assert_rc0 "second run"
  assert_eq "$(git_head)" "$UP1"
  assert_sources_ready git
  assert_packaged
}

t_git_prerequisite_failure_on_new_checkout_recovers() {
  new_sandbox; default_sources
  add_gcc_git_checkout old00000
  add_git_upstream "$UP1"
  run_crs MOCK_FAIL=prereq -- git
  assert_rc_nonzero "first run"
  assert_eq "$(count make 1)" 0 "no build on unprepared sources"
  assert_eq "$(count configure 1)" 0 "no configuration on unprepared sources"
  run_crs -- git
  assert_rc0 "second run"
  assert_eq "$(git_head)" "$UP1"
  assert_sources_ready git
  assert_packaged
}

# ---- continuation: compatible artifacts exist ------------------------------------

# Completed build, upstream moved on: running again changes nothing.
t_git_continuation_after_success_does_not_fetch_or_touch() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  build_ok git
  plant_sentinels
  set_upstream_commit "$UP2"
  age_tree "$PREF/src/cpl/gcc-git"
  snapshot_dir "$PREF/src" "$SB/src.before"
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- git
  assert_rc0 "repeated git build"
  assert_eq "$(git_mutation_count 2)" 0 "no fetch/clone/pull on continuation: $(git_mutations 2)"
  assert_eq "$(git_head)" "$UP1" "pinned commit changed"
  assert_eq "$(cat "$PREF/src/cpl/gcc-git/UPSTREAM_REV")" "$UP1" "checkout contents changed"
  assert_tree_timestamps_unchanged "$PREF/src/cpl/gcc-git" "source timestamps changed on continuation"
  snapshot_dir "$PREF/src" "$SB/src.after"
  snapshot_dir "$PREF/build" "$SB/build.after"
  assert_same_snapshot "$SB/src.before" "$SB/src.after" "source tree changed"
  assert_same_snapshot "$SB/build.before" "$SB/build.after" "build tree changed"
  assert_eq "$(count configure 2)" 0 "no reconfiguration"
  assert_eq "$(count prereq 2)" 0 "prerequisites downloaded again"
  assert_sentinels_intact
  assert_packaged
}

# Build interrupted part-way (after the first target finished), upstream moved on.
t_git_continuation_after_failed_build_does_not_fetch_or_touch() {
  local d
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  run_crs "MOCK_FAIL=make:cross/$T64/gcc:all-gcc" -- git
  assert_rc_nonzero "first run"
  assert_eq "$(git_head)" "$UP1"
  plant_sentinels
  set_upstream_commit "$UP2"
  age_tree "$PREF/src/cpl/gcc-git"
  run_crs -- git
  assert_rc0 "same command after the failure"
  assert_eq "$(git_mutation_count 2)" 0 "no fetch/clone/pull on continuation: $(git_mutations 2)"
  assert_eq "$(git_head)" "$UP1" "pinned commit changed"
  assert_eq "$(cat "$PREF/src/cpl/gcc-git/UPSTREAM_REV")" "$UP1" "checkout contents changed"
  assert_tree_timestamps_unchanged "$PREF/src/cpl/gcc-git" "source timestamps changed on continuation"
  while IFS= read -r d
  do
    assert_eq "$(configured_in_run "$d" 2)" 0 "build/$d was configured fine earlier"
  done < "$SB/sentinels.list"
  assert_eq "$(count prereq 2)" 0 "prerequisites downloaded again"
  assert_sentinels_intact "compatible build artifact"
  assert_packaged
}

# Interrupted installation of the very first component, then the same command.
t_git_continuation_after_first_stage_failure() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  run_crs "MOCK_FAIL=make:cross/$T32/binutils:install" -- git
  assert_rc_nonzero "first run"
  set_upstream_commit "$UP2"
  run_crs -- git
  assert_rc0 "same command after the failure"
  assert_packaged
  # whatever the policy for such an early state, the sources must be
  # consistent: the checkout is one complete upstream state, fully prepared.
  assert_sources_ready git
  case "$(git_head)" in "$UP1"|"$UP2") ;; *) fail "unexpected checkout commit $(git_head)" ;; esac
  assert_eq "$(cat "$PREF/src/cpl/gcc-git/UPSTREAM_REV")" "$(git_head)" "checkout contents match its commit"
}

# Early configure failure (only config.log exists).
t_git_recovery_after_early_configure_failure() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  run_crs "MOCK_FAIL=configure:cross/$T32/binutils" -- git
  assert_rc_nonzero "first run"
  set_upstream_commit "$UP2"
  run_crs -- git
  assert_rc0 "same command after the failure"
  assert_packaged
  assert_sources_ready git
  assert_eq "$(cat "$PREF/src/cpl/gcc-git/UPSTREAM_REV")" "$(git_head)" "checkout contents match its commit"
}

# ---- incompatible inputs are never silently reused -----------------------------------

# The user moved the checkout to another commit after the build.
t_git_commit_changed_after_build_not_silently_reused() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  build_ok git
  plant_sentinels
  echo cccc3333 > "$PREF/src/cpl/gcc-git/.git/FAKE_HEAD"
  snapshot_dir "$PREF/build" "$SB/build.before"
  snapshot_dir "$PREF/install" "$SB/install.before"
  run_crs -- git
  assert_safe_input_change "$SB/build.before" 'gcc-git' \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
  if [[ "$RC" -ne 0 ]]
  then
    snapshot_dir "$PREF/install" "$SB/install.after"
    assert_same_snapshot "$SB/install.before" "$SB/install.after" "rejected run changed installed files"
    assert_eq "$(git_head)" cccc3333 "rejected run moved the checkout"
    assert_eq "$(git_mutation_count "$RUNNO")" 0 "rejected run fetched: $(git_mutations "$RUNNO")"
    assert_sentinels_intact
  fi
}

# Artifacts of a release build, then "git": different gcc source.
t_git_request_after_release_build_not_silently_reused() {
  populate_state 13.2.0
  add_gcc_git_checkout old00000
  add_git_upstream "$UP1"
  snapshot_dir "$PREF/build" "$SB/build.before"
  snapshot_dir "$PREF/install" "$SB/install.before"
  run_crs -- git
  assert_safe_input_change "$SB/build.before" 'gcc-git' \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
  if [[ "$RC" -ne 0 ]]
  then
    snapshot_dir "$PREF/install" "$SB/install.after"
    assert_same_snapshot "$SB/install.before" "$SB/install.after" "rejected run changed installed files"
    assert_link "$PREF/src/cpl/gcc" gcc-13.2.0
    assert_sentinels_intact
  fi
}

# Artifacts of a git build, then a release: the git checkout must survive.
t_git_build_then_release_request_not_silently_reused() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  build_ok git
  plant_sentinels
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- 13.2.0
  assert_safe_input_change "$SB/build.before" 'gcc-13\.2\.0' \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
  assert_eq "$(git_head)" "$UP1" "git checkout lost or moved"
  [[ "$RC" -ne 0 ]] && assert_sentinels_intact
  return 0
}

# Artifacts exist but the checkout was removed: the upstream (now different) must
# not be quietly substituted.
t_git_missing_checkout_with_artifacts_not_silently_reused() {
  new_sandbox; default_sources
  add_git_upstream "$UP1"
  build_ok git
  plant_sentinels
  sb_rm "$PREF/src/cpl/gcc-git"
  set_upstream_commit "$UP2"
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- git
  assert_safe_input_change "$SB/build.before" 'gcc-git' \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
  [[ "$RC" -ne 0 ]] && assert_sentinels_intact
  return 0
}

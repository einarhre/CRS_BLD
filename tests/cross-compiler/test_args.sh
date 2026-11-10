# shellcheck shell=bash
# R1: command-line arguments, exact version matching, archive discovery, NCRS.

# Complete previous build of 14.1.0 with planted artifacts; then the given
# invocation must be rejected without touching anything.
expect_rejected_untouched() { # [VAR=val ...] -- args...
  snapshot_pref "$SB/snap.before"
  run_crs "$@"
  assert_rc_nonzero "invalid invocation"
  snapshot_pref "$SB/snap.after"
  assert_same_snapshot "$SB/snap.before" "$SB/snap.after" \
    "invalid invocation modified sources/build/install trees"
  assert_run_idle "$RUNNO"
}

check_arg_rejected() { # argument
  populate_state 14.1.0
  expect_rejected_untouched -- "$1"
}

t_r1_no_arguments_prints_usage() {
  new_sandbox; default_sources
  run_crs --
  assert_rc_nonzero
  assert_output_matches 'usage'
  assert_output_matches '13\.2\.0'
  assert_output_matches '14\.1\.0'
  assert_output_matches 'git'
  assert_run_idle "$RUNNO"
}

t_r1_two_arguments_rejected_untouched() {
  populate_state 14.1.0
  expect_rejected_untouched -- 13.2.0 14.1.0
}

t_r1_empty_argument_rejected_untouched() { check_arg_rejected ""; }
t_r1_unsupported_version_rejected_untouched() { check_arg_rejected "99.9.9"; }
t_r1_two_component_version_rejected_untouched() { check_arg_rejected "13.2"; }
t_r1_garbage_rejected_untouched() { check_arg_rejected "gcc-13.2.0"; }
t_r1_git_fragment_rejected_untouched() { check_arg_rejected "gi"; }
t_r1_git_with_space_rejected_untouched() { check_arg_rejected " git"; }

# The original does a substring test against the list "A, B, git", so any
# argument that merely contains a listed version plus separator slips through.
t_r1_version_with_comma_not_a_version() { check_arg_rejected "13.2.0,"; }
t_r1_version_with_comma_space_not_a_version() { check_arg_rejected "14.1.0, "; }

# 13.2.1 is a prefix of the available 13.2.10; must not match by substring.
t_r1_version_prefix_of_another_rejected_untouched() {
  new_sandbox; default_sources
  add_gcc_archive 13.2.10
  build_ok 14.1.0
  plant_sentinels
  expect_rejected_untouched -- 13.2.1
}

# Exact selection, tested in a fresh PREF per version (no earlier build whose
# artifacts could make the second selection an incompatible *switch*).
check_exact_selection() { # wanted other
  new_sandbox; default_sources
  add_gcc_archive 13.2.10
  build_ok "$1"
  assert_link "$PREF/src/cpl/gcc" "gcc-$1"
  assert_eq "$(cat "$PREF/src/cpl/gcc/IDENTITY")" "gcc-$1"
  assert_no_file "$PREF/src/cpl/gcc-$2" "other version must not be extracted"
  assert_sources_ready "$1"
  assert_packaged
}
t_r1_exact_version_selects_exact_archive() { check_exact_selection 13.2.0 13.2.10; }
t_r1_exact_version_selects_longer_exact_archive() { check_exact_selection 13.2.10 13.2.0; }

# Switching to a *different exact* version in a PREF that already holds build
# artifacts is an incompatible reuse: it must be rejected (build artifacts
# untouched, explained) or every gcc tree must be configured again.
t_r1_switching_exact_version_in_used_pref_is_not_silently_reused() {
  new_sandbox; default_sources
  add_gcc_archive 13.2.10
  build_ok 13.2.0
  plant_sentinels
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- 13.2.10
  assert_safe_input_change "$SB/build.before" 'gcc-13\.2\.10' \
    "cross/$T32/gcc native/$T32/gcc cross/$T64/gcc native/$T64/gcc"
  if [[ "$RC" -ne 0 ]]
  then
    assert_sentinels_intact "artifact of the rejected version switch"
    assert_link "$PREF/src/cpl/gcc" gcc-13.2.0
  fi
}

t_r1_valid_release_builds_both_targets() {
  new_sandbox; default_sources
  run_crs -- 13.2.0
  assert_rc0
  assert_packaged
}

# A fresh build with "git" fetches the sources from upstream (details of the
# git policy are in test_git.sh).
t_r1_valid_git_version_accepted() {
  new_sandbox; default_sources
  add_git_upstream aaaa1111
  build_ok git
  assert_link "$PREF/src/cpl/gcc" gcc-git
  assert_eq "$(git_head)" aaaa1111 "checkout is the upstream commit"
  assert_sources_ready git
  assert_packaged
}

# Requesting git without an existing checkout is a "missing" source; it has to
# be reported before the existing prepared sources are destroyed.
t_r1_git_without_checkout_rejected_untouched() {
  populate_state 14.1.0
  add_git_upstream aaaa1111   # a (wrong) fetch would succeed and be detected
  expect_rejected_untouched -- git
}

# Advisory: the rejection should say what is missing.
a_r1_git_without_checkout_error_is_useful() {
  populate_state 14.1.0
  run_crs -- git
  assert_rc_nonzero
  assert_output_matches 'git|checkout|gcc-git' "error message mentions the missing git checkout"
}

# Two archives for one version (.tar.gz and .tar.xz): ambiguous.
t_r1_ambiguous_archives_rejected_untouched() {
  populate_state 14.1.0
  cp "$PREF/src/cpl/gcc-13.2.0.tar.gz" "$PREF/src/cpl/gcc-13.2.0.tar.xz"
  expect_rejected_untouched -- 13.2.0
}

t_r1_pref_with_spaces_and_dashes() {
  new_sandbox "pref dir-1/gcc-x"
  default_sources
  run_crs -- 13.2.0
  assert_rc0
  assert_sources_ready 13.2.0
  assert_packaged
}

# ---- NCRS ------------------------------------------------------------------
check_ncrs_rejected() { # value
  populate_state 14.1.0
  expect_rejected_untouched "NCRS=$1" -- 13.2.0
}
t_r1_ncrs_zero_rejected() { check_ncrs_rejected 0; }
t_r1_ncrs_negative_rejected() { check_ncrs_rejected -3; }
t_r1_ncrs_word_rejected() { check_ncrs_rejected abc; }
t_r1_ncrs_fraction_rejected() { check_ncrs_rejected 1.5; }
t_r1_ncrs_trailing_garbage_rejected() { check_ncrs_rejected 4x; }
t_r1_ncrs_hex_rejected() { check_ncrs_rejected 0x10; }

t_r1_ncrs_valid_value_used_for_jobs() {
  new_sandbox; default_sources
  run_crs NCRS=3 -- 13.2.0
  assert_rc0
  lines make 1 | awk -F'\t' '$4!=""{print $4}' | sort -u > "$SB/jobs"
  assert_eq "$(cat "$SB/jobs")" 3 "parallel jobs passed to make"
}

a_r1_unsupported_version_error_names_the_argument() {
  populate_state 14.1.0
  run_crs -- 99.9.9
  assert_rc_nonzero
  assert_output_matches '99\.9\.9' "error message names the rejected version"
  assert_output_matches '13\.2\.0' "error message lists available versions"
}

a_r1_ncrs_error_names_the_variable() {
  populate_state 14.1.0
  run_crs NCRS=abc -- 13.2.0
  assert_rc_nonzero
  assert_output_matches 'NCRS' "error message names NCRS"
}

# Explicit boundaries use canonical decimal job counts without octal arithmetic.
t_r1_ncrs_decimal_boundaries() {
  new_sandbox; default_sources
  local pair
  for pair in 007:7 08:8 010:10 4096:4096 0004096:4096; do
    run_crs "NCRS=${pair%:*}" -- 13.2.0
    assert_rc0
    # Completed repeats are hits; first invocation must pass canonical jobs.
    if [[ "$RUNNO" -eq 1 ]]; then
      assert_eq "$(lines make 1 | awk -F '\t' '$4!=""{print $4}' | sort -u)" 7 'canonical -j'
    fi
  done
}

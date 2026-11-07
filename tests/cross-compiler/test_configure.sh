# shellcheck shell=bash
# R3: failed / interrupted configuration is retried; diagnostics survive.

# One test per configured directory and per failure style.
#   mode "configure"     -> configure fails (exit 1) after creating config.log
#   mode "configure-int" -> configure is interrupted (exit 130) likewise
check_configure_failure_retried() { # rel mode
  local rel="$1" mode="$2" d
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=$mode:$rel" -- 13.2.0
  assert_rc_nonzero "first run (configure of $rel fails)"
  # diagnostics: the failed attempt's log is still there for the user
  grep -rlE "(FAILED|INTERRUPTED)-CONFIG-DIAG $rel" "$PREF/build/$rel" > /dev/null 2>&1 \
    || fail "diagnostic log of failed configure was not preserved in build/$rel"
  plant_sentinels
  run_crs -- 13.2.0
  assert_rc0 "second run must retry configuration of $rel"
  assert_eq "$(configured_in_run "$rel" 2)" 1 "configure retried exactly once for $rel"
  # successfully configured directories are preserved, not reconfigured
  while IFS= read -r d
  do
    assert_eq "$(configured_in_run "$d" 2)" 0 "build/$d was configured fine earlier"
  done < "$SB/sentinels.list"
  # (nothing was configured before the very first directory failed)
  [[ ! -s "$SB/sentinels.list" ]] || assert_sentinels_intact "artifact of already configured directory"
  assert_packaged
}

# Generate tests: both targets for plain failure, i686 also for interruption.
_gen_configure_tests() {
  local t kind comp rel
  for t in "$T32" "$T64"
  do
    while IFS= read -r rel
    do
      kind="${rel%%/*}"; comp="${rel##*/}"
      eval "t_r3_failed_configure_retried__${kind}_${t%%-*}_${comp//-/_}() { check_configure_failure_retried '$rel' configure; }"
      if [[ "$t" == "$T32" ]]
      then
        eval "t_r3_interrupted_configure_retried__${kind}_${t%%-*}_${comp//-/_}() { check_configure_failure_retried '$rel' configure-int; }"
      fi
    done < <(rels_for "$t")
  done
}
_gen_configure_tests

# config.log without a finished configuration (no Makefile) is not "configured".
# The tree is hand-made (provenance unknown), so rejecting it with an
# explanation is also acceptable; silently skipping configure is not.
t_r3_config_log_alone_is_not_success() {
  new_sandbox; default_sources
  craft_sources 13.2.0 yes
  craft_build_tree
  rm -f "$PREF/build/cross/$T32/gcc/Makefile"
  echo "interrupted early" > "$PREF/build/cross/$T32/gcc/config.log"
  snapshot_dir "$PREF/build" "$SB/build.before"
  run_crs -- 13.2.0
  if [[ "$RC" -eq 0 ]]
  then
    assert_eq "$(configured_in_run "cross/$T32/gcc" 1)" 1 "half-configured directory reconfigured"
  else
    assert_output_matches 'compat|chang|differ|mismatch|stale|reus|inconsist|unknown|incomplete|provenance'
    snapshot_dir "$PREF/build" "$SB/build.after"
    assert_same_snapshot "$SB/build.before" "$SB/build.after" "rejection must not delete artifacts"
  fi
}

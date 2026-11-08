# shellcheck shell=bash
# Verified per-target completion cache for make_cross-compiler.sh.
#
# Design under test (see COMPLETION-CACHE-TESTS.md): after a target was built,
# installed, its DLL relocated and its ZIP published, a completion record
# (one per target) is published.  A later run skips the target only if the
# record and a deterministic metadata snapshot (types, paths, device/inode,
# size, permissions, numeric ownership, high resolution mtime/ctime, symlink
# targets) of the target's build trees, installation trees and ZIP still match.
# Otherwise the existing recovery procedure runs.  NCRS never matters.
#
# Every test below first requires a genuine cache hit (cc_expect_hit) or a
# record (assert_records_per_target), so none of them passes on an
# implementation that always replays (the original) or never skips.

other_target() { if [[ "$1" == "$T32" ]]; then echo "$T64"; else echo "$T32"; fi; }

REFUSAL_RE='compat|chang|differ|mismatch|stale|reus|inconsist|incomplete|input|prepared|sources|verify'

assert_not_cache_hit() { # run [no-explanation] -- the build was repeated, or refused (with an explanation)
  local ran
  ran=$(( $(count make "$1") + $(count configure "$1") + $(count zip "$1") ))
  if [[ "$ran" -eq 0 ]]
  then
    [[ "$RC" -ne 0 ]] || fail "run $1 was taken for a completed build although the build changed"
    [[ "${2:-}" == no-explanation ]] || assert_output_matches "$REFUSAL_RE" "a refusal must explain itself"
  fi
}

# The records are exactly as the completed build left them.
assert_records_unchanged() {
  local f
  while IFS=$'\t' read -r f sum
  do
    [[ -f "$SB/$f" ]] || fail "completion record $f was removed"
    assert_eq "$(cksum < "$SB/$f")" "$sum" "completion record $f was modified"
  done < "$SB/records.sum"
}

# Every regular file of the build and install trees present before is still there.
list_artifacts() { find "$PREF/build" "$PREF/install" -type f | LC_ALL=C sort; }
assert_no_artifact_lost() { # before-list
  local gone
  sed "s#^#$SB/#" "$SB/records.list" > "$SB/records.abs"
  gone="$(list_artifacts | comm -23 "$1" - | grep -Fvx -f "$SB/records.abs" | head -n 3 | tr '\n' ' ')"
  [[ -z "$gone" ]] || fail "existing artifacts were removed: $gone"
}

# ======================================================================
# Harness self-checks (hold for any implementation)
# ======================================================================

# Each mutation changes exactly what it claims to change.
t_000_cc_mutations_do_what_they_claim() {
  local f ino ctime_ref
  new_sandbox
  f="$SB/subject"; ctime_ref="$SB/cref"
  echo "0123456789" > "$f"
  # samesize: content differs, size and mtime equal, ctime newer
  cp "$f" "$SB/orig"; touch -r "$f" "$SB/mref"; sleep 0.05; touch "$ctime_ref"; sleep 0.05
  mutate samesize "$f"
  ! cmp -s "$f" "$SB/orig" || fail "samesize did not change the content"
  assert_eq "$(wc -c < "$f" | tr -d ' ')" 11 "samesize changed the size"
  [[ ! "$f" -nt "$SB/mref" && ! "$SB/mref" -nt "$f" ]] || fail "samesize changed the mtime"
  [[ -n "$(find "$f" -cnewer "$ctime_ref")" ]] || fail "samesize did not change the ctime"
  # inode: other inode, same content/size/mtime
  ino="$(ls -i "$f" | awk '{print $1}')"; cp "$f" "$SB/orig"; touch -r "$f" "$SB/mref"
  mutate inode "$f"
  assert_eq "$(cmp "$f" "$SB/orig" && echo same)" same "inode swap changed the content"
  [[ "$(ls -i "$f" | awk '{print $1}')" != "$ino" ]] || fail "inode swap kept the inode"
  [[ ! "$f" -nt "$SB/mref" && ! "$SB/mref" -nt "$f" ]] || fail "inode swap changed the mtime"
  # hardlink and chmod_restore: only the ctime moves
  for k in hardlink chmod_restore
  do
    rm -f "$SB/outside-hardlink"
    cp "$f" "$SB/orig"; touch -r "$f" "$SB/mref"; sleep 0.05; touch "$ctime_ref"; sleep 0.05
    ino="$(ls -i "$f" | awk '{print $1}')"
    mutate "$k" "$f"
    assert_eq "$(cmp "$f" "$SB/orig" && echo same)" same "$k changed the content"
    [[ ! "$f" -nt "$SB/mref" && ! "$SB/mref" -nt "$f" ]] || fail "$k changed the mtime"
    assert_eq "$(ls -i "$f" | awk '{print $1}')" "$ino" "$k changed the inode"
    [[ -n "$(find "$f" -cnewer "$ctime_ref")" ]] || fail "$k did not change the ctime"
  done
}

# The failure injections used by the cache tests work on the original script.
t_000_cc_mv_failure_injection_stops_the_zip_move() {
  new_sandbox; default_sources
  run_crs "MOCK_MV_FAIL_MATCH=$T32.zip" -- 13.2.0
  assert_rc_nonzero "interrupted ZIP publication"
  assert_eq "$(count mvfail 1)" 1 "the injected mv failure was logged"
  assert_no_file "$PREF/install/native/$T32.zip" "package published although its move failed"
}
t_000_cc_scan_shims_are_transparent() {
  new_sandbox; enable_scan_shims; default_sources
  build_ok 13.2.0
  assert_packaged
  [[ ! -e "$SB/scan.hit" ]] || fail "a shim failed without being asked to"
  run_crs MOCK_SCAN_FAIL=find -- 13.2.0
  # With or without a cache a repeat must succeed: whatever the script does with
  # the failing find, it falls back to the existing recovery procedure.
  assert_rc0 "repeat with the find shim armed"
}
t_000_cc_spy_records_files_at_first_modification() {
  new_sandbox; default_sources
  build_ok 13.2.0 MOCK_SPY=1                     # a first build always modifies the targets
  assert_file "$SB/spy.$T32" "spy file of the first target"
  assert_file "$SB/spy.$T64" "spy file of the second target"
  grep -q "^./build/.cross-inputs" "$SB/spy.$T32" || fail "spy file does not list the files existing at that time"
}

# ======================================================================
# Cache hits
# ======================================================================

t_cc_completed_build_leaves_one_record_per_target() {
  cc_complete
  assert_records_per_target
}

t_cc_unchanged_repeat_does_no_work() {
  cc_complete
  plant_sentinels
  cp "$PREF/install/native/$T32.zip" "$SB/zip32.before"
  cp "$PREF/install/native/$T64.zip" "$SB/zip64.before"
  # plant_sentinels changed the trees: establish the record again first
  build_ok "$CCV"
  discover_records
  assert_records_per_target
  cc_expect_hit
  assert_sentinels_intact "compatible build artifact"
  assert_same_snapshot "$SB/zip32.before" "$PREF/install/native/$T32.zip" "package of $T32 rewritten"
  assert_same_snapshot "$SB/zip64.before" "$PREF/install/native/$T64.zip" "package of $T64 rewritten"
}

t_cc_two_unchanged_repeats_do_no_work() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  cc_expect_hit
  assert_records_unchanged
}

# Only the number of parallel jobs differs: not a change.
t_cc_changing_only_ncrs_keeps_the_cache() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  cc_expect_hit NCRS=7
  cc_expect_hit NCRS=1
  cc_expect_hit NCRS=64
  assert_records_unchanged
}

# Validation of NCRS is not bypassed by a cache hit.
t_cc_invalid_ncrs_is_rejected_with_a_complete_cache() {
  local v
  cc_complete
  assert_records_per_target
  cc_expect_hit
  for v in abc 0 -1 1.5 ''
  do
    run_crs "NCRS=$v" -- "$CCV"
    assert_rc_nonzero "NCRS='$v'"
    assert_run_idle "$RUNNO"
  done
  cc_expect_hit
}

# Source preparation is neither repeated nor needed on a hit.
t_cc_hit_does_not_prepare_sources_again() {
  cc_complete
  assert_records_per_target
  snapshot_dir "$PREF/src" "$SB/src.before"
  cc_expect_hit
  assert_eq "$(count prereq "$RUNNO")" 0
  snapshot_dir "$PREF/src" "$SB/src.after"
  assert_same_snapshot "$SB/src.before" "$SB/src.after" "source tree changed on a cache hit"
}

# ======================================================================
# Two targets
# ======================================================================

t_cc_first_target_complete_second_interrupted_resumes_second_only() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=make:cross/$T64/gcc:all-gcc" -- "$CCV"
  assert_rc_nonzero "first run"
  cp "$PREF/install/native/$T32.zip" "$SB/zip32.before"
  run_crs -- "$CCV"
  assert_rc0 "second run"
  assert_target_idle "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  assert_same_snapshot "$SB/zip32.before" "$PREF/install/native/$T32.zip" "package of the finished target rewritten"
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# The record of the interrupted second target does not exist (or is unusable)
# while the first target's record stays valid across the interruption.
t_cc_interrupted_second_target_does_not_disturb_first_record() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=make:native/$T64/mingw-w64:install" -- "$CCV"
  assert_rc_nonzero "first run"
  run_ref -- "$CCV"
  assert_rc0 "second run"
  assert_target_idle "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# Interruption in the FIRST target: nothing of the second one exists yet.
t_cc_first_target_interrupted_then_both_complete() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=make:native/$T32/gcc:install" -- "$CCV"
  assert_rc_nonzero "first run"
  run_crs -- "$CCV"
  assert_rc0 "second run"
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# ======================================================================
# Interrupted builds: compilation, installation, DLL relocation, packaging
# ======================================================================

# make fails in a stage (compilation or installation); the target is never
# recorded as complete; the same command completes it; then everything idles.
check_interruption_is_not_completion() { # rel key
  local t="${1#*/}"; t="${t%%/*}"
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=make:$1:$2" -- "$CCV"
  assert_rc_nonzero "first run (make $2 fails in $1)"
  run_crs -- "$CCV"
  assert_rc0 "same command after the interruption"
  assert_target_replayed "$RUNNO" "$t"
  if [[ "$t" == "$T32" ]]
  then
    assert_target_replayed "$RUNNO" "$T64"        # never started before
  else
    assert_target_idle "$RUNNO" "$T32"            # finished and recorded before
  fi
  assert_packaged
  discover_records
  assert_records_per_target
  cc_expect_hit
}
_gen_interruption_tests() {
  local t rel key kind comp
  for t in "$T32" "$T64"
  do
    while read -r rel key
    do
      kind="${rel%%/*}"; comp="${rel##*/}"
      eval "t_cc_interrupted__${t%%-*}_${kind}_${comp//-/_}__${key//-/_}() { check_interruption_is_not_completion '$rel' '$key'; }"
    done < <(cc_stage_sequence "$t")
  done
}
_gen_interruption_tests

# Relocation of the DLL (stage 8) is interrupted.
check_dll_relocation_interrupted() { # target
  local t="$1"
  new_sandbox; default_sources
  run_crs "MOCK_MV_FAIL_MATCH=$t/lib/libgcc" -- "$CCV"
  assert_rc_nonzero "run with interrupted DLL relocation"
  [[ "$(count mvfail 1)" -ge 1 ]] || fail "test bug: DLL relocation was not interrupted"
  assert_no_file "$PREF/install/native/$t.zip" "package of a target whose DLL was never relocated"
  run_crs -- "$CCV"
  assert_rc0 "same command afterwards"
  assert_target_replayed "$RUNNO" "$t"
  assert_packaged
  discover_records
  assert_records_per_target
  cc_expect_hit
}
t_cc_interrupted_dll_relocation_first_target() { check_dll_relocation_interrupted "$T32"; }
t_cc_interrupted_dll_relocation_second_target() { check_dll_relocation_interrupted "$T64"; }

# Packaging itself fails.
check_zip_failure_is_not_completion() { # target
  local t="$1"
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=zip:$t" -- "$CCV"
  assert_rc_nonzero "run with failing packaging"
  run_crs -- "$CCV"
  assert_rc0 "same command afterwards"
  assert_target_replayed "$RUNNO" "$t"
  assert_packaged
  discover_records
  assert_records_per_target
  cc_expect_hit
}
t_cc_interrupted_zip_first_target() { check_zip_failure_is_not_completion "$T32"; }
t_cc_interrupted_zip_second_target() { check_zip_failure_is_not_completion "$T64"; }

# The ZIP is published (moved to its final name) -- or that move is interrupted.
check_zip_publication_interrupted() { # target
  local t="$1"
  new_sandbox; default_sources
  run_crs "MOCK_MV_FAIL_MATCH=$t.zip" -- "$CCV"
  assert_rc_nonzero "run with interrupted ZIP publication"
  [[ "$(count mvfail 1)" -ge 1 ]] || fail "test bug: ZIP publication was not interrupted"
  run_crs -- "$CCV"
  assert_rc0 "same command afterwards"
  assert_target_replayed "$RUNNO" "$t"
  assert_packaged
  discover_records
  assert_records_per_target
  cc_expect_hit
}
t_cc_interrupted_zip_publication_first_target() { check_zip_publication_interrupted "$T32"; }
t_cc_interrupted_zip_publication_second_target() { check_zip_publication_interrupted "$T64"; }

# The record itself is published by an atomic rename: if that rename fails
# nothing half-written may be trusted by any later run.
t_cc_interrupted_record_publication_never_yields_a_hit() {
  local i
  new_sandbox; default_sources
  run_crs MOCK_MV_FAIL_UNKNOWN=1 -- "$CCV"
  [[ "$(count mvfail 1)" -ge 1 ]] \
    || fail "a completion record was not published through a rename (mv): atomic publication cannot be verified"
  for i in 1 2
  do
    run_crs MOCK_MV_FAIL_UNKNOWN=1 -- "$CCV"
    assert_target_replayed "$RUNNO" "$T32"
    [[ "$(count make "$RUNNO")" -gt 0 ]] || fail "run $RUNNO took an unpublished record for a completed build"
  done
  run_crs -- "$CCV"
  assert_rc0 "run without interruption"
  assert_packaged
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# A partial or failed zip never leaves a record that makes the damaged state a hit.
t_cc_failed_packaging_of_a_changed_target_is_not_completion() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  echo new > "$PREF/install/native/$T32/bin/added-after-first-build.txt"
  run_crs "MOCK_FAIL=zip:$T32" MOCK_SPY=1 -- "$CCV"
  assert_rc_nonzero "run whose packaging fails"
  assert_records_invalidated_before_modification "$T32"
  run_crs -- "$CCV"
  assert_rc0 "same command afterwards"
  assert_target_replayed "$RUNNO" "$T32"
  grep -q added-after-first-build "$PREF/install/native/$T32.zip" || fail "package lacks the new file"
  cc_expect_hit
}

# ======================================================================
# Pipeline completion versus make's idea of freshness
# ======================================================================

# Everything make is asked to do is already up to date, yet there is no
# evidence the pipeline finished (no record): all stages and the packaging
# still run, and make's "up to date" never turns into a completion record
# before packaging happened.
t_cc_fresh_make_without_record_is_not_completion() {
  local bad
  cc_complete
  assert_records_per_target
  each_record "$T32" rm -f --
  each_record "$T64" rm -f --
  run_crs -- "$CCV"
  assert_rc0 "repeat without records"
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  bad="$(lines make "$RUNNO" | awk -F'\t' '$3 !~ /^install/ && $5 == "built"' | head -n 1)"
  [[ -z "$bad" ]] || fail "test bug: make was expected to find everything up to date: $bad"
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# Packaging failed after every make stage succeeded: the retry finds all
# compilation up to date but must still package, and only then record.
t_cc_packaging_failure_after_fresh_make_is_not_completion() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=zip:$T32" -- "$CCV"
  assert_rc_nonzero "first run"
  run_crs -- "$CCV"
  assert_rc0 "retry"
  assert_eq "$(lines make "$RUNNO" | awk -F'\t' -v t="$T32" 'index($2, t) && $3 !~ /^install/ && $5 == "built"' | wc -l | tr -d ' ')" 0 \
    "make had nothing left to compile for $T32"
  assert_target_replayed "$RUNNO" "$T32"
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# A run that rebuilt something is as good a completion as one that rebuilt
# nothing: both publish a record, neither depends on make's verdict.
t_cc_run_that_compiled_things_records_completion() {
  cc_complete
  assert_records_per_target
  rm -f "$PREF/build/cross/$T64/gcc/.mock-built-all"
  run_crs -- "$CCV"
  assert_rc0
  assert_eq "$(lines make "$RUNNO" | awk -F'\t' -v t="$T64" 'index($2, t) && $5 == "built"' | wc -l | tr -d ' ')" 1 \
    "test bug: one compilation expected"
  cc_expect_hit
}

# ======================================================================
# Modified, missing and added artifacts (the matrix)
# ======================================================================

check_mutation_invalidates() { # tree kind target
  local tree="$1" kind="$2" t="$3" f root=''
  cc_complete
  assert_records_per_target
  cc_expect_hit                                  # precondition: a real hit
  discover_records
  f="$(cc_file_for "$tree" "$t")"
  [[ "$tree" == zip ]] || root="$(cc_root_for "$tree" "$t")"
  list_artifacts > "$SB/artifacts.before"
  mutate "$kind" "$f" "$root"
  run_ref MOCK_SPY=1 -- "$CCV"
  assert_rc0 "repeat after '$kind' in $tree of $t"
  assert_target_replayed "$RUNNO" "$t"
  assert_target_idle "$RUNNO" "$(other_target "$t")"
  assert_records_invalidated_before_modification "$t"
  assert_no_artifact_lost "$SB/artifacts.before"
  [[ "$kind" != delete ]] || assert_file "$f" "deleted artifact was not recovered"
  assert_packaged
  cc_expect_hit                                  # and the target is recorded again
}

_gen_mutation_tests() {
  local t tree kind short
  for t in "$T32" "$T64"
  do
    short="${t%%-*}"
    for tree in bcross bnative icross inative zip
    do
      for kind in delete add grow samesize inode chmod chmod_restore mtime hardlink dirchmod add_dir
      do
        # Only the second target gets the full matrix; the first a representative part.
        if [[ "$t" == "$T32" ]]
        then
          case "$tree:$kind" in
            bcross:delete|bcross:samesize|bcross:chmod_restore|bcross:add_dir|inative:delete|inative:samesize|inative:hardlink|inative:dirchmod|zip:delete|zip:samesize|zip:grow|zip:hardlink) ;;
            *) continue ;;
          esac
        fi
        # A ZIP is a file: nothing to add to it, no tree root to chmod.
        case "$tree:$kind" in zip:add|zip:add_dir|zip:dirchmod) continue ;; esac
        eval "t_cc_mutation__${short}__${tree}__${kind}() { check_mutation_invalidates '$tree' '$kind' '$t'; }"
      done
    done
  done
}
_gen_mutation_tests

# Timestamps are compared at full resolution: modifications made in the same
# second as the record (mtime restored, only ctime differs) are still detected.
# Repeated immediately, so that an implementation with one second timestamps
# cannot escape by luck.
t_cc_modifications_within_the_same_second_are_detected() {
  local i f
  cc_complete
  assert_records_per_target
  cc_expect_hit
  f="$(cc_file_for bcross "$T64")"
  for i in 1 2 3 4 5 6
  do
    mutate samesize "$f"
    run_crs -- "$CCV"
    assert_rc0 "repeat $i after an immediate same-size edit"
    assert_target_replayed "$RUNNO" "$T64"
    assert_target_idle "$RUNNO" "$T32"
  done
  cc_expect_hit
}

# Both targets modified: both recovered.
t_cc_both_targets_modified_both_recovered() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  echo x > "$PREF/build/native/$T32/gcc/added-by-test.txt"
  rm -f "$PREF/install/cross/$T64/bin/.mock-installed-binutils-install"
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  assert_file "$PREF/install/cross/$T64/bin/.mock-installed-binutils-install"
  cc_expect_hit
}

# Changes of one target never invalidate the other.
t_cc_change_in_one_target_does_not_invalidate_the_other() {
  local t
  cc_complete
  assert_records_per_target
  cc_expect_hit
  for t in "$T32" "$T64"
  do
    echo x > "$PREF/install/native/$t/bin/added-by-test-$t.txt"
    run_crs -- "$CCV"
    assert_rc0
    assert_target_replayed "$RUNNO" "$t"
    assert_target_idle "$RUNNO" "$(other_target "$t")"
    cc_expect_hit
  done
}

# Files outside every target tree (next to the ZIPs) are not part of any snapshot.
t_cc_unrelated_file_next_to_the_packages_does_not_invalidate() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  echo x > "$PREF/install/native/unrelated-notes.txt"
  cc_expect_hit
}

# Required roots: a missing build or install root is a mismatch, and nothing
# valuable below the other roots is removed.
check_missing_root() { # tree target
  local root
  cc_complete
  assert_records_per_target
  cc_expect_hit
  root="$(cc_root_for "$1" "$2")"
  sb_rm "$root"
  run_crs -- "$CCV"
  assert_rc0 "repeat after the root disappeared"
  assert_target_replayed "$RUNNO" "$2"
  assert_target_idle "$RUNNO" "$(other_target "$2")"
  assert_dir_exists_after "$root"
  cc_expect_hit
}
assert_dir_exists_after() { [[ -d "$1" ]] || fail "recovery did not recreate $1"; }
t_cc_missing_build_cross_root_is_recovered() { check_missing_root bcross "$T64"; }
t_cc_missing_build_native_root_is_recovered() { check_missing_root bnative "$T64"; }
t_cc_missing_install_cross_root_is_recovered() { check_missing_root icross "$T32"; }
t_cc_missing_install_native_root_is_recovered() { check_missing_root inative "$T32"; }

# Roots replaced by something of another type (file / symlink instead of directory).
t_cc_root_replaced_by_a_file_is_not_a_hit_and_nothing_is_deleted() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  mv "$PREF/install/cross/$T32" "$SB/saved-root"
  echo not-a-directory > "$PREF/install/cross/$T32"
  run_crs -- "$CCV"
  assert_not_cache_hit "$RUNNO" no-explanation          # mkdir -p may refuse; any outcome but a hit is fine
  assert_file "$SB/saved-root/bin/.mock-installed-binutils-install" "the displaced installation was lost"
  assert_eq "$(cat "$PREF/install/cross/$T32")" not-a-directory "the replacement file was destroyed"
}
t_cc_root_replaced_by_a_symlink_is_not_a_hit() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  mv "$PREF/build/native/$T64" "$SB/saved-root"
  ln -s "$SB/saved-root" "$PREF/build/native/$T64"
  run_crs -- "$CCV"
  assert_not_cache_hit "$RUNNO"
  assert_file "$SB/saved-root/gcc/Makefile" "the displaced build tree was lost"
}

# ---- symbolic links ------------------------------------------------------------

check_symlink_change() { # tree target
  local tree="$1" t="$2" root link ref
  cc_complete
  ref="$SB/link.ref"
  assert_records_per_target
  root="$(cc_root_for "$tree" "$t")"
  link="$root/link-by-test"
  ln -s alpha "$link"                              # an added link
  run_crs -- "$CCV"
  assert_rc0 "repeat after a symbolic link was added"
  assert_target_replayed "$RUNNO" "$t"
  discover_records
  assert_records_per_target
  cc_expect_hit                                    # a tree with a (dangling) link is cacheable
  : > "$ref"
  touch -h -r "$link" "$ref"
  ln -sfn bravo "$link"                            # same length target ...
  touch -h -r "$ref" "$link"                       # ... and the link's own mtime restored
  run_ref -- "$CCV"
  assert_rc0 "repeat after the link target changed"
  assert_target_replayed "$RUNNO" "$t"
  assert_target_idle "$RUNNO" "$(other_target "$t")"
  assert_eq "$(readlink "$link")" bravo "the link must not be touched by recovery"
  cc_expect_hit
  rm -f "$link"                                    # a link replaced by a regular file
  printf 'bravo' > "$link"
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$t"
  cc_expect_hit
}
t_cc_symlink_retargeted_in_build_tree_invalidates() { check_symlink_change bnative "$T64"; }
t_cc_symlink_retargeted_in_install_tree_invalidates() { check_symlink_change icross "$T32"; }

# ======================================================================
# Completion records
# ======================================================================

rec_empty() { : > "$1"; }
rec_garbage() { echo 'this is not a completion record' > "$1"; }
rec_truncate() { local n=$(( $(wc -c < "$1") / 2 )); head -c "$n" "$1" > "$1.cut" && cat "$1.cut" > "$1" && rm -f "$1.cut"; }
rec_append() { echo 'unexpected trailing line' >> "$1"; }
rec_flip() { local n=$(( $(wc -c < "$1") / 2 )); printf 'Z' | dd of="$1" bs=1 count=1 seek="$n" conv=notrunc 2> /dev/null; }
rec_symlink_to_copy() {
  local c="$SB/record.copy.$RANDOM"
  cp "$1" "$c"; cksum < "$c" > "$c.sum"; rm -f "$1"; ln -s "$c" "$1"
}
rec_symlink_dangling() { rm -f "$1"; ln -s "$SB/does-not-exist" "$1"; }
rec_unreadable() { chmod 000 "$1"; }

check_record_damage() { # damage-function target
  local dmg="$1" t="$2" s
  cc_complete
  assert_records_per_target
  cc_expect_hit
  each_record "$t" "$dmg"
  run_ref -- "$CCV"
  assert_rc0 "repeat with a damaged record ($dmg)"
  assert_target_replayed "$RUNNO" "$t"
  assert_target_idle "$RUNNO" "$(other_target "$t")"
  # a record that was a symlink must be replaced, never written through
  for s in "$SB"/record.copy.*.sum
  do
    [[ -f "$s" ]] || continue
    assert_eq "$(cksum < "${s%.sum}")" "$(cat "$s")" "the target of a symlinked record was overwritten"
  done
  cc_expect_hit
}
_gen_record_tests() {
  local dmg t short
  for dmg in rec_empty rec_garbage rec_truncate rec_append rec_flip rec_symlink_to_copy rec_symlink_dangling
  do
    for t in "$T32" "$T64"
    do
      short="${t%%-*}"
      eval "t_cc_damaged_record__${dmg#rec_}__${short}() { check_record_damage '$dmg' '$t'; }"
    done
  done
}
_gen_record_tests

t_cc_unreadable_record__i686() { require_non_root; check_record_damage rec_unreadable "$T32"; }
t_cc_unreadable_record__x86_64() { require_non_root; check_record_damage rec_unreadable "$T64"; }

check_missing_record() { # target
  local t="$1"
  cc_complete
  assert_records_per_target
  cc_expect_hit
  each_record "$t" rm -f --
  run_ref -- "$CCV"
  assert_rc0 "repeat without the record of $t"
  assert_target_replayed "$RUNNO" "$t"
  assert_target_idle "$RUNNO" "$(other_target "$t")"
  cc_expect_hit
}
t_cc_missing_record_i686() { check_missing_record "$T32"; }
t_cc_missing_record_x86_64() { check_missing_record "$T64"; }

t_cc_all_records_missing_replays_everything_once() {
  cc_complete
  assert_records_per_target
  each_record "$T32" rm -f --
  each_record "$T64" rm -f --
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  discover_records
  assert_records_per_target
  cc_expect_hit
}

# A record of the wrong target must not be accepted for this target.
t_cc_record_of_the_other_target_is_rejected() {
  local a b
  cc_complete
  assert_records_per_target
  cc_expect_hit
  a="$SB/$(records_for "$T32" | head -n 1)"
  b="$SB/$(records_for "$T64" | head -n 1)"
  cp "$a" "$SB/rec32"; cp "$b" "$SB/rec64"
  cat "$SB/rec64" > "$a"
  cat "$SB/rec32" > "$b"
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  cc_expect_hit
}

# A record that was valid for an older state of the target is not valid now.
t_cc_stale_record_restored_over_a_newer_one_is_rejected() {
  local f
  cc_complete
  assert_records_per_target
  cc_expect_hit
  mkdir -p "$SB/oldrec"
  while IFS= read -r f; do cp "$SB/$f" "$SB/oldrec/$(echo "$f" | tr '/' '_')"; done < <(records_for "$T32")
  echo x > "$PREF/install/native/$T32/bin/added-by-test.txt"
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
  while IFS= read -r f; do cat "$SB/oldrec/$(echo "$f" | tr '/' '_')" > "$SB/$f"; done < <(records_for "$T32")
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_idle "$RUNNO" "$T64"
  cc_expect_hit
}

# Advisory: the record states its format version and its target, so that a
# future incompatible record (or one of the other target) is told apart even if
# it were otherwise well-formed.  Needs a decision on the record format.
a_cc_record_names_target_and_schema() {
  local f
  cc_complete
  assert_records_per_target
  while IFS= read -r f
  do
    grep -q "$T32" "$SB/$f" || fail "record $f does not name its target"
    grep -Eiq 'schema|version|format|v[0-9]' "$SB/$f" || fail "record $f carries no schema/version marker"
  done < <(records_for "$T32")
}
a_cc_record_with_unknown_schema_version_is_rejected() {
  local f
  cc_complete
  assert_records_per_target
  cc_expect_hit
  while IFS= read -r f
  do
    sed -E -e 's/((schema|version|format)[^0-9]{0,3})[0-9]+/\1999999/' \
      -e 's/((SCHEMA|VERSION|FORMAT|Schema|Version|Format)[^0-9]{0,3})[0-9]+/\1999999/' "$SB/$f" > "$SB/rec.tmp"
    cmp -s "$SB/rec.tmp" "$SB/$f" && fail "record has no recognizable schema/version number to change"
    cat "$SB/rec.tmp" > "$SB/$f"
  done < <(records_for "$T32")
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
}

# ---- an interrupted recovery leaves no valid record -----------------------------

t_cc_interrupted_recovery_of_a_changed_target_stays_incomplete() {
  cc_complete
  assert_records_per_target
  cc_expect_hit
  echo x > "$PREF/build/cross/$T32/binutils/added-by-test.txt"
  run_crs "MOCK_FAIL=make:cross/$T32/binutils:all" MOCK_SPY=1 -- "$CCV"
  assert_rc_nonzero "interrupted recovery"
  assert_records_invalidated_before_modification "$T32"
  run_crs -- "$CCV"
  assert_rc0
  assert_target_replayed "$RUNNO" "$T32"
  assert_target_idle "$RUNNO" "$T64"
  cc_expect_hit
}

# ======================================================================
# Failed or incomplete metadata scans
# ======================================================================

# A directory that cannot be read cannot be validated: never a hit, never a
# record on a partial listing.  (Needs a non-root user.)
t_cc_unreadable_directory_is_never_accepted_as_complete() {
  local dir
  require_non_root
  cc_complete
  assert_records_per_target
  cc_expect_hit
  dir="$PREF/build/native/$T32/gcc/private"
  mkdir "$dir"; echo secret > "$dir/data"; chmod 000 "$dir"
  run_crs -- "$CCV"
  assert_target_replayed "$RUNNO" "$T32"                       # changed: replayed, however the run ends
  run_crs -- "$CCV"
  assert_target_replayed "$RUNNO" "$T32"                       # still unreadable: still no hit
  chmod 755 "$dir"
  run_crs -- "$CCV"
  assert_rc0 "run once the directory is readable again"
  assert_target_replayed "$RUNNO" "$T32"                       # its mode changed
  cc_expect_hit
  assert_eq "$(cat "$dir/data")" secret "the unreadable directory's content was damaged"
}

SCAN_TOOLS="find stat sort xargs awk perl python3 sha256sum shasum sha512sum openssl ls readlink od uniq"

# The metadata scan is an external pipeline.  Whichever tool of it fails (after
# emitting partial output), the result must not be accepted: the target is
# recovered, and the record published afterwards is valid.
check_scan_tool_failure() { # tool
  local tool="$1"
  new_sandbox; enable_scan_shims; default_sources
  build_ok "$CCV"
  discover_records
  assert_records_per_target
  cc_expect_hit
  run_crs "MOCK_SCAN_FAIL=$tool" -- "$CCV"
  if [[ ! -e "$SB/scan.hit" ]]
  then
    echo "SKIP: $tool is not used by the metadata scan"
    exit 77
  fi
  assert_rc0 "run whose metadata scan fails in $tool (truncated output)"
  assert_target_replayed "$RUNNO" "$T32"
  cc_expect_hit
  # the same failure after all output was written: the exit status decides
  run_crs "MOCK_SCAN_FAIL=$tool" MOCK_SCAN_FAIL_MODE=full -- "$CCV"
  assert_rc0 "run whose metadata scan fails in $tool (complete output, failure status)"
  assert_target_replayed "$RUNNO" "$T32"
  cc_expect_hit
}
_gen_scan_failure_tests() {
  local tool
  for tool in $SCAN_TOOLS
  do
    eval "t_cc_scan_failure__${tool}() { check_scan_tool_failure '$tool'; }"
  done
}
_gen_scan_failure_tests

t_cc_metadata_scan_uses_an_external_tool_that_can_fail() {
  local tool found=''
  new_sandbox; enable_scan_shims; default_sources
  build_ok "$CCV"
  discover_records
  assert_records_per_target
  for tool in $SCAN_TOOLS
  do
    run_crs "MOCK_SCAN_FAIL=$tool" -- "$CCV"
    if [[ -e "$SB/scan.hit" ]]
    then
      found="$tool"
      break
    fi
  done
  [[ -n "$found" ]] || fail "none of the shimmed tools ($SCAN_TOOLS) took part in validating a completed target"
}

# ======================================================================
# Source, configuration and build logic
# ======================================================================

# The cache never overrides the compatibility checks that come first.
check_refused_despite_cache() { # description, run_crs args...
  local what="$1"; shift
  assert_rc_nonzero "$what"
  assert_run_idle "$RUNNO"
  assert_output_matches "$REFUSAL_RE" "refusal of '$what' must explain itself"
  assert_records_unchanged
}

t_cc_changed_cflags_are_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  run_crs CFLAGS=-O0 -- "$CCV"
  check_refused_despite_cache "changed CFLAGS"
}
t_cc_changed_environment_cc_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  run_crs CC=cc -- "$CCV"
  check_refused_despite_cache "CC now set"
}
t_cc_other_gcc_version_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  run_crs -- 14.1.0
  check_refused_despite_cache "other GCC version"
}
t_cc_newer_binutils_archive_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  add_binutils_archive 2.43
  run_crs -- "$CCV"
  check_refused_despite_cache "newer binutils archive"
}
t_cc_changed_gcc_archive_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  echo changed >> "$PREF/src/cpl/gcc-$CCV.tar.gz"
  run_crs -- "$CCV"
  check_refused_despite_cache "changed GCC archive"
}
t_cc_edited_source_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  echo '# local edit' >> "$PREF/src/cpl/gcc-$CCV/configure"
  run_crs -- "$CCV"
  check_refused_despite_cache "edited source file"
}
t_cc_replaced_host_tool_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  echo '# updated tool' >> "$SB/bin/make"
  run_crs -- "$CCV"
  check_refused_despite_cache "replaced host tool"
}
t_cc_changed_gcc_source_link_is_refused_despite_a_complete_cache() {
  cc_complete; assert_records_per_target; cc_expect_hit
  ln -sfn gcc-14.1.0 "$PREF/src/cpl/gcc"
  run_crs -- "$CCV"
  assert_not_cache_hit "$RUNNO"
  assert_eq "$(readlink "$PREF/src/cpl/gcc")" gcc-14.1.0 "the foreign link was replaced"
}

# Build logic: configure options are part of the build policy.
t_cc_changed_configure_options_are_never_a_silent_hit() {
  cc_complete; assert_records_per_target; cc_expect_hit
  make_script_variant 's/--without-zstd/--without-zstd --with-system-zlib/'
  run_crs -- "$CCV"
  assert_not_cache_hit "$RUNNO"
}
t_cc_changed_gcc_languages_are_never_a_silent_hit() {
  cc_complete; assert_records_per_target; cc_expect_hit
  make_script_variant 's/--enable-languages=c,c++,fortran/--enable-languages=c,c++/'
  run_crs -- "$CCV"
  assert_not_cache_hit "$RUNNO"
}
# Advisory (what "build-policy identity" covers is a decision): other build
# logic -- the runtime library per target and the packaging command.
a_cc_changed_runtime_dll_policy_is_not_a_hit() {
  cc_complete; assert_records_per_target; cc_expect_hit
  make_script_variant 's/libgcc_s_sjlj-1\.dll/libgcc_s_dw2-1.dll/'
  run_crs -- "$CCV"
  assert_not_cache_hit "$RUNNO"
  [[ "$(count make "$RUNNO")" -gt 0 ]] || fail "changed DLL policy was taken for a completed build"
}
a_cc_changed_packaging_command_is_not_a_hit() {
  cc_complete; assert_records_per_target; cc_expect_hit
  make_script_variant 's/zip --filesync --recurse-paths/zip --filesync --recurse-paths --quiet/'
  run_crs -- "$CCV"
  assert_rc0
  [[ "$(count zip "$RUNNO")" -gt 0 ]] || fail "changed packaging command was taken for a completed build"
}

# Recovery of a changed target after the script itself changed insignificantly
# is allowed but never required to be a hit (decision pending): only a sanity
# check that such a run succeeds.
t_cc_script_comment_change_never_breaks_the_build() {
  cc_complete; assert_records_per_target; cc_expect_hit
  make_script_variant '1a\
# harmless comment'
  run_crs -- "$CCV"
  assert_rc0
  assert_packaged
}

# ======================================================================
# Git sources
# ======================================================================

UPC1=aaaa1111
UPC2=bbbb2222

cc_age_sources() {
  find "$PREF/src" -exec touch -h -t 200001010000 {} +
  touch -t 200101010000 "$SB/ref-time"
}

t_cc_git_repeat_is_a_hit_and_leaves_sources_alone() {
  new_sandbox; default_sources
  add_git_upstream "$UPC1"
  build_ok git
  discover_records
  assert_records_per_target
  cc_age_sources
  set_upstream_commit "$UPC2"
  touch "$SB/ref"
  run_crs -- git
  assert_rc0
  assert_run_idle "$RUNNO"
  assert_packaged
  assert_eq "$(git_head)" "$UPC1" "pinned checkout"
  local newer
  newer="$(find "$PREF/src" -newer "$SB/ref-time" | head -n 3)"
  [[ -z "$newer" ]] || fail "source timestamps changed on a cache hit: $newer"
}

t_cc_git_two_unchanged_repeats_are_hits() {
  new_sandbox; default_sources
  add_git_upstream "$UPC1"
  build_ok git
  discover_records
  assert_records_per_target
  run_ref -- git; assert_rc0; assert_run_idle "$RUNNO"
  run_ref -- git; assert_rc0; assert_run_idle "$RUNNO"
  assert_artifacts_untouched
}

t_cc_git_second_target_interruption_resumes_second_only() {
  new_sandbox; default_sources
  add_git_upstream "$UPC1"
  run_crs "MOCK_FAIL=make:cross/$T64/gcc:all-gcc" -- git
  assert_rc_nonzero "first run"
  set_upstream_commit "$UPC2"
  run_crs -- git
  assert_rc0 "second run"
  assert_target_idle "$RUNNO" "$T32"
  assert_target_replayed "$RUNNO" "$T64"
  assert_eq "$(git_mutation_count "$RUNNO")" 0 "nothing fetched when continuing"
  assert_eq "$(git_head)" "$UPC1" "pinned checkout"
  discover_records
  assert_records_per_target
  run_crs -- git; assert_rc0; assert_run_idle "$RUNNO"
}

t_cc_git_changed_checkout_is_refused_despite_a_complete_cache() {
  new_sandbox; default_sources
  add_git_upstream "$UPC1"
  build_ok git
  discover_records
  assert_records_per_target
  echo changed-locally > "$PREF/src/cpl/gcc-git/.git/FAKE_HEAD"
  run_crs -- git
  check_refused_despite_cache "changed checkout"
}

t_cc_git_local_source_edit_is_refused_despite_a_complete_cache() {
  new_sandbox; default_sources
  add_git_upstream "$UPC1"
  build_ok git
  discover_records
  assert_records_per_target
  echo '# local work' >> "$PREF/src/cpl/gcc-git/configure"
  run_crs -- git
  check_refused_despite_cache "edited git source"
}

t_cc_git_modified_target_is_recovered_without_fetching() {
  new_sandbox; default_sources
  add_git_upstream "$UPC1"
  build_ok git
  discover_records
  assert_records_per_target
  set_upstream_commit "$UPC2"
  echo x > "$PREF/install/native/$T64/bin/added-by-test.txt"
  run_crs -- git
  assert_rc0
  assert_target_replayed "$RUNNO" "$T64"
  assert_target_idle "$RUNNO" "$T32"
  assert_eq "$(git_mutation_count "$RUNNO")" 0 "nothing fetched when recovering"
  run_crs -- git; assert_rc0; assert_run_idle "$RUNNO"
}

# ======================================================================
# Preservation of the existing guarantees in combination with the cache
# ======================================================================

# DLL relocation with a strict mv and no recreated DLL (second invocation sees
# the DLL already in bin/) still works when the cache is bypassed.
CC_STRICT=(MOCK_MV_TOLERANT=0 MOCK_DLL_MODE=keep)
t_cc_strict_mv_replay_after_invalidation() {
  new_sandbox; default_sources
  build_ok "$CCV" "${CC_STRICT[@]}"
  discover_records
  assert_records_per_target
  run_ref "${CC_STRICT[@]}" -- "$CCV"
  assert_rc0 "unchanged repeat with strict mv"
  assert_run_idle "$RUNNO"
  echo x > "$PREF/install/native/$T32/bin/added-by-test.txt"
  run_crs "${CC_STRICT[@]}" -- "$CCV"
  assert_rc0 "replay with the DLL already in bin/"
  assert_target_replayed "$RUNNO" "$T32"
  assert_packaged
}

# Invalidation never removes anything valuable.
t_cc_invalidation_preserves_all_build_artifacts() {
  cc_complete
  plant_sentinels
  build_ok "$CCV"
  discover_records
  assert_records_per_target
  list_artifacts > "$SB/artifacts.before"
  snapshot_dir "$PREF/src" "$SB/src.before"
  echo x > "$PREF/install/cross/$T32/bin/added-by-test.txt"
  echo x > "$PREF/build/native/$T64/binutils/added-by-test.txt"
  run_crs -- "$CCV"
  assert_rc0
  assert_sentinels_intact "build artifact"
  assert_no_artifact_lost "$SB/artifacts.before"
  assert_file "$PREF/install/cross/$T32/bin/added-by-test.txt"
  assert_file "$PREF/build/native/$T64/binutils/added-by-test.txt"
  snapshot_dir "$PREF/src" "$SB/src.after"
  assert_same_snapshot "$SB/src.before" "$SB/src.after" "sources changed by a recovery"
}

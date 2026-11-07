# shellcheck shell=bash
# R4: resumable builds; baseline behaviour preserved; recovery after the first
# target finished and the second failed.

# ---- baseline (existing successful behaviour must be preserved) --------------

expected_configure_lines() { # target -> rel<TAB>srcrel<TAB>args
  local t="$1"
  printf '%s\t%s\t%s\n' \
    "cross/$t/binutils" binutils "--prefix=@PREF@/install/cross/$t --target=$t --disable-multilib" \
    "cross/$t/mingw-w64-headers" mingw-w64/mingw-w64-headers "--prefix=@PREF@/install/cross/$t/$t --host=$t" \
    "cross/$t/gcc" gcc "--prefix=@PREF@/install/cross/$t --target=$t --disable-multilib --enable-languages=c,c++,fortran" \
    "cross/$t/mingw-w64" mingw-w64 "--prefix=@PREF@/install/cross/$t/$t --host=$t" \
    "cross/$t/winpthreads" mingw-w64/mingw-w64-libraries/winpthreads "--prefix=@PREF@/install/cross/$t/$t --host=$t --libdir=@PREF@/install/cross/$t/$t/lib" \
    "native/$t/binutils" binutils "--prefix=@PREF@/install/native/$t --host=$t --target=$t --disable-multilib --without-zstd" \
    "native/$t/gcc" gcc "--prefix=@PREF@/install/native/$t --host=$t --target=$t --disable-multilib --enable-languages=c,c++,fortran" \
    "native/$t/mingw-w64" mingw-w64 "--prefix=@PREF@/install/native/$t/$t --host=$t --with-libraries=winpthreads"
}

t_r4_baseline_configure_arguments_unchanged() {
  new_sandbox; default_sources
  build_ok 13.2.0
  { expected_configure_lines "$T32"; expected_configure_lines "$T64"; } | sort > "$SB/want"
  lines configure 1 | awk -F'\t' '{printf "%s\t%s\t%s\n", $2, $3, $5}' | sort > "$SB/got"
  if ! diff -u "$SB/want" "$SB/got" > "$SB/d"
  then
    cat "$SB/d" >&2
    fail "configure invocations differ from the original behaviour"
  fi
}

expected_make_sequence() { # target
  local t="$1"
  printf '%s\n' \
    "cross/$t/binutils all" "cross/$t/binutils install" \
    "cross/$t/mingw-w64-headers install" \
    "cross/$t/gcc all-gcc" "cross/$t/gcc install-gcc" \
    "cross/$t/mingw-w64 all" "cross/$t/mingw-w64 install" \
    "cross/$t/gcc all" "cross/$t/gcc install" \
    "cross/$t/winpthreads all" "cross/$t/winpthreads install" \
    "native/$t/binutils all" "native/$t/binutils install" \
    "native/$t/gcc all" "native/$t/gcc install" \
    "native/$t/mingw-w64 all" "native/$t/mingw-w64 install"
}

t_r4_baseline_stage_order_unchanged() {
  new_sandbox; default_sources
  build_ok 13.2.0
  { expected_make_sequence "$T32"; expected_make_sequence "$T64"; } > "$SB/want"
  lines make 1 | awk -F'\t' '{print $2 " " $3}' > "$SB/got"
  if ! diff -u "$SB/want" "$SB/got" > "$SB/d"
  then
    cat "$SB/d" >&2
    fail "build stage order differs from the original behaviour"
  fi
  # Packaging commands: same working directory, options and input directory as
  # the original.  The archive operand may be the final name (original) or a
  # staged path ending in "<target>[.zip]" (see t_r6_zip_writes_to_staging_path).
  local t n=0
  for t in "$T32" "$T64"
  do
    n=$((n + 1))
    line="$(lines zip 1 | sed -n "${n}p")"
    [[ -n "$line" ]] || fail "no packaging command for $t"
    cwd="$(printf '%s' "$line" | cut -f2)"; args="$(printf '%s' "$line" | cut -f3)"
    assert_eq "$cwd" install/native "packaging working directory"
    [[ "$args" =~ ^--filesync\ --recurse-paths\ ([^\ ]*/)?$t(\.zip)?\ $t$ ]] \
      || fail "packaging command differs from the original: $args"
  done
  assert_eq "$(count zip 1)" 2 "exactly one packaging command per target"
}

# ---- repeated invocation after success ------------------------------------

t_r4_rerun_after_success_preserves_everything() {
  new_sandbox; default_sources
  build_ok 13.2.0
  plant_sentinels
  snapshot_dir "$PREF/build" "$SB/build.before"
  snapshot_dir "$PREF/src" "$SB/src.before"
  run_crs -- 13.2.0
  assert_rc0 "repeated invocation"
  assert_eq "$(count configure 2)" 0 "no reconfiguration"
  assert_eq "$(count prereq 2)" 0 "no repeated source preparation"
  assert_eq "$(git_mutation_count 2)" 0 "no repeated source preparation"
  assert_eq "$(lines make 2 | awk -F'\t' '$5=="built"' | wc -l | tr -d ' ')" 0 "nothing recompiled"
  snapshot_dir "$PREF/build" "$SB/build.after"
  snapshot_dir "$PREF/src" "$SB/src.after"
  assert_same_snapshot "$SB/build.before" "$SB/build.after" "build tree changed on repeated run"
  assert_same_snapshot "$SB/src.before" "$SB/src.after" "source tree changed on repeated run"
  assert_sentinels_intact
  assert_packaged
}

t_r4_third_invocation_still_succeeds() {
  new_sandbox; default_sources
  build_ok 13.2.0
  build_ok 13.2.0
  build_ok 13.2.0
  assert_packaged
}

# ---- interrupted compilation / installation ------------------------------

# make fails in the given stage; the identical command line is run again.
check_make_failure_resume() { # rel key
  local d
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=make:$1:$2" -- 13.2.0
  assert_rc_nonzero "first run (make $2 fails in $1)"
  assert_output_matches 'compiling failed'
  plant_sentinels
  run_crs -- 13.2.0
  assert_rc0 "same command after failure in $1 ($2)"
  while IFS= read -r d
  do
    assert_eq "$(configured_in_run "$d" 2)" 0 "build/$d was configured fine earlier"
  done < "$SB/sentinels.list"
  assert_eq "$(count prereq 2)" 0 "sources must not be prepared again"
  assert_eq "$(git_mutation_count 2)" 0 "sources must not be prepared again"
  assert_sentinels_intact "compatible build artifact"
  assert_packaged
}

_gen_resume_tests() {
  local t kind comp key rel
  for t in "$T32" "$T64"
  do
    while read -r rel key
    do
      kind="${rel%%/*}"; comp="${rel##*/}"
      eval "t_r4_resume_after_make_failure__${t%%-*}_${kind}_${comp//-/_}__${key//-/_}() { check_make_failure_resume '$rel' '$key'; }"
    done < <(expected_make_sequence "$t")
  done
}
_gen_resume_tests

# ---- first target finished, second target fails ---------------------------

t_r4_first_target_artifacts_reused_after_second_target_failure() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=make:cross/$T64/gcc:all-gcc" -- 13.2.0
  assert_rc_nonzero "first run"
  assert_file "$PREF/install/native/$T32.zip" "first target package"
  plant_sentinels
  run_crs -- 13.2.0
  assert_rc0 "second run"
  assert_eq "$(lines make 2 | awk -F'\t' -v t="$T32" 'index($2,t) && $3 !~ /^install/ && $5=="built"' | wc -l | tr -d ' ')" 0 \
    "first target must not be recompiled"
  assert_eq "$(count configure 2 | tr -d ' ')" "$(lines configure 2 | awk -F'\t' -v t="$T64" 'index($2,t)' | wc -l | tr -d ' ')" \
    "only second-target directories may be configured in the second run"
  assert_sentinels_intact "first-target artifact"
  assert_packaged
}

t_r4_second_target_failure_before_any_second_target_output() {
  new_sandbox; default_sources
  run_crs "MOCK_FAIL=configure:cross/$T64/binutils" -- 13.2.0
  assert_rc_nonzero "first run"
  run_crs -- 13.2.0
  assert_rc0 "second run"
  assert_eq "$(configured_in_run "cross/$T64/binutils" 2)" 1 "failed configure retried"
  assert_packaged
}

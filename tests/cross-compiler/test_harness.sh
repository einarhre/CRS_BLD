# shellcheck shell=bash
# Harness sanity: simulated tools shadow real ones and a full simulated build works.

t_000_mocks_shadow_real_tools() {
  new_sandbox
  local t
  for t in make zip git pkg-config gcc cc ld curl wget mv mkdir
  do
    assert_eq "$(env "PATH=$SB/bin:$ORIG_PATH" sh -c "command -v $t")" "$SB/bin/$t" "$t is simulated"
  done
}

t_000_simulated_full_build_completes() {
  new_sandbox
  default_sources
  build_ok 13.2.0
  assert_sources_ready 13.2.0
  assert_packaged
}

# The simulated zip recognises failure injection for staged archive paths and
# damages the archive at exactly the path it was given.
t_000_fake_zip_failure_matches_staged_path() {
  new_sandbox
  mkdir -p "$PREF/install/native/tgt" "$SB/stg"
  echo x > "$PREF/install/native/tgt/f"
  ( cd "$PREF/install/native" \
    && PATH="$SB/bin:$ORIG_PATH" PREF="$PREF" MOCK_LOG="$LOG" MOCK_FAIL=zip:tgt \
       zip --filesync --recurse-paths "$SB/stg/tgt.zip" tgt 2> "$SB/zip.err" )
  assert_eq "$?" 15 "injected failure exit status"
  assert_eq "$(cat "$SB/stg/tgt.zip")" PARTIAL "staged archive damaged"
  assert_no_file "$PREF/install/native/tgt.zip" "final archive must not be touched"
  ( cd "$PREF/install/native" \
    && PATH="$SB/bin:$ORIG_PATH" PREF="$PREF" MOCK_LOG="$LOG" MOCK_FAIL=zip:other \
       zip --filesync --recurse-paths "$SB/stg/tgt.zip" tgt )
  assert_eq "$(head -n 1 "$SB/stg/tgt.zip")" MOCKZIP "non-matching spec must not fail"
}

# The simulated git clones the simulated upstream, reports the commit, and
# refuses to clone over a non-empty directory.
t_000_fake_git_clone_and_rev_parse() {
  new_sandbox
  add_git_upstream abc12345
  local g="env PATH=$SB/bin:$ORIG_PATH PREF=$PREF MOCK_LOG=$LOG MOCK_UPSTREAM=$SB/upstream MOCK_REAL_MKDIR=$REAL_MKDIR git"
  $g clone --depth 1 https://example.invalid/gcc.git "$SB/co" || fail "clone failed"
  assert_eq "$($g -C "$SB/co" rev-parse --verify HEAD)" abc12345
  assert_file "$SB/co/configure"
  $g clone https://example.invalid/gcc.git "$SB/co" 2> /dev/null && fail "clone into non-empty dir must fail"
  $g -C "$SB/missing" rev-parse HEAD 2> /dev/null && fail "rev-parse in missing dir must fail"
  assert_eq "$(count git)" 4 "all calls logged"
  assert_eq "$(awk -F'\t' '$1=="git"{print $2}' "$LOG" | grep -c '^-C .* rev-parse')" 2
}

t_000_git_mutations_ignores_read_only_queries() {
  new_sandbox
  printf 'run\t1\tx\ngit\t-C @PREF@/a rev-parse --verify HEAD\ngit\tstatus\ngit\tclone --depth 1 u d\ngit\t-C @PREF@/a pull\n' > "$LOG"
  assert_eq "$(git_mutation_count 1)" 2
}

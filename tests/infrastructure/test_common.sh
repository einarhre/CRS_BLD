# Characterization tests for etc/common.sh (current behavior, not ideals).
# Each test sources common.sh in its own fresh, controlled bash (run_common):
# the file declares readonly variables and cannot safely be sourced twice in
# one shell.  Paths reach the scripts as positional arguments or through the
# exported SB, never by interpolation into script text.  The platform is
# pinned to Linux unless a test mocks uname explicitly.

# Bash fragment: acquire "$1" and report.
_LOCK_ACQUIRE='lock_acquire "$1"; echo acquired'

# ---------------------------------------------------------------- comp_fail

t_common_comp_fail_output_and_status() {
  sandbox_new
  run_common -s -- 'comp_fail "gcc stage 1"'
  assert_rc 1 "$RC" 'comp_fail exit status'
  # exact bytes: blank line, message line, blank line
  assert_eq "$(printf '\n compiling failed: gcc stage 1\n\n' | od -An -c)" "$(od -An -c < "$OUT_FILE")" 'comp_fail output'
  assert_eq '' "$ERR" 'nothing on stderr'
}

t_common_comp_fail_is_stdout_only_and_exits_caller() {
  sandbox_new
  run_common -s -- 'comp_fail x; echo not-reached'
  assert_rc 1 "$RC" 'status'
  assert_eq '' "$ERR" 'comp_fail writes nothing to stderr'
  assert_not_contains "$OUT" not-reached 'comp_fail terminates the caller'
  # inside a subshell only the subshell exits
  run_common -- '( comp_fail sub ) || echo "sub-rc=$?"; echo after'
  assert_contains "$OUT" 'sub-rc=1' 'subshell status'
  assert_contains "$OUT" after 'parent survives a subshell comp_fail'
}

t_common_comp_fail_without_argument_is_unbound_error() {
  sandbox_new
  run_common -- 'comp_fail'
  [[ "$RC" -ne 0 ]] || fail 'expected nonzero status'
  assert_not_contains "$OUT" 'compiling failed' 'no message without a name'
  assert_contains "$OUT" 'unbound variable' 'set -u complaint'
}

# --------------------------------------------------------------- trash bin

t_common_trash_put_and_empty_removes_paths() {
  sandbox_new
  mkdir -p "$SB/d/sub"; : > "$SB/d/sub/f"; : > "$SB/file"
  : > "$SB/bin"
  run_common -- 'put_into_trash_bin "$1" "$2" "$3"; empty_trash_bin "$1"' "$SB/bin" "$SB/d" "$SB/file"
  assert_rc 0 "$RC" 'empty_trash_bin'
  assert_absent "$SB/d" 'directory removed'
  assert_absent "$SB/file" 'file removed'
  assert_absent "$SB/bin" 'bin file removed'
  assert_eq "deleted the following directories/files:
  $SB/d
  $SB/file
" "$OUT"$'\n' 'report (sorted, one per line, trailing blank line)'
}

t_common_trash_paths_with_whitespace_and_newlines() {
  sandbox_new
  local sp="$SB/with space" nl="$SB/new"$'\n'"line" lead="$SB/-rf" tab="$SB/t"$'\t'"ab" ap="$SB/it's"
  mkdir -p -- "$sp" "$nl" "$lead" "$tab" "$ap"; : > "$nl/x"
  : > "$SB/bin"
  run_common -- 'put_into_trash_bin "$@"; empty_trash_bin "$1"' "$SB/bin" "$sp" "$nl" "$lead" "$tab" "$ap"
  assert_rc 0 "$RC" 'empty_trash_bin'
  assert_absent "$sp"; assert_absent "$nl"; assert_absent "$lead"; assert_absent "$tab"; assert_absent "$ap"
  # the report prints each entry raw, so a newline splits the display line
  assert_contains "$OUT"$'\n' "  $nl"$'\n' 'newline path shown raw'
  assert_contains "$OUT"$'\n' "  $sp"$'\n' 'space path shown'
  assert_contains "$OUT"$'\n' "  $ap"$'\n' 'apostrophe path shown'
  [[ -d "$SB" ]] || fail 'sandbox itself must survive'
}

t_common_trash_entries_with_glob_chars_are_literal() {
  sandbox_new
  mkdir -p "$SB/g1" "$SB/g2"; : > "$SB/keep1"
  : > "$SB/bin"
  run_common -- 'put_into_trash_bin "$1" "$SB/g*"; empty_trash_bin "$1"' "$SB/bin"
  assert_rc 0 "$RC" 'status'
  assert_exists "$SB/g1" 'glob not expanded'
  assert_exists "$SB/g2" 'glob not expanded'
  assert_exists "$SB/keep1" 'unrelated file survives'
}

t_common_trash_duplicates_are_removed_once_and_listed_once() {
  sandbox_new
  mkdir -p "$SB/dup"; : > "$SB/bin"
  run_common -- 'put_into_trash_bin "$1" "$2" "$2"; put_into_trash_bin "$1" "$2"; empty_trash_bin "$1"' "$SB/bin" "$SB/dup"
  assert_rc 0 "$RC" 'status'
  assert_absent "$SB/dup"
  assert_eq 1 "$(count_substr "$OUT" "  $SB/dup")" 'listed exactly once'
}

t_common_trash_missing_files_are_ignored_but_still_reported() {
  sandbox_new
  : > "$SB/bin"
  run_common -- 'put_into_trash_bin "$1" "$2"; empty_trash_bin "$1"' "$SB/bin" "$SB/never-existed"
  assert_rc 0 "$RC" 'rm -f tolerates missing paths'
  assert_absent "$SB/bin"
  assert_contains "$OUT" "  $SB/never-existed" 'reported as deleted although it never existed'
}

t_common_trash_empty_and_missing_bin() {
  sandbox_new
  : > "$SB/emptybin"
  run_common -- 'empty_trash_bin "$1"' "$SB/emptybin"
  assert_rc 0 "$RC" 'empty bin'
  assert_eq '' "$OUT" 'no output for an empty bin'
  assert_absent "$SB/emptybin" 'empty bin file still removed'
  run_common -- 'empty_trash_bin "$1"' "$SB/nonexistent-bin"
  assert_rc 0 "$RC" 'missing bin is not an error'
  assert_eq '' "$OUT" 'no output for a missing bin'
}

t_common_trash_argument_and_bin_validation() {
  sandbox_new
  : > "$SB/bin"; mkdir "$SB/dirbin"
  run_common -- 'empty_trash_bin || echo e0=$?; empty_trash_bin a b || echo e2=$?
    put_into_trash_bin || echo p0=$?; put_into_trash_bin "$1" || echo p1=$?
    put_into_trash_bin "" x || echo pempty=$?; put_into_trash_bin "$2" x || echo pmissing=$?
    put_into_trash_bin "$3" x || echo pdir=$?' "$SB/bin" "$SB/missing-bin" "$SB/dirbin"
  local t
  for t in e0=1 e2=1 p0=1 p1=1 pempty=1 pmissing=1 pdir=1; do
    assert_contains "$OUT" "$t" "argument validation $t"
  done
  assert_absent "$SB/missing-bin" 'put does not create the bin'
  assert_eq 0 "$(wc -c < "$SB/bin")" 'rejected calls append nothing'
}

t_common_trash_bin_content_is_nul_separated() {
  sandbox_new
  : > "$SB/bin"
  run_common -- 'put_into_trash_bin "$1" "a b" $'"'"'c\nd'"'"'' "$SB/bin"
  assert_rc 0 "$RC" 'put'
  assert_eq "$(printf 'a b\0c\nd\0' | od -An -c | tr -s ' ')" "$(od -An -c < "$SB/bin" | tr -s ' ')" 'NUL-separated records'
}

# -------------------------------------------------------------------- locks

t_common_lock_acquire_creates_and_release_removes() {
  sandbox_new
  run_common -- 'lock_acquire "$1" && test -d "$1" && echo held; lock_release "$1"; test ! -e "$1" && echo released' "$SB/L"
  assert_rc 0 "$RC" 'acquire/release'
  assert_contains "$OUT" held; assert_contains "$OUT" released
}

t_common_lock_argument_validation() {
  sandbox_new
  run_common -- 'lock_acquire || echo a0=$?; lock_acquire x y || echo a2=$?; lock_acquire "" || echo ae=$?
    lock_release || echo r0=$?; lock_release x y || echo r2=$?; lock_release "" || echo re=$?
    lock_run || echo u0=$?; lock_run "$1" || echo u1=$?' "$SB/L"
  local t
  for t in a0=1 a2=1 ae=1 r0=1 r2=1 re=1 u0=1 u1=1; do assert_contains "$OUT" "$t" "validation $t"; done
  assert_absent "$SB/L" 'rejected lock_run must not create the lock'
}

t_common_lock_release_of_unheld_lock_fails() {
  sandbox_new
  run_common -- 'lock_release "$1" || echo rc=$?' "$SB/none"
  assert_contains "$OUT" 'rc=1' 'rmdir failure is returned'
}

t_common_lock_contention_blocks_until_release() {
  sandbox_new
  mkdir "$SB/L"
  # Held lock: a second acquirer must still be waiting after 3 seconds.
  run_common -t 3 -- "$_LOCK_ACQUIRE" "$SB/L"
  assert_eq 124 "$RC" 'acquirer times out while the lock is held'
  assert_not_contains "$OUT" acquired 'must not acquire a held lock'
  # Released after a delay: the waiter proceeds and ends up holding it.
  spawn_ctl "$SB/.run/releaser" -t 10 -- "$BASH_BIN" --noprofile --norc -c 'sleep 2; rmdir "$1"' _ "$SB/L"
  local rel="$SPAWN_PID"
  run_common -t 20 -- "$_LOCK_ACQUIRE" "$SB/L"
  local waiter_rc="$RC" waiter_out="$OUT"
  reap_ctl "$rel"
  assert_rc 0 "$waiter_rc" 'waiter acquires after release'
  assert_contains "$waiter_out" acquired
  assert_exists "$SB/L" 'waiter now holds the lock'
}

t_common_lock_run_is_mutually_exclusive() {
  sandbox_new
  local i pids=() p
  for i in 1 2 3; do
    spawn_ctl "$SB/.run/worker$i" -t 40 -- "$BASH_BIN" --noprofile --norc -c 'source "$COMMON_SH"
      section() { echo "start $1" >> "$2"; sleep 0.3; echo "end $1" >> "$2"; }
      lock_run "$3" section "$1" "$2"' _ "$i" "$SB/log" "$SB/L"
    pids+=("$SPAWN_PID")
  done
  # Any early failure below leaves workers running; the runner reaps them.
  for p in "${pids[@]}"; do reap_ctl "$p"; [[ "$RC" -eq 0 ]] || fail "worker exit $RC"; done
  assert_eq 6 "$(wc -l < "$SB/log")" 'six log lines'
  local expect="" line k=0
  while IFS= read -r line; do
    if (( k % 2 == 0 )); then
      [[ "$line" == start* ]] || fail "interleaved: $(cat "$SB/log")"; expect="end ${line#start }"
    else
      [[ "$line" == "$expect" ]] || fail "interleaved: $(cat "$SB/log")"
    fi
    k=$((k + 1))
  done < "$SB/log"
  assert_absent "$SB/L" 'lock released at the end'
}

t_common_lock_run_success_passes_arguments_and_releases() {
  sandbox_new
  run_common -- 'f() { echo "args=$# [$1] [$2]"; }; lock_run "$1" f "a b" ""; echo rc=$?; test ! -e "$1" && echo free' "$SB/L"
  assert_contains "$OUT" 'args=2 [a b] []'
  assert_contains "$OUT" 'rc=0'; assert_contains "$OUT" free
}

t_common_lock_run_failure_status_released_when_errexit_suppressed() {
  sandbox_new
  # In an `||` context set -e is inactive, so the failure status is returned
  # and the lock IS released.  Contrast with k_common_lock_run_leaks_*.
  run_common -- 'lock_run "$1" false || echo status=$?; test ! -e "$1" && echo free' "$SB/L"
  assert_contains "$OUT" 'status=1'; assert_contains "$OUT" free
}

t_common_lock_run_ignores_release_failure() {
  sandbox_new
  run_common -- 'f() { rmdir "$L"; }; L="$1"; lock_run "$1" f; echo rc=$?' "$SB/L"
  assert_contains "$OUT" 'rc=0' 'a vanished lock does not change the status'
}

k_common_lock_run_leaks_lock_when_command_fails_under_errexit() {
  # KNOWN DEFECT: common.sh enables `set -e`; lock_run runs "$@" as a plain
  # command, so a failing command aborts the shell before lock_release.  The
  # lock directory is left behind and the next acquirer waits forever.
  # Reproduced -> exit 0; non-gating.
  sandbox_new
  run_common -- 'lock_run "$1" false; echo not-reached' "$SB/L"
  [[ "$RC" -ne 0 ]] || fail "shell was not aborted (rc=$RC)"
  assert_not_contains "$OUT" not-reached 'errexit aborted the shell'
  assert_exists "$SB/L" 'defect: lock directory leaked'
  run_common -t 3 -- "$_LOCK_ACQUIRE" "$SB/L"
  assert_eq 124 "$RC" 'defect: next acquirer blocks (killed by timeout)'
  echo "lock leaked after failing command; next acquirer timed out"
}

k_common_lock_acquire_spins_forever_when_parent_missing() {
  # KNOWN DEFECT: mkdir errors are hidden, so an uncreatable lock path (missing
  # parent directory) is indistinguishable from contention; the loop never ends.
  sandbox_new
  run_common -t 3 -- "$_LOCK_ACQUIRE" "$SB/no/such/parent/L"
  assert_eq 124 "$RC" 'spins until killed'
  echo "lock_acquire on an uncreatable path never returns"
}

# --------------------------------------------------------------------- NCRS

t_common_ncrs_accepts_positive_integers() {
  sandbox_new
  local v
  for v in 1 4 16 007 08 010 +4 ' 4'; do
    run_common "NCRS=$v" -- 'echo "NCRS=[$NCRS]"'
    assert_rc 0 "$RC" "NCRS=[$v] accepted"
    assert_eq "NCRS=[$v]" "$OUT" "NCRS=[$v] preserved verbatim, no diagnostic"
  done
}

t_common_ncrs_rejects_zero_and_negative() {
  sandbox_new
  local v
  for v in 0 -1 -0 -100 000; do
    run_common -s "NCRS=$v" -- 'echo reached'
    assert_rc 1 "$RC" "NCRS=$v rejected"
    assert_eq 'No processing units appear to be available for this machine (nproc --all)!' "$OUT" "NCRS=$v message (stdout)"
    assert_eq '' "$ERR" "NCRS=$v: nothing on stderr"
  done
}

t_common_ncrs_unset_or_empty_defaults_to_nproc() {
  sandbox_new
  local n; n="$(nproc --all)"
  run_common -- 'echo "$NCRS"'
  assert_eq "$n" "$OUT" 'unset -> nproc --all'
  run_common NCRS= -- 'echo "$NCRS"'
  assert_eq "$n" "$OUT" 'empty -> nproc --all'
}

t_common_ncrs_malformed_values_are_accepted_with_test_diagnostic() {
  # Current behavior (a validation gap, see report): `[ "$NCRS" -le 0 ]` returns
  # status 2 for a non-integer, which `if` treats as false.  The value is
  # accepted unchanged, with only a bash diagnostic, and common.sh succeeds.
  sandbox_new
  local v
  for v in abc 4x 1.5 0x10 '1 2' '4;' 99999999999999999999; do
    run_common -s "NCRS=$v" -- 'echo "NCRS=[$NCRS]"'
    assert_rc 0 "$RC" "malformed NCRS=[$v] does not fail"
    assert_contains "$ERR" 'integer expression expected' "diagnostic for [$v] on stderr"
    assert_eq "NCRS=[$v]" "$OUT" "[$v] kept as is"
  done
}

t_common_ncrs_is_readonly() {
  sandbox_new
  run_common NCRS=3 -- 'NCRS=5'
  assert_rc 1 "$RC" 'assignment fails'
  assert_contains "$OUT" 'readonly variable'
  run_common NCRS=3 -- 'declare -p NCRS'
  [[ "$OUT" =~ ^declare\ -r[a-z]*\ NCRS=\"3\"$ ]] || fail "NCRS not readonly: $OUT"
}

# ------------------------------------------------- shared dirs and constants

t_common_directories_and_target_constants() {
  sandbox_new
  run_common -- 'printf "%s\n" "$PREF" "$SOURCE_DIRECTORY" "$BUILD_DIRECTORY" "$INSTALL_DIRECTORY" "$TRG32" "$TRG64" "${#TARGETS[@]}" "${TARGETS[0]}" "${TARGETS[1]}"'
  assert_rc 0 "$RC" source
  assert_eq "$SB/pref
$SB/pref/src
$SB/pref/build
$SB/pref/install
i686-w64-mingw32
x86_64-w64-mingw32
2
i686-w64-mingw32
x86_64-w64-mingw32" "$OUT" 'constants'
  [[ ! -e "$SB/pref" ]] || fail 'sourcing must not create directories'
}

t_common_pref_defaults_to_repository_root() {
  sandbox_new
  run_common -PREF -- 'echo "$PREF"'
  assert_rc 0 "$RC" source
  assert_eq "$CRS_ROOT" "$OUT" 'PREF defaults to the checkout containing etc/'
  run_common PREF= -- 'echo "$PREF"'
  assert_eq "$CRS_ROOT" "$OUT" 'empty PREF -> default'
}

t_common_pref_default_ignores_cwd_and_keeps_symlinked_path() {
  sandbox_new
  mkdir -p "$SB/elsewhere"
  run_common -C "$SB/elsewhere" -PREF -- 'echo "$PREF"'
  assert_eq "$CRS_ROOT" "$OUT" 'cwd does not matter'
  # Sourced through a symlinked checkout, the default is the logical
  # (unresolved) path: dirname of BASH_SOURCE with `cd` and plain `pwd`.
  ln -s -- "$CRS_ROOT" "$SB/link to checkout"
  run_ctl -C "$SB/elsewhere" -PREF -- "$BASH_BIN" --noprofile --norc -c 'source "$1"; echo "$PREF"' _ "$SB/link to checkout/etc/common.sh"
  assert_rc 0 "$RC" 'source via symlink'
  assert_eq "$SB/link to checkout" "$OUT" 'symlink path is not resolved'
}

t_common_constants_are_readonly() {
  sandbox_new
  local v
  for v in PREF SOURCE_DIRECTORY BUILD_DIRECTORY INSTALL_DIRECTORY TRG32 TRG64 PKG_CONFIG_BIN; do
    run_common -- "declare -p $v"
    [[ "$OUT" =~ ^declare\ -[a-zA-Z]*r ]] || fail "$v is not declared readonly: $OUT"
    run_common -- "$v=x"
    assert_rc 1 "$RC" "$v is readonly"
    assert_contains "$OUT" 'readonly variable' "$v assignment message"
  done
  run_common -- 'TARGETS+=(x)'
  assert_rc 1 "$RC" 'TARGETS is readonly'
}

t_common_pkg_config_bin_is_resolved_from_path() {
  sandbox_new
  mkdir "$SB/bin"
  printf '#!/bin/sh\nexit 0\n' | write_exe "$SB/bin/pkg-config"
  run_common "PATH=$SB/bin:$CTL_BIN" -- 'echo "$PKG_CONFIG_BIN"; declare -p PKG_CONFIG_BIN'
  assert_rc 0 "$RC" source
  assert_eq "$SB/bin/pkg-config" "${OUT%%$'\n'declare*}" 'first pkg-config on PATH wins'
  assert_contains "$OUT" 'declare -r PKG_CONFIG_BIN'
}

t_common_missing_pkg_config_fails_on_stderr() {
  sandbox_new
  make_tool_dir "$SB/tools" dirname nproc
  ln -s -- "$CTL_BIN/uname" "$SB/tools/uname"
  run_common -s "PATH=$SB/tools" -- 'echo reached'
  assert_rc 1 "$RC" 'missing pkg-config'
  assert_eq 'pkg-config was not found on PATH.' "$ERR" 'stderr message'
  assert_eq '' "$OUT" 'nothing on stdout'
}

# ------------------------------------------------------------ Homebrew/PATH

# _mock_platform DIR OS [BREW_PREFIX]: uname reporting OS, optional brew mock
# that only answers `brew --prefix` (and logs every call), and pkg-config.
_mock_platform() {
  local d="$1" os="$2" brew="${3:-}"
  mkdir -p "$d"
  printf '#!/bin/sh\necho %s\n' "$os" | write_exe "$d/uname"
  if [[ -n "$brew" ]]; then
    printf '%s\n' "$brew" > "$d/brew.prefix"
    printf '#!/bin/sh\necho "$*" >> "%s/brew.log"\n[ "$1" = --prefix ] && [ $# -eq 1 ] && cat "%s/brew.prefix"\nexit 0\n' "$d" "$d" | write_exe "$d/brew"
  fi
  printf '#!/bin/sh\nexit 0\n' | write_exe "$d/pkg-config"
}

t_common_linux_leaves_path_untouched() {
  sandbox_new
  _mock_platform "$SB/m" Linux "$SB/brewroot"
  run_common "PATH=$SB/m:$CTL_BIN" -- 'echo "$PATH"'
  assert_rc 0 "$RC" source
  assert_eq "$SB/m:$CTL_BIN" "$OUT" 'PATH unchanged on non-Darwin'
  assert_absent "$SB/m/brew.log" 'brew not consulted on Linux'
}

t_common_default_platform_is_pinned_linux() {
  # The controlled environment's uname reports Linux, so even on a macOS host
  # common.sh takes the non-Darwin branch and never calls a real brew.
  sandbox_new
  run_common -- 'echo "$(uname -s) $PATH"'
  assert_eq "Linux $CTL_BIN" "$OUT" 'pinned uname and untouched PATH'
}

t_common_darwin_prepends_homebrew_gnu_tools_in_order() {
  sandbox_new
  _mock_platform "$SB/m" Darwin "/opt/mock brew"
  run_common "PATH=$SB/m:$CTL_BIN" -- 'echo "$PATH"'
  assert_rc 0 "$RC" source
  local b="/opt/mock brew" expect='' d
  for d in opt/flex/bin opt/bison/bin opt/texinfo/bin opt/zip/bin opt/gpatch/libexec/gnubin \
           opt/libtool/libexec/gnubin opt/gnu-tar/libexec/gnubin opt/make/libexec/gnubin \
           opt/grep/libexec/gnubin opt/gnu-sed/libexec/gnubin opt/findutils/libexec/gnubin \
           opt/coreutils/libexec/gnubin bin sbin; do
    expect+="$b/$d:"
  done
  assert_eq "$expect$SB/m:$CTL_BIN" "$OUT" 'Homebrew directories prepended in documented order'
  assert_eq '--prefix' "$(cat "$SB/m/brew.log")" 'brew called once as `brew --prefix`'
}

t_common_darwin_without_brew_fails() {
  sandbox_new
  _mock_platform "$SB/m" Darwin
  make_tool_dir "$SB/tools" dirname nproc
  run_common -s "PATH=$SB/m:$SB/tools" -- 'echo reached'
  assert_rc 1 "$RC" 'Darwin without brew'
  assert_eq 'Homebrew is required to build CRS_BLD on macOS.' "$ERR" 'stderr message'
  assert_eq '' "$OUT" 'no stdout, pkg-config check never reached'
}

t_common_darwin_homebrew_path_precedes_mock_tools() {
  # The mocked Homebrew GNU directory shadows a same-named tool later on PATH.
  sandbox_new
  _mock_platform "$SB/m" Darwin "$SB/hb"
  mkdir -p "$SB/hb/opt/coreutils/libexec/gnubin"
  printf '#!/bin/sh\necho 7\n' | write_exe "$SB/hb/opt/coreutils/libexec/gnubin/nproc"
  run_common "PATH=$SB/m:$CTL_BIN" -- 'echo "$NCRS"'
  assert_rc 0 "$RC" source
  assert_eq 7 "$OUT" 'GNU nproc from the Homebrew prefix is used for the NCRS default'
}

t_common_legacy_check_pc_vs_files_is_defined() {
  # common.sh still carries an older one-argument check_pc_vs_files that
  # etc/diagnostics.sh later overrides with a three-argument version.
  sandbox_new
  local p="$SB/prefix"
  mkdir -p "$p/lib/pkgconfig" "$p/lib64"
  printf 'Libs: -lgone -lhere\n' > "$p/lib/pkgconfig/a.pc"
  : > "$p/lib/libhere.a"
  run_common -- 'declare -F check_pc_vs_files >/dev/null && echo defined; check_pc_vs_files "$1"' "$p"
  # It reports the right library but still exits 1 (status of the last pipeline).
  assert_rc 1 "$RC" 'legacy checker exit status'
  assert_eq "defined
== $p ==
MISSING: $p/lib/pkgconfig/a.pc -> -lgone" "$OUT" 'legacy checker output with both lib dirs present'
  # Quirk: with lib64 absent, find exits nonzero and pipefail makes every
  # library look missing.
  rmdir "$p/lib64"
  run_common -- 'check_pc_vs_files "$1"' "$p"
  assert_rc 1 "$RC" 'legacy checker without lib64'
  assert_contains "$OUT" "a.pc -> -lhere" 'present library falsely reported'
}

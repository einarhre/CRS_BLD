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

# --------------------------------------------------------------------- NCRS

t_common_ncrs_accepts_and_canonicalizes_decimal() {
  sandbox_new
  local pair
  for pair in 1:1 4:4 16:16 007:7 08:8 010:10 4096:4096 0004096:4096; do
    run_common -s "NCRS=${pair%:*}" -- 'echo "$NCRS"'
    assert_rc 0 "$RC" "$pair accepted"
    assert_eq "${pair#*:}" "$OUT" 'canonical decimal'
    assert_eq '' "$ERR" 'valid explicit input is quiet'
  done
}

t_common_ncrs_invalid_rejected_before_host_setup_or_mutation() {
  sandbox_new
  local v script
  # Exercise both real drivers and common itself, including Unicode digits.
  for v in '' 0 00 -0 -1 +4 ' 4' '4 ' 4x 1.5 0x10 1e3 '1 2' '4;' 4097 2147483648 999999999999999999999999999999 ０８ ١٢; do
    for script in "$PKGS_SH" "$CRS_ROOT/make_cross-compiler.sh" "$COMMON_SH"; do
      run_ctl -s "NCRS=$v" MOCK_UNAME=Darwin -- "$BASH_BIN" --noprofile --norc "$script"
      assert_rc 1 "$RC" "[$v] rejected by $script"
      assert_contains "$ERR" NCRS 'NCRS wins over missing Homebrew'
      assert_not_contains "$ERR" Homebrew 'no host setup first'
      assert_eq '' "$OUT" 'no stdout'
      assert_absent "$SB/pref" 'no prefix mutation'
      assert_eq '' "$(ls -A "$SB/tmp")" 'no temporary allocation'
    done
  done
  ctl_replace pkg-config "$SB/missing-pkg-config"
  run_common -s NCRS=abc -- ':'
  assert_contains "$ERR" NCRS 'NCRS wins over missing pkg-config'
  assert_not_contains "$ERR" 'pkg-config' 'explicit preflight precedes lookup'
}

t_common_ncrs_unset_uses_validated_nproc_default() {
  sandbox_new
  printf '#!/bin/sh\n[ "$*" = --all ] || exit 9\nprintf "%%s" "$MOCK_NPROC"\nexit "$MOCK_NPROC_RC"\n' | write_exe "$SB/nproc"
  ctl_replace nproc "$SB/nproc"
  local value
  for value in 7 0007 5000 999999999999999999999999999999; do
    run_common -s "MOCK_NPROC=$value" MOCK_NPROC_RC=0 -- 'echo "$NCRS"'
    assert_rc 0 "$RC" 'default accepted'
    if [[ "$value" == 7 || "$value" == 0007 ]]; then
      assert_eq 7 "$OUT" 'canonical default'; assert_eq '' "$ERR" 'quiet default'
    else
      assert_eq 4096 "$OUT" 'default clamped'; assert_contains "$ERR" 'clamping to 4096'
    fi
  done
  for value in '' abc 0 00 +4 '7 ' ０８; do
    run_common -s "MOCK_NPROC=$value" MOCK_NPROC_RC=0 -- 'echo reached'
    assert_rc 1 "$RC" 'invalid default rejected'
    assert_contains "$ERR" 'nproc --all'; assert_eq '' "$OUT" 'not reached'
  done
  run_common -s MOCK_NPROC=7 MOCK_NPROC_RC=3 -- ':'
  assert_rc 1 "$RC" 'even plausible output with failed nproc is rejected'
  assert_contains "$ERR" 'nproc --all failed'
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

t_common_has_only_shared_functions() {
  sandbox_new
  run_common -- 'declare -F | sed "s/declare -f //"'
  assert_rc 0 "$RC" 'source common'
  assert_eq comp_fail "$OUT" 'no package helpers or legacy checker'
}

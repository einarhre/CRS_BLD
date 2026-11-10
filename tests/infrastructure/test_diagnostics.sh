# Characterization tests for etc/diagnostics.sh using fabricated install trees.
# The assertions record what the script does today (including its quirks), not
# what a corrected diagnostics script should do.  Output paths are normalized:
# the sandbox's fabricated root is shown as ROOT.

# A .pc file is line-based: a prefix containing a newline cannot be written
# into one, so these tests skip (rather than misreport) under such a TMPDIR.
diag_sandbox() {
  sandbox_new
  [[ "$SB" != *$'\n'* ]] || skip 'sandbox path contains a newline; .pc variables cannot represent it'
}

# diag_prefix TRG KIND -> creates and prints the prefix directory
diag_prefix() {
  local p="$SB/root/$1/$2"
  mkdir -p "$p/lib/pkgconfig"
  printf '%s\n' "$p"
}

# mkpc FILE PREFIX LIBS_LINE [EXTRA_LINES...]: a .pc with standard variables
mkpc() {
  local f="$1" prefix="$2" libs="$3"; shift 3
  mkdir -p "$(dirname -- "$f")"
  {
    printf 'prefix=%s\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\n' "$prefix"
    printf 'Name: t\nDescription: t\nVersion: 1\n'
    printf '%s\n' "$libs"
    (( $# == 0 )) || printf '%s\n' "$@"
  } > "$f"
}

# run_diag [args...]: RC and OUT (normalized); runs from the sandbox as cwd in
# the controlled environment (pinned Linux platform, no host PATH).
run_diag() {
  run_ctl NCRS=4 -- "$BASH_BIN" --noprofile --norc "$DIAG_SH" "$@"
  OUT="${OUT//"$SB/root"/ROOT}"
  OUT="$(norm_sb "$OUT")"
}

t_diag_valid_package_reports_only_header() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo -lm'
  run_diag "$SB/root"
  assert_rc 0 "$RC" 'exit status'
  assert_eq "SKIP: missing prefix: ROOT/$TRG32/static
SKIP: missing prefix: ROOT/$TRG32/shared

== $TRG64/static ==

SKIP: missing prefix: ROOT/$TRG64/shared" "$OUT" 'valid package output'
}

t_diag_missing_library_reported_for_libs_and_libs_private() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo -lpub' 'Libs.private: -lpriv -lfoo'
  run_diag "$SB/root"
  assert_rc 0 "$RC" 'problems do not change the exit status'
  assert_contains "$OUT" "MISSING_LIB_FROM_PC: lib/pkgconfig/foo.pc
  pc wants : -lpriv
  searched : ROOT/$TRG64/static/lib and ROOT/$TRG64/static/lib64
" 'private lib'
  assert_contains "$OUT" '  pc wants : -lpub' 'public lib'
  assert_not_contains "$OUT" '-lfoo' 'present library not reported'
  assert_eq 2 "$(count_prefixed_lines "$OUT" MISSING_LIB_FROM_PC)" 'one report per missing library'
}

t_diag_libraries_listed_once_per_pc_even_if_repeated() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -lx -lx' 'Libs.private: -lx'
  run_diag "$SB/root"
  assert_eq 1 "$(count_prefixed_lines "$OUT" MISSING_LIB_FROM_PC)" 'sort -u de-duplicates names across Libs lines'
}

t_diag_missing_library_directories() {
  diag_sandbox
  local p="$SB/root/$TRG64/static"
  mkdir -p "$p/share/pkgconfig"     # no lib/ and no lib64/
  mkpc "$p/share/pkgconfig/foo.pc" "$p" 'Libs: -lfoo'
  run_diag "$SB/root"
  assert_rc 0 "$RC" status
  assert_contains "$OUT" "BAD_LIBDIR: $(printf %s "ROOT/$TRG64/static")/share/pkgconfig/foo.pc
  pc libdir: \${exec_prefix}/lib
  expands : ROOT/$TRG64/static/lib
" 'libdir does not exist'
  assert_contains "$OUT" 'MISSING_LIB_FROM_PC: share/pkgconfig/foo.pc' 'library missing as well'
}

t_diag_prefix_without_pkgconfig_directories_is_silent() {
  diag_sandbox
  mkdir -p "$SB/root/$TRG64/static/lib"
  run_diag "$SB/root"
  assert_rc 0 "$RC" status
  assert_not_contains "$OUT" '== ' 'no header when no pkgconfig dir exists'
  assert_contains "$OUT" "SKIP: missing prefix: ROOT/$TRG64/shared"
  assert_not_contains "$OUT" "missing prefix: ROOT/$TRG64/static" 'existing prefix is not skipped'
}

t_diag_empty_pkgconfig_directory_prints_header_only() {
  diag_sandbox
  diag_prefix $TRG64 shared >/dev/null
  run_diag "$SB/root"
  assert_contains "$OUT" "
== $TRG64/shared ==" 'header'
  assert_not_contains "$OUT" MISSING; assert_not_contains "$OUT" BAD_LIBDIR
}

t_diag_duplicate_pc_names_across_directories() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkdir -p "$p/lib64/pkgconfig" "$p/share/pkgconfig"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo'
  mkpc "$p/lib64/pkgconfig/foo.pc" "$p" 'Libs: -lfoo'
  mkpc "$p/share/pkgconfig/foo.pc" "$p" 'Libs: -lfoo'
  run_diag "$SB/root"
  assert_rc 0 "$RC" status
  # find output is sorted: lib/ < lib64/ < share/ ; first is kept, each later
  # copy is reported against the first.
  assert_contains "$OUT" "DUPLICATE_PC: foo
  first: ROOT/$TRG64/static/lib/pkgconfig/foo.pc
  again: ROOT/$TRG64/static/lib64/pkgconfig/foo.pc
DUPLICATE_PC: foo
  first: ROOT/$TRG64/static/lib/pkgconfig/foo.pc
  again: ROOT/$TRG64/static/share/pkgconfig/foo.pc" 'duplicates'
  assert_eq 2 "$(count_prefixed_lines "$OUT" DUPLICATE_PC)" 'count'
}

t_diag_same_pc_name_in_different_targets_is_not_duplicate() {
  diag_sandbox
  local t p
  for t in $TRG32 $TRG64; do
    p="$(diag_prefix $t static)"
    : > "$p/lib/libfoo.a"
    mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo'
  done
  run_diag "$SB/root"
  assert_not_contains "$OUT" DUPLICATE_PC 'duplicate tracking is per prefix'
}

t_diag_pc_directory_mismatch() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkdir -p "$p/lib64/pkgconfig"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib64/pkgconfig/foo.pc" "$p" 'Libs: -L${prefix}/lib64 -lfoo'
  run_diag "$SB/root"
  assert_rc 0 "$RC" status
  assert_contains "$OUT" "PC_FILE_LOCATION_MISMATCH: lib64/pkgconfig/foo.pc
  pc wants      : -lfoo
  pc -L dirs    :
    ROOT/$TRG64/static/lib64
  actual files  :
    ROOT/$TRG64/static/lib/libfoo.a
" 'mismatch report'
}

t_diag_libdir_matching_any_actual_location_is_accepted() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkdir -p "$p/lib64"
  : > "$p/lib/libfoo.a"; : > "$p/lib64/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${prefix}/lib64 -lfoo'
  run_diag "$SB/root"
  assert_not_contains "$OUT" PC_FILE_LOCATION_MISMATCH 'one of two copies matches'
}

t_diag_no_L_flag_means_no_location_check() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkdir -p "$p/lib64"
  : > "$p/lib64/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -lfoo'
  run_diag "$SB/root"
  assert_not_contains "$OUT" PC_FILE_LOCATION_MISMATCH
  assert_not_contains "$OUT" MISSING
}

t_diag_variable_expansion_chain_and_unusual_variables() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  {
    printf 'prefix=%s\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\n' "$p"
    printf 'sharedlibdir=${libdir}\ntoolexeclibdir=${libdir}/../lib\n'
    printf 'Libs: -L${sharedlibdir} -L${toolexeclibdir} -lfoo\n'
  } > "$p/lib/pkgconfig/foo.pc"
  run_diag "$SB/root"
  assert_not_contains "$OUT" BAD_LIBDIR; assert_not_contains "$OUT" PC_FILE_LOCATION_MISMATCH
  assert_not_contains "$OUT" MISSING
}

t_diag_pc_without_exec_prefix_uses_prefix_default() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  printf 'prefix=%s\nlibdir=${exec_prefix}/lib\nLibs: -L${libdir} -lfoo\n' "$p" > "$p/lib/pkgconfig/foo.pc"
  run_diag "$SB/root"
  assert_eq "== $TRG64/static ==" "$(grep -F '==' <<< "$OUT")" 'only the header'
  assert_not_contains "$OUT" BAD_LIBDIR 'exec_prefix defaults to ${prefix}'
}

t_diag_unresolvable_variable_is_not_rejected_but_changes_path() {
  # An unknown ${var} survives five substitution rounds and is then passed to
  # `realpath -m`, i.e. interpreted relative to the current directory.
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${pcfiledir}/.. -lfoo'
  run_diag "$SB/root"
  assert_rc 0 "$RC" status
  assert_contains "$OUT" 'PC_FILE_LOCATION_MISMATCH: lib/pkgconfig/foo.pc'
  # "${pcfiledir}/.." normalizes to the current directory, which is the sandbox (SB)
  grep -qx '    SB' <<< "$OUT" || fail "expected the cwd as the only -L dir: $OUT"
}

t_diag_system_libraries_are_exempt() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  local libs=(m dl rt pthread atomic 'stdc++' gcc gcc_s mingw32 mingwex msvcrt ucrt ksuser
    cfgmgr32 kernel32 user32 gdi32 winspool shell32 ole32 oleaut32 uuid comdlg32 advapi32 bcrypt crypt32
    ws2_32 winmm shlwapi dnsapi iphlpapi setupapi comctl32 dwmapi imm32 opengl32 hid
    dwrite d2d1 windowscodecs msimg32 dxguid psapi netio secur32 wldap32)
  local line='Libs:' l
  for l in "${libs[@]}"; do line+=" -l$l"; done
  mkpc "$p/lib/pkgconfig/sys.pc" "$p" "$line"
  run_diag "$SB/root"
  assert_not_contains "$OUT" MISSING "all ${#libs[@]} exempt libraries ignored"
}

t_diag_system_library_exemption_is_exact_name_only() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkpc "$p/lib/pkgconfig/x.pc" "$p" 'Libs: -lm -lmx -lkernel32 -lkernel32x -lz -lstdc++fs -lws2_32 -lWS2_32'
  run_diag "$SB/root"
  local w
  for w in mx kernel32x z 'stdc++fs' WS2_32; do assert_contains "$OUT" "  pc wants : -l$w" "-l$w is not exempt"; done
  for w in ' -lm$' ' -lkernel32$' ' -lws2_32$'; do
    ! grep -Eq -- "pc wants : $w" <<< "$OUT" || fail "exempt library reported: $w"
  done
}

t_diag_static_vs_shared_import_library_names() {
  diag_sandbox
  local ps pd
  ps="$(diag_prefix $TRG64 static)"; pd="$(diag_prefix $TRG64 shared)"
  : > "$ps/lib/libs1.a"; : > "$ps/lib/libs2.dll.a"; : > "$ps/lib/libs3.so"; : > "$ps/lib/libs4.lib"
  mkpc "$ps/lib/pkgconfig/s.pc" "$ps" 'Libs: -L${libdir} -ls1 -ls2 -ls3 -ls4'
  : > "$pd/lib/libd1.dll.a"; : > "$pd/lib/libd2.dll"; : > "$pd/lib/libd2.so.1"
  mkdir -p "$pd/bin"; : > "$pd/bin/d3.dll"
  mkpc "$pd/lib/pkgconfig/d.pc" "$pd" 'Libs: -L${libdir} -ld1 -ld2 -ld3'
  run_diag "$SB/root"
  assert_contains "$OUT" "== $TRG64/static ==" ; assert_contains "$OUT" "== $TRG64/shared =="
  # only lib<name>.a and lib<name>.dll.a count, in both kinds of prefix
  assert_contains "$OUT" '  pc wants : -ls3'; assert_contains "$OUT" '  pc wants : -ls4'
  assert_contains "$OUT" '  pc wants : -ld2'; assert_contains "$OUT" '  pc wants : -ld3'
  assert_not_contains "$OUT" '-ls1'; assert_not_contains "$OUT" '-ls2'; assert_not_contains "$OUT" '-ld1'
  assert_eq 4 "$(count_prefixed_lines "$OUT" MISSING_LIB_FROM_PC)" 'exactly the four unsupported names'
}

t_diag_static_kind_is_processed_before_shared_and_i686_before_x86_64() {
  diag_sandbox
  local t k p
  for t in $TRG64 $TRG32; do for k in shared static; do
    p="$(diag_prefix $t $k)"
  done; done
  run_diag "$SB/root"
  assert_eq "== $TRG32/static ==
== $TRG32/shared ==
== $TRG64/static ==
== $TRG64/shared ==" "$(grep -F '==' <<< "$OUT")" 'fixed order: targets then kinds'
}

t_diag_both_target_architectures_are_checked_independently() {
  diag_sandbox
  local p32 p64
  p32="$(diag_prefix $TRG32 static)"; p64="$(diag_prefix $TRG64 static)"
  : > "$p32/lib/libok.a"
  mkpc "$p32/lib/pkgconfig/a.pc" "$p32" 'Libs: -L${libdir} -lok'
  mkpc "$p64/lib/pkgconfig/a.pc" "$p64" 'Libs: -L${libdir} -lbad'
  run_diag "$SB/root"
  local out32="${OUT%%== $TRG64*}"
  assert_not_contains "$out32" MISSING 'i686 section clean'
  assert_contains "${OUT#*== $TRG64/static ==}" '-lbad' 'x86_64 section reports its own problem'
  # a library present only in the other architecture does not satisfy it
  : > "$p32/lib/libbad.a"
  run_diag "$SB/root"
  assert_contains "${OUT#*== $TRG64/static ==}" '-lbad' 'no cross-architecture matching'
}

t_diag_lib64_and_share_pkgconfig_are_scanned() {
  diag_sandbox
  local p="$SB/root/$TRG64/static"
  mkdir -p "$p/lib64/pkgconfig" "$p/share/pkgconfig"
  : > "$p/lib64/libx.a"
  mkpc "$p/lib64/pkgconfig/a.pc" "$p" 'Libs: -L${prefix}/lib64 -lx -lq1'
  mkpc "$p/share/pkgconfig/b.pc" "$p" 'Libs: -lq2'
  run_diag "$SB/root"
  assert_contains "$OUT" 'MISSING_LIB_FROM_PC: lib64/pkgconfig/a.pc'
  assert_contains "$OUT" 'MISSING_LIB_FROM_PC: share/pkgconfig/b.pc'
  assert_not_contains "$OUT" '-lx'
}

t_diag_symlinked_library_file_and_directory_are_followed() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkdir -p "$p/store"; : > "$p/store/libreal.a"
  ln -s ../store/libreal.a "$p/lib/liblinked.a"        # file symlink in lib/
  ln -s lib "$p/lib64"                                  # lib64 -> lib
  mkpc "$p/lib/pkgconfig/l.pc" "$p" 'Libs: -L${libdir} -llinked'
  run_diag "$SB/root"
  assert_not_contains "$OUT" MISSING 'symlinked file satisfies the check (find -L)'
  assert_not_contains "$OUT" PC_FILE_LOCATION_MISMATCH 'lib64 alias resolves to the same files'
}

t_diag_dangling_library_symlink_counts_as_missing() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  ln -s nowhere "$p/lib/libdead.a"
  mkpc "$p/lib/pkgconfig/d.pc" "$p" 'Libs: -L${libdir} -ldead'
  run_diag "$SB/root"
  assert_contains "$OUT" '  pc wants : -ldead'
}

t_diag_symlinked_pc_file_is_not_scanned() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkpc "$SB/real.pc" "$p" 'Libs: -lmissing'
  ln -s "$SB/real.pc" "$p/lib/pkgconfig/link.pc"
  run_diag "$SB/root"
  assert_not_contains "$OUT" MISSING 'find -type f skips .pc symlinks'
  assert_contains "$OUT" "== $TRG64/static =="
}

t_diag_symlinked_root_reports_false_location_mismatch() {
  # realpath resolves the symlinked root for -L directories while find reports
  # library paths under the symlink path, so a correct package mismatches.
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo'
  run_diag "$SB/root"
  assert_not_contains "$OUT" PC_FILE_LOCATION_MISMATCH 'direct path: clean'
  ln -s root "$SB/rootlink"
  run_diag "$SB/rootlink"
  assert_rc 0 "$RC" status
  assert_contains "$OUT" 'PC_FILE_LOCATION_MISMATCH: lib/pkgconfig/foo.pc' 'via symlinked root'
}

t_diag_missing_root_skips_all_four_prefixes() {
  diag_sandbox
  run_diag "$SB/nonexistent"
  assert_rc 0 "$RC" status
  assert_eq "SKIP: missing prefix: SB/nonexistent/$TRG32/static
SKIP: missing prefix: SB/nonexistent/$TRG32/shared
SKIP: missing prefix: SB/nonexistent/$TRG64/static
SKIP: missing prefix: SB/nonexistent/$TRG64/shared" "$OUT"
}

t_diag_default_root_is_pref_install_pkg() {
  diag_sandbox
  local p="$SB/pref/install/pkg/$TRG64/static"
  mkdir -p "$p/lib/pkgconfig"; : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo -lnope'
  run_diag
  assert_rc 0 "$RC" status
  assert_contains "$OUT" "SKIP: missing prefix: SB/pref/install/pkg/$TRG32/static"
  assert_contains "$OUT" "== $TRG64/static =="
  assert_contains "$OUT" '  pc wants : -lnope'
}

t_diag_only_first_argument_is_used() {
  diag_sandbox
  mkdir -p "$SB/second"
  run_diag "$SB/root" "$SB/second"
  assert_rc 0 "$RC" status
  assert_contains "$OUT" "ROOT/$TRG32/static"
  assert_not_contains "$OUT" 'second'
}

t_diag_exit_status_is_zero_even_with_all_defect_kinds() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  mkdir -p "$p/lib64/pkgconfig"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${prefix}/elsewhere -lfoo -lgone' 'Libs.private: -lzzz'
  mkpc "$p/lib64/pkgconfig/foo.pc" "$p" 'Libs: -lfoo'
  printf 'prefix=%s\nlibdir=${prefix}/nodir\nLibs: -lfoo\n' "$p" > "$p/lib64/pkgconfig/bar.pc"
  run_diag "$SB/root"
  assert_rc 0 "$RC" 'diagnostics are informational'
  local k
  for k in BAD_LIBDIR MISSING_LIB_FROM_PC PC_FILE_LOCATION_MISMATCH DUPLICATE_PC; do
    assert_contains "$OUT" "$k:" "$k reported"
  done
}

t_diag_pc_libdir_check_runs_even_when_no_libs_listed() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  printf 'prefix=%s\nlibdir=${prefix}/nodir\nName: x\n' "$p" > "$p/lib/pkgconfig/x.pc"
  run_diag "$SB/root"
  assert_contains "$OUT" 'BAD_LIBDIR: ROOT/'"$TRG64"'/static/lib/pkgconfig/x.pc'
  assert_not_contains "$OUT" MISSING
}

t_diag_pc_without_libdir_is_not_checked_for_libdir() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  printf 'Name: x\nLibs:\n' > "$p/lib/pkgconfig/x.pc"
  run_diag "$SB/root"
  assert_not_contains "$OUT" BAD_LIBDIR
}

t_diag_is_read_only_and_leaves_no_files_or_dirs() {
  diag_sandbox
  local p; p="$(diag_prefix $TRG64 static)"
  : > "$p/lib/libfoo.a"
  mkpc "$p/lib/pkgconfig/foo.pc" "$p" 'Libs: -L${libdir} -lfoo -lgone'
  local before after
  before="$(cd "$SB" && find root -printf '%p %s %T@\n' | sort)"
  run_diag "$SB/root"
  after="$(cd "$SB" && find root -printf '%p %s %T@\n' | sort)"
  assert_eq "$before" "$after" 'fabricated tree untouched'
  assert_absent "$SB/pref" 'PREF not created'
  assert_eq '' "$(ls -A "$SB/tmp")" 'no temporary files'
}

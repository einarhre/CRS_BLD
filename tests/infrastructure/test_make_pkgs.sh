# Mock-based smoke tests for make_pkgs.sh.
#
# Every test runs the real driver against a throw-away PREF holding tiny
# synthetic package configurations, in the controlled environment of lib.sh:
# `env -i`, no Bash startup files, a pinned Linux uname and a PATH holding only
# allowlisted utilities and spies - there is no fallback to the host PATH.
# make, meson, ninja, cmake, the autotools "configure" script and the glib
# helpers are command spies; tar is a logging wrapper around the real tar
# (synthetic archives only).  Compilers, linkers, assemblers, downloaders, git,
# patch and package installers are either absent or "forbidden" spies whose
# use fails the test.
#
# Spy records are one line per call:  tool|cwd|CC|argc| arg1 arg2 ...
# with every field and argument encoded by printf %q, so argument boundaries
# and counts are exact and the log is line-safe for any path.
# The driver needs Bash >= 5.1 (wait -n -p); older shells skip these tests.

PKG_TRGS=("$TRG32" "$TRG64")
PKG_KINDS=(static shared)

pkgs_require_bash() {
  (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )) \
    || skip 'make_pkgs.sh needs Bash >= 5.1 (wait -n -p)'
}

# pkgs_sandbox: sandbox + PREF layout + spies.  Sets PREF_DIR, SPY_LOG, HOOK_LOG, SPY_BIN.
pkgs_sandbox() {
  pkgs_require_bash
  sandbox_new
  PREF_DIR="$SB/pref"
  SPY_LOG="$SB/spy.log"; HOOK_LOG="$SB/hook.log"; SPY_BIN="$SB/.ctl/spy"
  mkdir -p "$PREF_DIR/src/pkg/cfg" "$PREF_DIR/src/pkg/tar" "$PREF_DIR/src/pkg/ptc"
  : > "$SPY_LOG"; : > "$HOOK_LOG"
  cat > "$SPY_BIN" <<SPY
#!$BASH_BIN
# Generic command spy; one append per call; honors MOCK_FAIL_TOOL/MOCK_FAIL_CC.
n="\${0##*/}"
printf -v line '%q|%q|%q|%d|' "\$n" "\$PWD" "\${CC:-}" "\$#"
args=''; (( \$# == 0 )) || printf -v args ' %q' "\$@"
extra=''; [[ -z "\${MOCK_SHOW_VAR:-}" ]] || printf -v extra '|%s=%q' "\$MOCK_SHOW_VAR" "\${!MOCK_SHOW_VAR-}"
printf '%s%s%s\n' "\$line" "\$args" "\$extra" >> "\$SPY_LOG"
if [[ "\$n" == "\${MOCK_FAIL_TOOL:-}" && -n "\${MOCK_FAIL_CC:-}" && "\${CC:-}" == "\$MOCK_FAIL_CC" ]]; then
  exit 1
fi
exit 0
SPY
  chmod +x "$SPY_BIN"
  local real_tar t
  real_tar="$(command -v tar)" || skip 'tar is required'
  cat > "$SB/.ctl/tar" <<SPY
#!$BASH_BIN
printf -v line '%q|%q|%q|%d|' tar "\$PWD" "\${CC:-}" "\$#"
args=''; (( \$# == 0 )) || printf -v args ' %q' "\$@"
printf '%s%s\n' "\$line" "\$args" >> "\$SPY_LOG"
exec $(printf '%q' "$real_tar") "\$@"
SPY
  chmod +x "$SB/.ctl/tar"
  ctl_replace tar "$SB/.ctl/tar"
  for t in make meson ninja cmake glib-compile-resources glib-compile-schemas gdk-pixbuf-pixdata; do
    ctl_replace "$t" "$SPY_BIN"
  done
}

# mkcfg NAME [LINES...]: minimal configuration with logging hooks; extra lines
# are appended verbatim after the base definition (and may override it).
mkcfg() {
  local name="$1" h; shift
  {
    cat <<CFG
declare -rg CFG_PKG_NAME='$name'
declare -rg CFG_VERSION='1.0'
CFG_NO_ARCHIVE=1
declare -ga CFG_CPPFLAGS=()
declare -ga CFG_CFLAGS=('-O2')
declare -ga CFG_CXXFLAGS=()
declare -ga CFG_LDFLAGS=()
declare -ga CFG_LIBS=('-lz')
CFG
    for h in cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install; do
      printf '%s() { printf "%%s %%s %%s %%s %%s\\n" "$(date +%%s.%%N)" "%s" "$CFG" "$TRG" "$BKIND" >> "$HOOK_LOG"; }\n' "$h" "$h"
    done
    printf '%s\n' "$@"
  } > "$PREF_DIR/src/pkg/cfg/$name.sh"
}

CUSTOM_BUILD='CFG_BUILD_SYSTEM=custom
cfg_custom_build() { printf "%s %s %s %s %s\n" "$(date +%s.%N)" cfg_custom_build "$CFG" "$TRG" "$BKIND" >> "$HOOK_LOG"; }'

AUTOTOOLS_BASE=('CFG_BUILD_SYSTEM=autotools' 'CFG_CONFIGURE_SH=configure' 'CFG_AUTOTOOLS_BOOTSTRAP=()'
  'CFG_CONFIGURE_ENV=()' 'CFG_CONFIGURE_OPTS=()' 'CFG_MAKE_BUILD_OPTS=()' 'CFG_MAKE_INSTALL_OPTS=()')
# post-extract hook that installs the spy as the package's configure script
CONFIGURE_SPY_HOOK='cfg_post_extract() { cp "$SPY_BIN" "$PKG_SRC/configure"; }'

# pkgs_run [NAME=value...] -- cfg...   -> RC, OUT (sandbox path shown as SB)
pkgs_run() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  run_ctl -t "${PKGS_TIMEOUT:-60}" NCRS=4 "SPY_LOG=$SPY_LOG" "HOOK_LOG=$HOOK_LOG" "SPY_BIN=$SPY_BIN" \
    MOCK_FAIL_TOOL=make "${envs[@]}" -- "$BASH_BIN" --noprofile --norc "$PKGS_SH" "$@"
  OUT="$(norm_sb "$OUT")"
}

# spy_line TOOL CWD CC [ARGS...]: the exact record a spy writes (+ SPY_EXTRA)
spy_line() {
  local t="$1" d="$2" c="$3" line args=''; shift 3
  printf -v line '%q|%q|%q|%d|' "$t" "$d" "$c" "$#"
  (( $# == 0 )) || printf -v args ' %q' "$@"
  printf '%s%s%s' "$line" "$args" "${SPY_EXTRA:-}"
}
# expect_call TOOL CWD CC [ARGS...]: exactly one such record exists
expect_call() {
  local want n
  want="$(spy_line "$@")"
  n="$(grep -cFx -- "$want" "$SPY_LOG")"
  [[ "$n" -eq 1 ]] || fail "expected one call [$want], found $n in:"$'\n'"$(cat "$SPY_LOG")"
}
# count_calls TOOL [CWD]: number of records for a tool (optionally in CWD)
count_calls() {
  local pre
  if [[ $# -ge 2 ]]; then printf -v pre '%q|%q|' "$1" "$2"; else printf -v pre '%q|' "$1"; fi
  count_prefixed_lines "$(cat "$SPY_LOG")" "$pre"
}

# hooks_for TRG KIND [CFG]: ordered hook names logged for one worker
hooks_for() {
  awk -v t="$1" -v k="$2" -v c="${3:-}" '$4==t && $5==k && (c=="" || $3==c) {print $2}' "$HOOK_LOG" | paste -sd' '
}
# file_has_line FILE LINE (byte-safe, literal)
file_has_line() {
  local c; c=$'\n'"$(< "$1")"$'\n'
  [[ "$c" == *$'\n'"$2"$'\n'* ]]
}
pkg_bld() { printf '%s' "$PREF_DIR/build/pkg/$1/$2/build/$3"; }
pkg_src() { printf '%s' "$PREF_DIR/build/pkg/$1/$2/src/$3"; }
pkg_ins() { printf '%s' "$PREF_DIR/install/pkg/$1/$2"; }

# ------------------------------------------------------------------ usage

t_pkgs_no_arguments_prints_usage_and_exits_1() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"; mkcfg beta "$CUSTOM_BUILD"
  echo ignored > "$PREF_DIR/src/pkg/cfg/notes.txt"
  mkdir "$PREF_DIR/src/pkg/cfg/nested"; : > "$PREF_DIR/src/pkg/cfg/nested/inner.sh"
  pkgs_run --
  assert_rc 1 "$RC" 'usage exit status'
  assert_contains "$OUT" "usage: " 'usage line'
  assert_contains "$OUT" 'cfg1 [cfg2...]'
  assert_contains "$OUT" "configuration files must exist in: SB/pref/src/pkg/cfg"
  local avail; avail="$(sed -n 's/^ available gcc configurations: //p' <<< "$OUT" | tr ' ' '\n' | sort | paste -sd' ')"
  assert_eq 'alpha beta' "$avail" 'only top-level *.sh files are configurations'
  assert_eq '' "$(cat "$SPY_LOG")" 'nothing executed'
  assert_absent "$PREF_DIR/build" 'no build tree'
  assert_absent "$PREF_DIR/install" 'no install tree'
}

t_pkgs_unknown_name_is_rejected_before_any_build() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  pkgs_run -- alpha nosuch
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" 'Configuration not found: nosuch'
  assert_contains "$OUT" 'usage: '
  assert_eq '' "$(cat "$HOOK_LOG")" 'valid earlier name was not built either'
  assert_absent "$PREF_DIR/build"
}

t_pkgs_invalid_package_name_forms() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  local bad
  for bad in alph alpha.sh ALPHA '../cfg/alpha' 'alpha ' '' 'al*' '*'; do
    pkgs_run -- "$bad"
    assert_rc 1 "$RC" "[$bad] rejected"
    assert_contains "$OUT" "Configuration not found: $bad" "[$bad] message"
  done
  assert_eq '' "$(cat "$HOOK_LOG")" 'nothing ran'
}

t_pkgs_repeating_a_name_builds_it_twice() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  pkgs_run -- alpha alpha
  assert_rc 0 "$RC" 'status'
  assert_eq 8 "$(grep -c ' cfg_custom_build ' "$HOOK_LOG")" '4 workers x 2 passes'
}

# ---------------------------------------------------- configuration discovery

t_pkgs_configuration_is_loaded_by_each_worker_with_prefixed_output() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  pkgs_run -- alpha
  assert_rc 0 "$RC" 'status'
  local t k
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_contains "$OUT" "[alpha:$t:$k] Loading configuration: alpha" "$t/$k load"
    # the banner is printed before the worker installs its output prefix
    assert_contains "$OUT" "
Processing configuration alpha ($k build on $t)
" "$t/$k banner (unprefixed)"
  done; done
}

t_pkgs_config_without_flag_arrays_is_tolerated() {
  # Despite set -u, a configuration that defines none of the CFG_*FLAGS/LIBS
  # arrays still loads and (custom, no archive) completes.
  pkgs_sandbox
  printf '%s\n' "CFG_BUILD_SYSTEM=custom" "CFG_NO_ARCHIVE=1" > "$PREF_DIR/src/pkg/cfg/bare.sh"
  pkgs_run -- bare
  assert_rc 0 "$RC" "status ($OUT)"
  assert_contains "$OUT" '[bare:i686-w64-mingw32:static] Loading configuration: bare'
}

# ----------------------------------------------------- hooks and build kinds

t_pkgs_custom_build_hook_order() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  pkgs_run -- alpha
  assert_rc 0 "$RC" 'status'
  local t k
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_extract cfg_custom_build' "$(hooks_for "$t" "$k")" "$t/$k hooks"
  done; done
  assert_eq '' "$(cat "$SPY_LOG")" 'custom build runs no external build tool'
}

t_pkgs_autotools_exact_argv_hook_order_and_kinds() {
  pkgs_sandbox
  mkcfg alpha "${AUTOTOOLS_BASE[@]}" 'CFG_CONFIGURE_ENV=("FOO=bar baz")' \
    'CFG_CONFIGURE_OPTS=(--with-x "--opt=a b")' 'CFG_MAKE_BUILD_OPTS=(V=1)' 'CFG_MAKE_INSTALL_OPTS=(DESTDIR=/nowhere)' \
    "$CONFIGURE_SPY_HOOK"
  pkgs_run MOCK_SHOW_VAR=FOO -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k other ins bld src
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$t" "$k")" "$t/$k hook order"
    [[ $k == static ]] && other=shared || other=static
    ins="$(pkg_ins "$t" "$k")"; bld="$(pkg_bld "$t" "$k" alpha)"; src="$(pkg_src "$t" "$k" alpha)"
    # configure sees FOO from CFG_CONFIGURE_ENV; make does not
    SPY_EXTRA="|FOO=$(printf %q 'bar baz')" \
      expect_call configure "$bld" "$t-gcc" --host="$t" --prefix="$ins" --libdir="$ins/lib" \
        --disable-$other --enable-$k --with-x '--opt=a b'
    SPY_EXTRA="|FOO=''" expect_call make "$bld" "$t-gcc" -j 1 V=1
    SPY_EXTRA="|FOO=''" expect_call make "$bld" "$t-gcc" install DESTDIR=/nowhere
  done; done
  # The option containing a space stays ONE argument (argc 7, not 8).
  local rec; rec="$(grep -F "$(printf '%q|' configure)" "$SPY_LOG" | head -n 1)"
  [[ "$rec" == *"|7| "*" --opt=a\\ b|FOO="* ]] || fail "spaced option split or argc wrong: $rec"
  assert_eq 4 "$(count_calls configure)" 'one configure per worker'
}

t_pkgs_autotools_bootstrap_runs_once_per_source_tree() {
  pkgs_sandbox
  mkcfg alpha "${AUTOTOOLS_BASE[@]}" \
    'CFG_AUTOTOOLS_BOOTSTRAP=(sh -c "echo bootstrap >> \"\$HOOK_LOG\"; cp \"\$SPY_BIN\" configure")'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq 4 "$(grep -c '^bootstrap' "$HOOK_LOG")" 'one bootstrap per (target, kind) source tree'
}

t_pkgs_meson_exact_argv_and_hook_order() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=meson' 'CFG_MESON_OPTS=(-Dfoo=true "-Dname=a b")' 'CFG_MESON_ENV=("MENV=1")'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k b
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$t" "$k")" "$t/$k hooks"
    b="$(pkg_bld "$t" "$k" alpha)"
    expect_call meson "$b" "$t-gcc" setup "$b" "$(pkg_src "$t" "$k" alpha)" \
      --cross-file "$PREF_DIR/build/pkg/$t/meson-$t.ini" --wrap-mode=nofallback \
      --prefix "$(pkg_ins "$t" "$k")" --default-library "$k" --buildtype release -Dfoo=true '-Dname=a b'
    expect_call ninja "$b" "$t-gcc" -j 1 -C "$b"
    expect_call ninja "$b" "$t-gcc" -j 1 -C "$b" install
  done; done
}

t_pkgs_cmake_exact_argv_and_hook_order() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=cmake' 'CFG_CMAKE_SRC_DIR=sub' 'CFG_CMAKE_CONFIGURE_OPTS=(-DX=1 "-DY=a b")' \
    'CFG_CMAKE_BUILD_OPTS=(--verbose)' 'CFG_CMAKE_INSTALL_OPTS=(--strip)'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k onoff b ins
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$t" "$k")" "$t/$k hooks"
    [[ $k == static ]] && onoff=OFF || onoff=ON
    b="$(pkg_bld "$t" "$k" alpha)"; ins="$(pkg_ins "$t" "$k")"
    expect_call cmake "$b" "$t-gcc" -S "$(pkg_src "$t" "$k" alpha)/sub" -B "$b" \
      "-DCMAKE_TOOLCHAIN_FILE=$PREF_DIR/build/pkg/$t/toolchain-$t.cmake" "-DBUILD_SHARED_LIBS=$onoff" \
      "-DCMAKE_PREFIX_PATH=$ins" "-DCMAKE_FIND_ROOT_PATH=$ins" "-DCMAKE_INSTALL_PREFIX=$ins" \
      -DCMAKE_BUILD_TYPE=Release -DX=1 '-DY=a b'
    expect_call cmake "$b" "$t-gcc" --build "$b" --config Release --parallel 1 --verbose
    expect_call cmake "$b" "$t-gcc" --install "$b" --config Release --strip
  done; done
}

t_pkgs_build_system_can_differ_per_kind() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM_STATIC=custom' 'CFG_BUILD_SYSTEM_SHARED=meson' 'CFG_BUILD_SYSTEM=cmake' \
    'CFG_MESON_OPTS=()' 'CFG_MESON_ENV=()' \
    'cfg_custom_build() { printf "%s %s %s %s %s\n" 0 cfg_custom_build "$CFG" "$TRG" "$BKIND" >> "$HOOK_LOG"; }'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq 2 "$(grep -c ' cfg_custom_build ' "$HOOK_LOG")" 'static kind (one per target) uses the custom system'
  assert_eq 2 "$(count_calls meson)" 'shared kinds (one per target) use meson setup'
  assert_eq 0 "$(count_calls meson "$(pkg_bld "$TRG64" static alpha)")" 'no meson for static'
  assert_eq 0 "$(count_calls cmake)" 'generic CFG_BUILD_SYSTEM is overridden by per-kind values'
}

t_pkgs_unknown_build_system_fails_every_worker() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=bogus'
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" 'Consider supplying a config file in ./src/pkg/cfg/'
  assert_contains "$OUT" '4 packages failed to compile:'
}

# ----------------------------------------------------- targets and environment

t_pkgs_every_target_and_kind_is_built_once_with_target_cc() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=meson' 'CFG_MESON_OPTS=()' 'CFG_MESON_ENV=()'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k pre
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    printf -v pre '%q|%q|%q|' meson "$(pkg_bld "$t" "$k" alpha)" "$t-gcc"
    assert_eq 1 "$(count_prefixed_lines "$(grep -F ' setup ' "$SPY_LOG")" "$pre")" "$t/$k once, CC=$t-gcc"
    assert_exists "$(pkg_ins "$t" "$k")" 'install prefix created'
  done; done
  assert_eq 4 "$(grep -c ' setup ' "$SPY_LOG")" 'four setups in total'
}

t_pkgs_environment_exported_to_hooks_for_every_worker() {
  pkgs_sandbox
  mkdir "$SB/env"
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'CFG_CFLAGS=(-O2 -g)' 'CFG_LDFLAGS=(-Wl,-x)' \
    'cfg_custom_build() { { echo "$BKIND $TRG"; echo "PATH=$PATH"; echo "CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB STRIP=$STRIP WINDRES=$WINDRES"; echo "CPPFLAGS=[$CPPFLAGS]"; echo "CFLAGS=$CFLAGS"; echo "LDFLAGS=$LDFLAGS"; echo "LIBS=$LIBS"; echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"; echo "PKG_CONFIG_PATH=[$PKG_CONFIG_PATH]"; echo "PWD=$PWD"; } > "$ENV_DIR/$TRG-$BKIND"; }'
  pkgs_run "ENV_DIR=$SB/env" -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k i
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    i="$(pkg_ins "$t" "$k")"
    assert_eq "$k $t
PATH=$PREF_DIR/install/cross/$t/bin:$CTL_BIN
CC=$t-gcc CXX=$t-g++ AR=$t-ar RANLIB=$t-ranlib STRIP=$t-strip WINDRES=$t-windres
CPPFLAGS=[-I$i/include ]
CFLAGS=-I$i/include -O2 -g
LDFLAGS=-L$i/lib -L$i/lib64 -Wl,-x
LIBS=-lz
PKG_CONFIG_LIBDIR=$i/lib/pkgconfig:$i/lib64/pkgconfig:$i/share/pkgconfig
PKG_CONFIG_PATH=[]
PWD=$(pkg_bld "$t" "$k" alpha)" "$(cat "$SB/env/$t-$k")" "$t/$k worker environment"
  done; done
}

t_pkgs_meson_and_cmake_files_have_target_specific_content() {
  pkgs_sandbox
  mkdir "$SB/keep"
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' \
    'cfg_custom_build() { cp "$MESON_CROSS_FILE" "$KEEP/meson-$TRG-$BKIND"; cp "$CMAKE_TOOLCHAIN_FILE" "$KEEP/cmake-$TRG-$BKIND"; }'
  pkgs_run "KEEP=$SB/keep" -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local m="$SB/keep/meson-$TRG32-static" c="$SB/keep/cmake-$TRG64-shared"
  file_has_line "$m" "c = '$TRG32-gcc'" || fail 'meson c'
  file_has_line "$m" "cpu_family = 'x86'" || fail 'i686 cpu_family'
  file_has_line "$m" "cpu = 'i686'" || fail 'i686 cpu'
  file_has_line "$m" "pkg-config = '$CTL_BIN/pkg-config'" || fail 'meson pkg-config'
  file_has_line "$m" "glib-compile-resources = '$CTL_BIN/glib-compile-resources'" || fail 'native glib tool recorded'
  file_has_line "$SB/keep/meson-$TRG64-static" "cpu_family = 'x86_64'" || fail 'x86_64 family'
  file_has_line "$c" "set(CMAKE_SYSTEM_PROCESSOR x86_64)" || fail 'cmake processor'
  file_has_line "$c" "set(CMAKE_C_COMPILER   \"$PREF_DIR/install/cross/$TRG64/bin/$TRG64-gcc\")" || fail 'cmake compiler'
  file_has_line "$SB/keep/cmake-$TRG32-static" "set(CMAKE_SYSTEM_PROCESSOR x86)" || fail 'i686 cmake processor'
}

t_pkgs_missing_native_glib_tools_fail_every_worker() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  rm "$CTL_BIN/glib-compile-resources" "$CTL_BIN/glib-compile-schemas" "$CTL_BIN/gdk-pixbuf-pixdata"
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" 'Native GLib build tools were not found in PATH'
  assert_contains "$OUT" '4 packages failed to compile'
  assert_eq '' "$(cat "$HOOK_LOG")" 'no hook ran'
}

# ------------------------------------------------- isolation (H3) and platform

t_pkgs_unmocked_build_tools_cannot_reach_the_host() {
  # Recording impostors placed FIRST on the test process's PATH must never be
  # reached by the driver: the controlled PATH has no host fallback.  Known
  # names hit forbidden spies (exit 99); unknown names are not found (127).
  pkgs_sandbox
  mkdir "$SB/hostbin"
  local t
  for t in clang clang++ as ld cc gcc nasm curl wget git brew "$TRG64-as" "$TRG64-objdump" llvm-mc tcc; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/host-escape.log"\n' "$t" "$SB" | write_exe "$SB/hostbin/$t"
  done
  export PATH="$SB/hostbin:$PATH"
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' \
    'cfg_custom_build() { local t; for t in clang clang++ as ld cc gcc nasm curl wget git brew x86_64-w64-mingw32-as x86_64-w64-mingw32-objdump llvm-mc tcc; do "$t" --version >/dev/null 2>&1 || printf "%s %s=%s\n" "$TRG/$BKIND" "$t" "$?" >> "$HOOK_LOG"; done; }'
  ALLOW_FORBIDDEN=1 pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_absent "$SB/host-escape.log" 'no host impostor was executed'
  local w="$TRG64/shared"
  for t in clang clang++ as ld cc gcc nasm curl wget git brew x86_64-w64-mingw32-as x86_64-w64-mingw32-objdump; do
    grep -qxF "$w $t=99" "$HOOK_LOG" || fail "$t did not resolve to the forbidden spy: $(cat "$HOOK_LOG")"
  done
  for t in llvm-mc tcc; do
    grep -qxF "$w $t=127" "$HOOK_LOG" || fail "$t should be absent (127): $(cat "$HOOK_LOG")"
  done
  grep -q '^FORBIDDEN|clang|' "$FORBIDDEN_LOG" || fail 'clang attempt recorded'
  grep -q '^FORBIDDEN|as|' "$FORBIDDEN_LOG" || fail 'assembler attempt recorded'
}

t_pkgs_forbidden_tool_use_fails_the_test_helper() {
  # Without ALLOW_FORBIDDEN, run_ctl turns a forbidden invocation into a test
  # failure even when the driver itself succeeds.
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'cfg_custom_build() { clang -c x.c || true; }'
  ( pkgs_run -- alpha ) > "$SB/inner.out" 2>&1 && fail 'helper accepted a forbidden call'
  assert_contains "$(cat "$SB/inner.out")" 'FAIL: forbidden tool invoked: FORBIDDEN|clang|argc=2| -c x.c'
}

t_pkgs_caller_environment_and_startup_files_are_not_inherited() {
  pkgs_sandbox
  printf 'echo bash_env >> "%s/leak.log"\n' "$SB" > "$SB/bash_env.sh"
  printf 'echo bashrc >> "%s/leak.log"\n' "$SB" > "$SB/home/.bashrc"
  cp "$SB/home/.bashrc" "$SB/home/.bash_profile"
  export BASH_ENV="$SB/bash_env.sh" ENV="$SB/bash_env.sh" MOCK_LEAK=1 CC=host-cc PKG_CONFIG_PATH=/host/pc
  command_not_found_handle() { echo handler >> "$SB/leak.log"; return 127; }
  export -f command_not_found_handle
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' \
    'cfg_custom_build() { env | sort > "$SB/env.$TRG.$BKIND"; tcc 2>/dev/null || true; }'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_absent "$SB/leak.log" 'no BASH_ENV/ENV/rc file or imported function ran'
  local e; e="$(cat "$SB/env.$TRG64.static")"
  assert_not_contains "$e" MOCK_LEAK 'arbitrary caller variable'
  assert_not_contains "$e" BASH_FUNC 'exported function'
  assert_not_contains "$e" BASH_ENV
  assert_not_contains "$e" 'PKG_CONFIG_PATH=/host/pc' 'caller pkg-config path'
  assert_contains "$e" "HOME=$SB/home" 'HOME inside the sandbox'
  assert_contains "$e" "CC=$TRG64-gcc" 'driver sets its own CC'
}

t_pkgs_linux_initialization_never_consults_brew() {
  # Pinned platform: brew stays a forbidden spy and PATH gains only the
  # cross-toolchain directory.
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'cfg_custom_build() { printf "%s\n" "$PATH" > "$SB/path.$TRG.$BKIND"; }'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq "$PREF_DIR/install/cross/$TRG32/bin:$CTL_BIN" "$(cat "$SB/path.$TRG32.shared")" 'PATH on Linux'
  assert_eq '' "$(cat "$FORBIDDEN_LOG")" 'brew not called'
}

t_pkgs_simulated_darwin_initialization_uses_mock_brew_prefix() {
  # Simulated macOS (Linux host): uname reports Darwin and brew is a mock that
  # only answers --prefix.  No real Homebrew is involved; this is not native
  # macOS evidence.
  pkgs_sandbox
  printf '#!/bin/sh\necho "$*" >> "%s/brew.log"\n[ "$1" = --prefix ] && [ $# -eq 1 ] && echo "%s/hb"\nexit 0\n' "$SB" "$SB" \
    | write_exe "$SB/.ctl/brew-mock"
  ctl_replace brew "$SB/.ctl/brew-mock"
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'cfg_custom_build() { printf "%s\n" "$PATH" > "$SB/path.$TRG.$BKIND"; }'
  pkgs_run MOCK_UNAME=Darwin -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local b="$SB/hb" expect='' d
  for d in opt/flex/bin opt/bison/bin opt/texinfo/bin opt/zip/bin opt/gpatch/libexec/gnubin \
           opt/libtool/libexec/gnubin opt/gnu-tar/libexec/gnubin opt/make/libexec/gnubin \
           opt/grep/libexec/gnubin opt/gnu-sed/libexec/gnubin opt/findutils/libexec/gnubin \
           opt/coreutils/libexec/gnubin bin sbin; do
    expect+="$b/$d:"
  done
  assert_eq "$PREF_DIR/install/cross/$TRG64/bin:$expect$CTL_BIN" "$(cat "$SB/path.$TRG64.static")" 'PATH on simulated Darwin'
  assert_eq '--prefix' "$(cat "$SB/brew.log")" 'brew queried exactly once, for its prefix'
}

# -------------------------------------------------------- archives and jobs

t_pkgs_archive_extracted_once_per_worker_before_post_extract() {
  pkgs_sandbox
  mkdir -p "$SB/srcsrc/alpha-1.0"; echo hello > "$SB/srcsrc/alpha-1.0/file.txt"
  tar -C "$SB/srcsrc" -czf "$PREF_DIR/src/pkg/tar/alpha-1.0.tar.gz" alpha-1.0
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' \
    'cfg_post_extract() { printf "%s\n" "$(cat "$PKG_SRC/file.txt")-$TRG-$BKIND" >> "$HOOK_LOG"; }'
  sed -i '/CFG_NO_ARCHIVE/d' "$PREF_DIR/src/pkg/cfg/alpha.sh"
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq 4 "$(grep -c '^hello-' "$HOOK_LOG")" 'extracted content visible to the hook in each source tree'
  assert_eq 4 "$(count_calls tar)" 'exactly one extraction per worker'
  local t k
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    # extraction happens before the worker changes into its build directory
    expect_call tar "$SB" "$t-gcc" --strip-components=1 \
      "--directory=$(pkg_src "$t" "$k" alpha)" -xaf "$PREF_DIR/src/pkg/tar/alpha-1.0.tar.gz"
  done; done
  assert_absent "$(pkg_src "$TRG64" static alpha)" 'source tree removed afterwards'
}

t_pkgs_tarball_count_must_be_exactly_one() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom'
  sed -i '/CFG_NO_ARCHIVE/d' "$PREF_DIR/src/pkg/cfg/alpha.sh"
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'zero tarballs'
  assert_contains "$OUT" 'Expected exactly one tarball for configuration alpha, found 0'
  mkdir -p "$SB/x"; : > "$SB/x/f"
  tar -C "$SB/x" -czf "$PREF_DIR/src/pkg/tar/alpha-1.0.tar.gz" f
  tar -C "$SB/x" -czf "$PREF_DIR/src/pkg/tar/alpha-1.0-b.tar.gz" f
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'two tarballs'
  assert_contains "$OUT" 'found 2'
  assert_eq 0 "$(count_calls tar)" 'nothing extracted when the count is wrong'
}

t_pkgs_job_counts_follow_ncrs() {
  pkgs_sandbox
  mkcfg alpha "${AUTOTOOLS_BASE[@]}" "$CONFIGURE_SPY_HOOK"
  local n want t k
  for n in "1:1" "3:1" "4:1" "8:2" "16:4"; do
    : > "$SPY_LOG"
    pkgs_run NCRS="${n%%:*}" -- alpha
    assert_rc 0 "$RC" "NCRS=${n%%:*} status ($OUT)"
    want="${n##*:}"
    for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
      expect_call make "$(pkg_bld "$t" "$k" alpha)" "$t-gcc" -j "$want"
    done; done
  done
}

t_pkgs_canonical_ncrs_boundary_jobs() {
  pkgs_sandbox
  mkcfg alpha "${AUTOTOOLS_BASE[@]}" "$CONFIGURE_SPY_HOOK"
  local pair t k
  for pair in 007:1 08:2 010:2 4096:1024 0004096:1024; do
    : > "$SPY_LOG"
    pkgs_run "NCRS=${pair%:*}" -- alpha
    assert_rc 0 "$RC" "status ($OUT)"
    for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
      expect_call make "$(pkg_bld "$t" "$k" alpha)" "$t-gcc" -j "${pair#*:}"
    done; done
  done
}

# ---------------------------------------------------------------- cleanup

t_pkgs_success_cleans_temp_files_work_dirs_and_generated_configs() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=meson' 'CFG_MESON_OPTS=()' 'CFG_MESON_ENV=()'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq '' "$(ls -A "$SB/tmp")" 'no temporary trash-bin files left in TMPDIR'
  local t k
  for t in "${PKG_TRGS[@]}"; do
    for k in "${PKG_KINDS[@]}"; do
      assert_absent "$(pkg_src "$t" "$k" alpha)" "$t/$k source dir"
      assert_absent "$(pkg_bld "$t" "$k" alpha)" "$t/$k build dir"
    done
    assert_absent "$PREF_DIR/build/pkg/$t/meson-$t.ini" 'meson ini deleted at exit'
    assert_absent "$PREF_DIR/build/pkg/$t/toolchain-$t.cmake" 'cmake toolchain deleted at exit'
    assert_absent "$PREF_DIR/build/pkg/$t.meson.lock"; assert_absent "$PREF_DIR/build/pkg/$t.cmake.lock"
  done
  assert_contains "$OUT" 'deleted the following directories/files:' 'cleanup report'
}

t_pkgs_second_configuration_runs_after_first_completes() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"; mkcfg beta "$CUSTOM_BUILD"
  pkgs_run -- beta alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local first_alpha last_beta
  first_alpha="$(awk '$3=="alpha"{print $1}' "$HOOK_LOG" | sort -n | head -1)"
  last_beta="$(awk '$3=="beta"{print $1}' "$HOOK_LOG" | sort -n | tail -1)"
  awk -v a="$first_alpha" -v b="$last_beta" 'BEGIN{exit !(b < a)}' || fail 'argument order not respected'
}

# ------------------------------------------------------------------ locks

t_pkgs_generated_file_lock_blocks_until_released() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  mkdir -p "$PREF_DIR/build/pkg/$TRG64.meson.lock"
  spawn_ctl "$SB/.run/releaser" -t 20 -- "$BASH_BIN" --noprofile --norc -c \
    'sleep 3; date +%s.%N > "$1"; rmdir "$2"' _ "$SB/released" "$PREF_DIR/build/pkg/$TRG64.meson.lock"
  local rel="$SPAWN_PID"
  pkgs_run -- alpha
  local run_rc="$RC" run_out="$OUT"
  reap_ctl "$rel"
  RC="$run_rc"; OUT="$run_out"
  assert_rc 0 "$RC" "status ($OUT)"
  local released; released="$(cat "$SB/released")"
  # hooks of the blocked target start only after the lock was released
  awk -v r="$released" -v t="$TRG64" '$4==t && $1 < r {bad=1} END{exit bad}' "$HOOK_LOG" || fail "$TRG64 worker ran while its lock was held"
  assert_eq 4 "$(grep -c ' cfg_custom_build ' "$HOOK_LOG")" 'all workers eventually ran'
  assert_absent "$PREF_DIR/build/pkg/$TRG64.meson.lock" 'released'
}

t_pkgs_stuck_lock_makes_the_run_hang_until_killed() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  mkdir -p "$PREF_DIR/build/pkg/$TRG32.cmake.lock"
  PKGS_TIMEOUT=4 pkgs_run -- alpha
  assert_eq 124 "$RC" 'timeout kills the waiting run (no stale-lock detection)'
  assert_eq 0 "$(grep -c "$TRG32" "$HOOK_LOG")" 'blocked target never started'
  assert_exists "$PREF_DIR/build/pkg/$TRG32.cmake.lock" 'foreign lock left untouched'
}

# ------------------------------------------------------ worker failures

t_pkgs_worker_failure_is_reported_and_exit_is_nonzero() {
  pkgs_sandbox
  mkcfg alpha "${AUTOTOOLS_BASE[@]}" "$CONFIGURE_SPY_HOOK"
  mkcfg beta "$CUSTOM_BUILD"
  pkgs_run "MOCK_FAIL_CC=$TRG64-gcc" -- alpha beta
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" 'compiling failed: failed building for alpha'
  local failed; failed="$(sed -n 's/^.*packages failed to compile: //p' <<< "$OUT" | tr ' ' '\n' | sort | paste -sd' ')"
  assert_eq "alpha:$TRG64:shared alpha:$TRG64:static" "$failed" 'exactly the failing workers are named'
  assert_contains "$OUT" '2 packages failed to compile:'
  assert_eq 'cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$TRG32" static alpha)" 'sibling workers complete'
  assert_eq 'cfg_post_configure' "$(hooks_for "$TRG64" static alpha)" 'failing worker stops after configure'
  assert_eq 0 "$(grep -c ' beta ' "$HOOK_LOG")" 'later configurations are not started'
  assert_eq '' "$(ls -A "$PREF_DIR/build/pkg/$TRG64/static/src" 2>/dev/null)" 'failed worker still removes its source dir via its own trash bin'
}

t_pkgs_failing_hook_marks_worker_failed() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'cfg_custom_build() { [ "$TRG" = "x86_64-w64-mingw32" ] && [ "$BKIND" = shared ] && return 1; return 0; }'
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" '1 packages failed to compile: alpha:x86_64-w64-mingw32:shared'
}

t_pkgs_all_workers_failing_are_all_listed() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'cfg_custom_build() { return 3; }'
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" '4 packages failed to compile:'
  local t k
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do assert_contains "$OUT" "alpha:$t:$k"; done; done
}

k_pkgs_failed_configuration_leaks_per_config_temp_file() {
  # KNOWN DEFECT (audit B6): on `exit 1` after worker failures the per-
  # configuration trash-bin file (mktemp) is never emptied or removed.
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'cfg_custom_build() { return 1; }'
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'status'
  local n; n="$(find "$SB/tmp" -type f -printf . | wc -c)"
  assert_eq 1 "$n" 'exactly one leaked temp file in TMPDIR'
  echo "leaked: $(norm_sb "$(find "$SB/tmp" -type f)")"
}

t_pkgs_run_leaves_checkout_listing_and_tracked_files_unchanged() {
  # Shallow evidence only: the checkout's top level, build/, install/ and
  # src/cpl listings, plus (when available) git's view of tracked files.
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=cmake' 'CFG_CMAKE_SRC_DIR=.' 'CFG_CMAKE_CONFIGURE_OPTS=()' 'CFG_CMAKE_BUILD_OPTS=()' 'CFG_CMAKE_INSTALL_OPTS=()'
  _checkout_state() {
    ( cd "$CRS_ROOT" && ls -A && ls -A build install src/cpl 2>/dev/null
      if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
        git status --porcelain --untracked-files=no 2>/dev/null
      fi )
  }
  local before; before="$(_checkout_state)"
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq "$before" "$(_checkout_state)" 'checkout listings and tracked-file status unchanged'
}

t_pkgs_nproc_defaults_and_failures_before_workers() {
  pkgs_sandbox
  mkcfg alpha "${AUTOTOOLS_BASE[@]}" "$CONFIGURE_SPY_HOOK"
  printf '#!/bin/sh\nprintf "%%s" "$MOCK_NPROC"\nexit "$MOCK_NPROC_RC"\n' | write_exe "$SB/nproc"
  ctl_replace nproc "$SB/nproc"
  local value pair t k
  for value in '' abc 0; do
    pkgs_run -NCRS "MOCK_NPROC=$value" MOCK_NPROC_RC=0 -- alpha
    assert_rc 1 "$RC" 'invalid default'
    assert_contains "$OUT" 'nproc --all'
    assert_eq '' "$(cat "$HOOK_LOG")" 'no hooks'
    assert_eq '' "$(ls -A "$SB/tmp")" 'no allocation'
    assert_absent "$PREF_DIR/build" 'no build mutation'
  done
  pkgs_run -NCRS MOCK_NPROC=7 MOCK_NPROC_RC=3 -- alpha
  assert_rc 1 "$RC" 'failed nproc cannot supply a value'
  for pair in 7:1 5000:1024; do
    : > "$SPY_LOG"
    pkgs_run -NCRS "MOCK_NPROC=${pair%:*}" MOCK_NPROC_RC=0 -- alpha
    assert_rc 0 "$RC" 'valid default'
    for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
      expect_call make "$(pkg_bld "$t" "$k" alpha)" "$t-gcc" -j "${pair#*:}"
    done; done
  done
}

# Exercise the real ICU custom-build function with synthetic configure/make only.
# Other recipe hooks are not executed; compilers remain forbidden spies.
icu_lock_fixture() {
  pkgs_sandbox
  mkdir -p "$SB/icu-source/icu4c/source" "$SB/icu-target"
  cat > "$SB/icu-source/icu4c/source/configure" <<'SH'
#!/bin/bash
if [[ "$*" == *--host=* ]]; then
  echo "target-configure $PWD" >> "$ICU_LOG"
else
  echo host-configure >> "$ICU_LOG"
  if [[ "$ICU_FAIL" == configure ]] && mkdir "$SB/failed-once" 2>/dev/null; then exit 7; fi
fi
SH
  chmod +x "$SB/icu-source/icu4c/source/configure"
  cat > "$SB/icu-make" <<'SH'
#!/bin/bash
if [[ "$PWD" == "$SB/pkg/host-tools/build/icu" ]]; then
  echo host-make >> "$ICU_LOG"
  if [[ "$ICU_FAIL" == make ]] && mkdir "$SB/failed-once" 2>/dev/null; then exit 7; fi
else
  echo "target-make $PWD" >> "$ICU_LOG"
fi
SH
  chmod +x "$SB/icu-make"
  ctl_replace make "$SB/icu-make"
  : > "$SB/icu.log"
}

ICU_LOCK_SETUP='
source "$ICU_CFG"
PKG_BLD_DIR="$SB/pkg"
PKG_SRC="$SB/icu-source"
PKG_BLD="$SB/icu-target"
PKG_INS="$SB/icu-install"
CFG=icu
TRG=x86_64-w64-mingw32
BKIND=shared
NJOBS=1
BUILD_KINDS=(static shared)
declare -A BUILD_KINDS_REV=([static]=shared [shared]=static)
DELETE_PKG_BLD=0
run_hook() { :; }
cd "$PKG_BLD"
'

t_pkgs_icu_failed_host_step_never_publishes_marker_or_starts_target() {
  icu_lock_fixture
  local phase
  for phase in configure make; do
    rm -f "$SB/failed-once" 2>/dev/null || rmdir "$SB/failed-once"
    : > "$SB/icu.log"
    run_pkgs_support "ICU_CFG=$CRS_ROOT/src/pkg/cfg/icu.sh" "ICU_LOG=$SB/icu.log" "ICU_FAIL=$phase" -- "$ICU_LOCK_SETUP"'
      cfg_custom_build || exit 9'
    assert_rc 9 "$RC" 'conditional caller still propagates host failure'
    assert_absent "$SB/pkg/host-tools/build/icu/.built"
    assert_absent "$SB/pkg/host-tools/build/icu.lock"
    assert_not_contains "$(cat "$SB/icu.log")" target- 'no target work after host failure'
  done
}

t_pkgs_icu_four_way_contention_builds_host_once_and_retries_failed_owner() {
  icu_lock_fixture
  local phase log
  for phase in none configure make; do
    rm -f "$SB/pkg/host-tools/build/icu/.built"
    if [[ -d "$SB/failed-once" ]]; then rmdir "$SB/failed-once"; fi
    : > "$SB/icu.log"
    run_pkgs_support -t 25 "ICU_CFG=$CRS_ROOT/src/pkg/cfg/icu.sh" "ICU_LOG=$SB/icu.log" "ICU_FAIL=$phase" -- "$ICU_LOCK_SETUP"'
      pids=(); failures=0
      for i in 1 2 3 4; do ( cfg_custom_build ) & pids+=("$!"); done
      for pid in "${pids[@]}"; do wait "$pid" || failures=$((failures+1)); done
      echo "failures=$failures"'
    assert_rc 0 "$RC" "workers reaped ($OUT)"
    log="$(cat "$SB/icu.log")"
    if [[ "$phase" == none ]]; then
      assert_contains "$OUT" failures=0
      assert_eq 1 "$(grep -c '^host-configure$' "$SB/icu.log")" 'one configure under contention'
      assert_eq 4 "$(grep -c '^target-configure ' "$SB/icu.log")" 'all four targets proceed'
    else
      assert_contains "$OUT" failures=1 'one failed owner, successful waiters'
      assert_eq 2 "$(grep -c '^host-configure$' "$SB/icu.log")" 'one retry after failed owner'
      assert_eq 3 "$(grep -c '^target-configure ' "$SB/icu.log")" 'failed owner never builds target'
    fi
    assert_exists "$SB/pkg/host-tools/build/icu/.built" 'successful waiter publishes marker'
    assert_absent "$SB/pkg/host-tools/build/icu.lock" 'host lock released'
  done
}

t_pkgs_generator_write_failure_removes_partial_and_releases_lock() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  # Read the heredoc using the real cat; fail the selected generator after
  # publishing partial bytes. This exercises both native-file callbacks.
  local real_cat phase t
  real_cat="$(command -v cat)"
  printf '#!%s\nif [[ $# -eq 0 ]]; then\n  data="$(%q)"\n  if [[ "$FAIL_GENERATOR" == meson && "$data" == *"[binaries]"* || "$FAIL_GENERATOR" == cmake && "$data" == *CMAKE_SYSTEM_NAME* ]]; then echo partial; exit 7; fi\n  printf "%%s\\n" "$data"; exit 0\nfi\nexec %q "$@"\n' "$BASH_BIN" "$real_cat" "$real_cat" | write_exe "$SB/failing-cat"
  ctl_replace cat "$SB/failing-cat"
  for phase in meson cmake; do
    pkgs_run "FAIL_GENERATOR=$phase" -- alpha
    assert_rc 1 "$RC" 'failed generation aborts workers'
    assert_eq '' "$(cat "$HOOK_LOG")" 'no package work'
    for t in "${PKG_TRGS[@]}"; do
      assert_absent "$PREF_DIR/build/pkg/$t/meson-$t.ini"
      assert_absent "$PREF_DIR/build/pkg/$t/toolchain-$t.cmake"
      assert_absent "$PREF_DIR/build/pkg/$t.meson.lock"
      assert_absent "$PREF_DIR/build/pkg/$t.cmake.lock"
    done
  done
}

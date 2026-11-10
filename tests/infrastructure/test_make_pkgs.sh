# Mock-based smoke tests for make_pkgs.sh.
#
# Every test runs the real driver against a throw-away PREF holding tiny
# synthetic package configurations.  All build tools (make, meson, ninja, cmake,
# the autotools "configure" script, glib helpers) are command spies that only
# append to a log.  Compilers, linkers, downloaders, git and package installers
# are "forbidden" spies: any call is logged as FORBIDDEN and fails the test.
# The driver needs Bash >= 5.1 (wait -n -p); older shells skip these tests.

PKG_TRGS=("$TRG32" "$TRG64")
PKG_KINDS=(static shared)

pkgs_require_bash() {
  (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )) \
    || skip 'make_pkgs.sh needs Bash >= 5.1 (wait -n -p)'
}

# pkgs_sandbox: sandbox + PREF layout + spy bin dir.  Sets PREF_DIR, SPY_LOG, HOOK_LOG.
pkgs_sandbox() {
  pkgs_require_bash
  sandbox_new
  PREF_DIR="$SB/pref"
  SPY_LOG="$SB/spy.log"; HOOK_LOG="$SB/hook.log"
  mkdir -p "$PREF_DIR/src/pkg/cfg" "$PREF_DIR/src/pkg/tar" "$PREF_DIR/src/pkg/ptc" "$SB/bin"
  : > "$SPY_LOG"; : > "$HOOK_LOG"
  local t
  cat > "$SB/spy" <<'SPY'
#!/bin/sh
# Generic command spy: log "tool|cwd|CC|args" with one append, honor MOCK_FAIL_*.
n=$(basename "$0")
printf '%s|%s|%s|%s\n' "$n" "$PWD" "${CC:-}" "$*" >> "$SPY_LOG"
if [ "$n" = "$MOCK_FAIL_TOOL" ] && [ -n "${MOCK_FAIL_CC:-}" ] && [ "${CC:-}" = "$MOCK_FAIL_CC" ]; then
  exit 1
fi
exit 0
SPY
  cat > "$SB/forbidden" <<'SPY'
#!/bin/sh
printf 'FORBIDDEN|%s|%s\n' "$(basename "$0")" "$*" >> "$SPY_LOG"
exit 99
SPY
  chmod +x "$SB/spy" "$SB/forbidden"
  for t in make meson ninja cmake glib-compile-resources glib-compile-schemas gdk-pixbuf-pixdata; do
    ln -s ../spy "$SB/bin/$t"
  done
  for t in gcc g++ cc c++ ld curl wget git apt-get apt dnf brew pip pip3 npm cargo go \
           "$TRG32-gcc" "$TRG64-gcc" "$TRG32-g++" "$TRG64-g++" patch; do
    ln -s ../forbidden "$SB/bin/$t"
  done
  # `patch` is only forbidden because no test here supplies a patch file.
}

# mkcfg NAME [BUILD_SYSTEM-lines...]: write a minimal configuration with logging hooks.
#   Extra lines (arguments) are appended verbatim after the base definition.
mkcfg() {
  local name="$1"; shift
  {
    cat <<CFG
declare -rg CFG_PKG_NAME='$name'
declare -rg CFG_VERSION='1.0'
declare -rg CFG_NO_ARCHIVE=1
declare -ga CFG_CPPFLAGS=()
declare -ga CFG_CFLAGS=('-O2')
declare -ga CFG_CXXFLAGS=()
declare -ga CFG_LDFLAGS=()
declare -ga CFG_LIBS=('-lz')
CFG
    local h
    for h in cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install; do
      printf '%s() { printf "%%s %%s %%s %%s %%s\\n" "$(date +%%s.%%N)" "%s" "$CFG" "$TRG" "$BKIND" >> "$HOOK_LOG"; }\n' "$h" "$h"
    done
    printf '%s\n' "$@"
  } > "$PREF_DIR/src/pkg/cfg/$name.sh"
}

CUSTOM_BUILD='CFG_BUILD_SYSTEM=custom
cfg_custom_build() { printf "%s %s %s %s %s\n" "$(date +%s.%N)" cfg_custom_build "$CFG" "$TRG" "$BKIND" >> "$HOOK_LOG"; }'

# pkgs_run [NAME=value...] -- cfg...   -> RC, OUT (sandbox path shown as SB)
pkgs_run() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  RC=0
  OUT="$(cd "$SB" && env "PREF=$PREF_DIR" "PATH=$SB/bin:$PATH" "TMPDIR=$SB/tmp" "SPY_LOG=$SPY_LOG" \
      "HOOK_LOG=$HOOK_LOG" NCRS=4 MOCK_FAIL_TOOL=make "${envs[@]}" \
      timeout -k 3 "${PKGS_TIMEOUT:-60}" bash "$PKGS_SH" "$@" 2>&1)" || RC=$?
  OUT="${OUT//$SB/SB}"
  ! grep -q '^FORBIDDEN' "$SPY_LOG" || fail "forbidden tool invoked: $(grep '^FORBIDDEN' "$SPY_LOG")"
}

# hooks_for TRG KIND [CFG]: ordered hook names logged for one worker
hooks_for() {
  awk -v t="$1" -v k="$2" -v c="${3:-}" '$4==t && $5==k && (c=="" || $3==c) {print $2}' "$HOOK_LOG" | paste -sd' '
}
spy_lines() { grep -E "^$1\|" "$SPY_LOG" || true; }

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

t_pkgs_autotools_hook_order_arguments_and_kinds() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=autotools' 'CFG_CONFIGURE_SH=configure' \
    'CFG_AUTOTOOLS_BOOTSTRAP=()' 'CFG_CONFIGURE_ENV=("FOO=bar")' \
    'CFG_CONFIGURE_OPTS=(--with-x "--opt=a b")' 'CFG_MAKE_BUILD_OPTS=(V=1)' 'CFG_MAKE_INSTALL_OPTS=(DESTDIR=/nowhere)' \
    'cfg_post_extract() { printf "%s %s %s %s %s\n" 0 cfg_post_extract "$CFG" "$TRG" "$BKIND" >> "$HOOK_LOG"; printf "#!/bin/sh\necho \"configure|\$PWD|\$FOO|\$*\" >> \"\$SPY_LOG\"\n" > "$PKG_SRC/configure"; chmod +x "$PKG_SRC/configure"; }'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k other
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$t" "$k")" "$t/$k hook order"
    [[ $k == static ]] && other=shared || other=static
    local ins="SB/pref/install/pkg/$t/$k"
    local conf; conf="$(spy_lines configure | grep "|SB/pref/build/pkg/$t/$k/build/alpha|" || true)"
    conf="$(grep "pref/build/pkg/$t/$k/build/alpha|" "$SPY_LOG" | grep '^configure' | sed "s#$SB#SB#g")"
    assert_eq "configure|SB/pref/build/pkg/$t/$k/build/alpha|bar|--host=$t --prefix=$ins --libdir=$ins/lib --disable-$other --enable-$k --with-x --opt=a b" "$conf" "$t/$k configure call"
    grep -q "^make|.*pkg/$t/$k/build/alpha|$t-gcc|-j 1 V=1$" "$SPY_LOG" || fail "make build call for $t/$k"
    grep -q "^make|.*pkg/$t/$k/build/alpha|$t-gcc|install DESTDIR=/nowhere$" "$SPY_LOG" || fail "make install call for $t/$k"
  done; done
}

t_pkgs_autotools_bootstrap_runs_once_per_source_tree() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=autotools' 'CFG_CONFIGURE_SH=configure' 'CFG_CONFIGURE_ENV=()' \
    'CFG_CONFIGURE_OPTS=()' 'CFG_MAKE_BUILD_OPTS=()' 'CFG_MAKE_INSTALL_OPTS=()' \
    'CFG_AUTOTOOLS_BOOTSTRAP=(sh -c "echo bootstrap >> \"\$HOOK_LOG\"; printf \"#!/bin/sh\nexit 0\n\" > configure; chmod +x configure")'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq 4 "$(grep -c '^bootstrap' "$HOOK_LOG")" 'one bootstrap per (target, kind) source tree'
}

t_pkgs_meson_hook_order_and_arguments() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=meson' 'CFG_MESON_OPTS=(-Dfoo=true)' 'CFG_MESON_ENV=("MENV=1")'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$t" "$k")" "$t/$k hooks"
    local b="pref/build/pkg/$t/$k/build/alpha"
    grep -q "^meson|.*$b|$t-gcc|setup .*$b .*pref/build/pkg/$t/$k/src/alpha --cross-file .*pref/build/pkg/$t/meson-$t.ini --wrap-mode=nofallback --prefix .*pref/install/pkg/$t/$k --default-library $k --buildtype release -Dfoo=true\$" "$SPY_LOG" || fail "meson setup for $t/$k: $(spy_lines meson)"
    grep -q "^ninja|.*$b|$t-gcc|-j 1 -C .*$b\$" "$SPY_LOG" || fail "ninja build $t/$k"
    grep -q "^ninja|.*$b|$t-gcc|-j 1 -C .*$b install\$" "$SPY_LOG" || fail "ninja install $t/$k"
  done; done
}

t_pkgs_cmake_hook_order_and_arguments() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=cmake' 'CFG_CMAKE_SRC_DIR=sub' 'CFG_CMAKE_CONFIGURE_OPTS=(-DX=1)' \
    'CFG_CMAKE_BUILD_OPTS=(--verbose)' 'CFG_CMAKE_INSTALL_OPTS=(--strip)'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t k onoff
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 'cfg_post_extract cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for "$t" "$k")" "$t/$k hooks"
    [[ $k == static ]] && onoff=OFF || onoff=ON
    grep -q "^cmake|.*|$t-gcc|-S .*pkg/$t/$k/src/alpha/sub -B .*pkg/$t/$k/build/alpha -DCMAKE_TOOLCHAIN_FILE=.*pkg/$t/toolchain-$t.cmake -DBUILD_SHARED_LIBS=$onoff .* -DCMAKE_BUILD_TYPE=Release -DX=1\$" "$SPY_LOG" || fail "cmake configure $t/$k: $(spy_lines cmake)"
    grep -q "^cmake|.*|$t-gcc|--build .* --config Release --parallel 1 --verbose\$" "$SPY_LOG" || fail "cmake build"
    grep -q "^cmake|.*|$t-gcc|--install .* --config Release --strip\$" "$SPY_LOG" || fail "cmake install"
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
  assert_eq 2 "$(spy_lines meson | grep -c '|setup ')" 'shared kinds use meson'
  assert_eq '' "$(spy_lines cmake)" 'generic CFG_BUILD_SYSTEM is overridden by per-kind values'
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

t_pkgs_every_target_and_kind_is_built_once_with_target_environment() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=meson' 'CFG_MESON_OPTS=()' 'CFG_MESON_ENV=()'
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq 4 "$(spy_lines meson | grep -c '|setup ')" 'four setups'
  local t k
  for t in "${PKG_TRGS[@]}"; do for k in "${PKG_KINDS[@]}"; do
    assert_eq 1 "$(sed "s#$SB#SB#g" "$SPY_LOG" | grep -c "^meson|SB/pref/build/pkg/$t/$k/build/alpha|$t-gcc|setup ")" "$t/$k once, CC=$t-gcc"
    assert_exists "$PREF_DIR/install/pkg/$t/$k" 'install prefix created'
  done; done
}

t_pkgs_environment_exported_to_hooks() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'CFG_CFLAGS=(-O2 -g)' 'CFG_LDFLAGS=(-Wl,-x)' \
    'cfg_custom_build() { { echo "$BKIND $TRG"; echo "PATH0=${PATH%%:*}"; echo "CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB STRIP=$STRIP WINDRES=$WINDRES"; echo "CPPFLAGS=$CPPFLAGS"; echo "CFLAGS=$CFLAGS"; echo "LDFLAGS=$LDFLAGS"; echo "LIBS=$LIBS"; echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"; echo "PKG_CONFIG_PATH=[$PKG_CONFIG_PATH]"; echo "PWD=$PWD"; } > "$ENV_DIR/$TRG-$BKIND"; }'
  mkdir "$SB/env"
  pkgs_run "ENV_DIR=$SB/env" -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local t="$TRG64" k=shared f="$SB/env/$TRG64-shared" i="$SB/pref/install/pkg/$TRG64/shared"
  assert_eq "shared $t
PATH0=$SB/pref/install/cross/$t/bin
CC=$t-gcc CXX=$t-g++ AR=$t-ar RANLIB=$t-ranlib STRIP=$t-strip WINDRES=$t-windres
CPPFLAGS=-I$i/include 
CFLAGS=-I$i/include -O2 -g
LDFLAGS=-L$i/lib -L$i/lib64 -Wl,-x
LIBS=-lz
PKG_CONFIG_LIBDIR=$i/lib/pkgconfig:$i/lib64/pkgconfig:$i/share/pkgconfig
PKG_CONFIG_PATH=[]
PWD=$SB/pref/build/pkg/$t/shared/build/alpha" "$(cat "$f")" 'worker environment'
}

t_pkgs_meson_and_cmake_files_have_target_specific_content() {
  pkgs_sandbox
  mkdir "$SB/keep"
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' \
    'cfg_custom_build() { cp "$MESON_CROSS_FILE" "$KEEP/meson-$TRG-$BKIND"; cp "$CMAKE_TOOLCHAIN_FILE" "$KEEP/cmake-$TRG-$BKIND"; }'
  pkgs_run "KEEP=$SB/keep" -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  local m="$SB/keep/meson-$TRG32-static" c="$SB/keep/cmake-$TRG64-shared"
  grep -q "^c = '$TRG32-gcc'$" "$m" || fail 'meson c'
  grep -q "^cpu_family = 'x86'$" "$m" || fail 'i686 cpu_family'
  grep -q "^cpu = 'i686'$" "$m" || fail 'i686 cpu'
  grep -q "^pkg-config = '.*pkg-config'$" "$m" || fail 'meson pkg-config'
  grep -q "^glib-compile-resources = '$SB/bin/glib-compile-resources'$" "$m" || fail 'native glib tool recorded'
  grep -q "^cpu_family = 'x86_64'$" "$SB/keep/meson-$TRG64-static" || fail 'x86_64 family'
  grep -q "^set(CMAKE_SYSTEM_PROCESSOR x86_64)$" "$c" || fail 'cmake processor'
  grep -q "^set(CMAKE_C_COMPILER   \"$SB/pref/install/cross/$TRG64/bin/$TRG64-gcc\")$" "$c" || fail 'cmake compiler'
  grep -q "^set(CMAKE_SYSTEM_PROCESSOR x86$" "$SB/keep/cmake-$TRG32-static" || grep -q "^set(CMAKE_SYSTEM_PROCESSOR x86)$" "$SB/keep/cmake-$TRG32-static" || fail 'i686 cmake processor'
}

t_pkgs_missing_native_glib_tools_fail_every_worker() {
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  rm "$SB/bin/glib-compile-resources" "$SB/bin/glib-compile-schemas" "$SB/bin/gdk-pixbuf-pixdata"
  make_tool_dir "$SB/rbin" bash dirname basename uname nproc pkg-config find mktemp sort sed rm mkdir rmdir cat env date touch paste awk timeout
  RC=0
  OUT="$(cd "$SB" && env "PREF=$PREF_DIR" "PATH=$SB/rbin" "TMPDIR=$SB/tmp" NCRS=4 "HOOK_LOG=$HOOK_LOG" \
      "$(command -v timeout)" 60 "$(command -v bash)" "$PKGS_SH" alpha 2>&1)" || RC=$?
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" 'Native GLib build tools were not found in PATH'
  assert_contains "$OUT" '4 packages failed to compile'
  assert_eq '' "$(cat "$HOOK_LOG")" 'no hook ran'
}

# -------------------------------------------------------- archives and jobs

t_pkgs_archive_is_extracted_once_before_post_extract() {
  pkgs_sandbox
  mkdir -p "$SB/srcsrc/alpha-1.0"; echo hello > "$SB/srcsrc/alpha-1.0/file.txt"
  tar -C "$SB/srcsrc" -czf "$PREF_DIR/src/pkg/tar/alpha-1.0.tar.gz" alpha-1.0
  mkcfg alpha 'CFG_BUILD_SYSTEM=custom' 'unset CFG_NO_ARCHIVE' \
    'cfg_post_extract() { printf "%s\n" "$(cat "$PKG_SRC/file.txt")-$TRG-$BKIND" >> "$HOOK_LOG"; }'
  sed -i '/CFG_NO_ARCHIVE/d' "$PREF_DIR/src/pkg/cfg/alpha.sh"
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq 4 "$(grep -c '^hello-' "$HOOK_LOG")" 'extracted content visible to the hook in each source tree'
  assert_absent "$PREF_DIR/build/pkg/$TRG64/static/src/alpha" 'source tree removed afterwards'
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
  tar -C "$SB/x" -cJf "$PREF_DIR/src/pkg/tar/alpha-1.0-b.tar.xz" f
  pkgs_run -- alpha
  assert_rc 1 "$RC" 'two tarballs'
  assert_contains "$OUT" 'found 2'
}

t_pkgs_job_counts_follow_ncrs() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=autotools' 'CFG_CONFIGURE_SH=configure' 'CFG_AUTOTOOLS_BOOTSTRAP=()' \
    'CFG_CONFIGURE_ENV=()' 'CFG_CONFIGURE_OPTS=()' 'CFG_MAKE_BUILD_OPTS=()' 'CFG_MAKE_INSTALL_OPTS=()' \
    'cfg_post_extract() { printf "#!/bin/sh\nexit 0\n" > "$PKG_SRC/configure"; chmod +x "$PKG_SRC/configure"; }'
  local n want
  for n in "1:1" "3:1" "4:1" "8:2" "16:4"; do
    : > "$SPY_LOG"
    pkgs_run NCRS="${n%%:*}" -- alpha
    assert_rc 0 "$RC" "NCRS=${n%%:*} status ($OUT)"
    want="${n##*:}"
    assert_eq 4 "$(grep -c "^make|.*|-j $want\$" "$SPY_LOG" || true)" "NCRS=${n%%:*} gives make -j $want"
  done
}

t_pkgs_malformed_ncrs_current_behavior() {
  # Documented gaps: common.sh lets malformed values through; the arithmetic in
  # make_pkgs.sh then either aborts or accepts them (e.g. 0x10 acts as 16).
  pkgs_sandbox
  mkcfg alpha "$CUSTOM_BUILD"
  local v
  for v in abc 4x 08; do
    pkgs_run NCRS="$v" -- alpha
    [[ "$RC" -ne 0 ]] || fail "NCRS=$v unexpectedly succeeded"
    assert_eq '' "$(cat "$HOOK_LOG")" "NCRS=$v: nothing built"
  done
  pkgs_run NCRS=abc -- alpha;  assert_contains "$OUT" 'integer expression expected' 'abc diagnostic from common.sh'
  pkgs_run NCRS=0x10 -- alpha
  assert_rc 0 "$RC" "NCRS=0x10 is accepted ($OUT)"
  pkgs_run NCRS=0 -- alpha
  assert_rc 1 "$RC" 'NCRS=0 rejected by common.sh'
  assert_contains "$OUT" 'No processing units appear to be available'
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
      assert_absent "$PREF_DIR/build/pkg/$t/$k/src/alpha" "$t/$k source dir"
      assert_absent "$PREF_DIR/build/pkg/$t/$k/build/alpha" "$t/$k build dir"
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
  mkdir -p "$PREF_DIR/build/pkg"
  mkdir "$PREF_DIR/build/pkg/$TRG64.meson.lock"
  ( sleep 3; date +%s.%N > "$SB/released"; rmdir "$PREF_DIR/build/pkg/$TRG64.meson.lock" ) &
  local rel=$!
  pkgs_run -- alpha
  wait "$rel"
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
  mkcfg alpha 'CFG_BUILD_SYSTEM=autotools' 'CFG_CONFIGURE_SH=configure' 'CFG_AUTOTOOLS_BOOTSTRAP=()' \
    'CFG_CONFIGURE_ENV=()' 'CFG_CONFIGURE_OPTS=()' 'CFG_MAKE_BUILD_OPTS=()' 'CFG_MAKE_INSTALL_OPTS=()' \
    'cfg_post_extract() { printf "#!/bin/sh\nexit 0\n" > "$PKG_SRC/configure"; chmod +x "$PKG_SRC/configure"; }'
  mkcfg beta "$CUSTOM_BUILD"
  pkgs_run "MOCK_FAIL_CC=$TRG64-gcc" -- alpha beta
  assert_rc 1 "$RC" 'status'
  assert_contains "$OUT" 'compiling failed: failed building for alpha'
  local failed; failed="$(sed -n 's/^.*packages failed to compile: //p' <<< "$OUT" | tr ' ' '\n' | sort | paste -sd' ')"
  assert_eq "alpha:$TRG64:shared alpha:$TRG64:static" "$failed" 'exactly the failing workers are named'
  assert_contains "$OUT" '2 packages failed to compile:'
  assert_eq 'cfg_post_configure cfg_post_build cfg_post_install' "$(hooks_for $TRG32 static alpha)" 'sibling workers complete'
  assert_eq '' "$(hooks_for $TRG64 static alpha | grep -o 'cfg_post_install' || true)" 'failing worker stops before install hook'
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
  local n; n="$(find "$SB/tmp" -type f | wc -l)"
  assert_eq 1 "$n" 'exactly one leaked temp file in TMPDIR'
  echo "leaked: $(find "$SB/tmp" -type f | sed "s#$SB#SB#")"
}

t_pkgs_no_forbidden_tool_and_no_production_tree_touched() {
  pkgs_sandbox
  mkcfg alpha 'CFG_BUILD_SYSTEM=cmake' 'CFG_CMAKE_SRC_DIR=.' 'CFG_CMAKE_CONFIGURE_OPTS=()' 'CFG_CMAKE_BUILD_OPTS=()' 'CFG_CMAKE_INSTALL_OPTS=()'
  local before; before="$(cd "$CRS_ROOT" && ls -A; ls -A build install src/cpl 2>/dev/null)"
  pkgs_run -- alpha
  assert_rc 0 "$RC" "status ($OUT)"
  assert_eq "$before" "$(cd "$CRS_ROOT" && ls -A; ls -A build install src/cpl 2>/dev/null)" 'repository top level and build/install/src/cpl listings unchanged'
}

#!/bin/bash
set -euo pipefail

# Optional behaviour
declare -r DELETE_PKG_SRC=1 # Delete source directory after compilation (no=0, yes=1)
declare -r DELETE_PKG_BLD=1 # Delete build directory after compilation (no=0, yes=1)
declare -r DELETE_MESON_CONF=1 # Delete meson ini file
declare -r DELETE_CMAKE_CONF=1 # Delete cmake toolchain file
declare -r PARALLEL_LOOP=1  # Parallelise the loop over build kinds (e.g. 32bit, 64bit)
                            # and targets (e.g. i686 mingw, x86_64 mingw) (no=0, yes=1)

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/etc/common.sh"
unset script_dir

# Define a trash bin for temporary directories and files to be
# deleted on exit from this script.
# Add to this bin with 'put_into_trash_bin "$AFTER_ALL_BUILDS_TRASH_BIN" dir_or_file, ...'
declare -r AFTER_ALL_BUILDS_TRASH_BIN="$(mktemp -q)"
trap 'empty_trash_bin "$AFTER_ALL_BUILDS_TRASH_BIN"' EXIT

# Constant initialisation
declare -ra BUILD_KINDS=([0]="static" [1]="shared")
declare -rA BUILD_KINDS_REV=(
  [${BUILD_KINDS[0]}]=${BUILD_KINDS[1]}
  [${BUILD_KINDS[1]}]=${BUILD_KINDS[0]}
)

# For parallelising the loop
declare -ri PARALLEL_RUNS=$((
  (1 + (${#TARGETS[@]} * ${#BUILD_KINDS[@]} -1) * PARALLEL_LOOP) <= $NCRS ?
  (1 + (${#TARGETS[@]} * ${#BUILD_KINDS[@]} -1) * PARALLEL_LOOP)          :
   $NCRS
)) # Always less than or equal to the number of cores
declare -ri NCRS_PER_RUN=$((
  PARALLEL_LOOP ?
    NCRS / PARALLEL_RUNS :
    NCRS
)) # Always greater than or equal to one, since PARELLEL_RUNS <= NCRS

# Define the directory structure
declare -r PKG_TAR_DIR="$SOURCE_DIRECTORY/pkg/tar"
declare -r PKG_CFG_DIR="$SOURCE_DIRECTORY/pkg/cfg"
declare -r PKG_PTC_DIR="$SOURCE_DIRECTORY/pkg/ptc"
declare -r PKG_BLD_DIR="$BUILD_DIRECTORY/pkg"
declare -r PKG_INS_DIR="$INSTALL_DIRECTORY/pkg"

# Collect the available configurations to compile
declare -a cfgs=()
while IFS= read -r fn
do
  cfgs+=("$(basename "${fn%.sh}")")
done < <(
  find "$PKG_CFG_DIR" -maxdepth 1 -name '*.sh'
)
unset fn

# Function definitions
function usage() {
  echo
  echo " usage: $0 cfg1 [cfg2...]"
  echo
  echo " configuration files must exist in: $PKG_CFG_DIR"
  echo " available gcc configurations: ${cfgs[*]}"
  echo
  exit 1
}

# Argument handling
if [ $# -lt 1 ]
then
  usage
fi
declare -ra CFG_ORDER=("$@"); shift $#

# Check that all configuration files can be uniquely determined
for cfg in "${CFG_ORDER[@]}"
do
  declare -i found=0
  for cfg_full in "${cfgs[@]}"
  do
    if [ "$cfg_full" = "${cfg}" ]
    then
      ! ((found++)) # "!" is a hack to have "set -e" option ignore the exit status of ((
      if [ $found -gt 1 ]
      then
        echo "Configuration not unique: $cfg"
        echo
        usage
      fi
    fi
  done
  if [ $found -lt 1 ]
  then
    echo "Configuration not found: $cfg"
    echo
    usage
  fi
done
unset cfg found cfg_full cfgs

# Apply patch
function apply_patch_file() {
  local -r PTC="$1"; local -r PKG_SRC="$2"; shift 2
  local -r PATCH_HISTORY="$PKG_SRC/.patches_applied"

  if [ -f $PKG_SRC/.patches_applied ] && \
     [ $(grep -F -m 1 -c -e "$PTC" -- $PATCH_HISTORY) -ge 1 ]
  then
    echo "Patch has already been applied: $PTC"
  else
    echo "Applying patch: $PTC"
    patch -d "$PKG_SRC" -p1 < "$PTC"
    echo "$PTC" >> "$PATCH_HISTORY"
  fi
}

# Load configuration file
function load_pkg_config() {
  local -r CFG="$1"; shift

  local -r CFG_FILE="$PKG_CFG_DIR/${CFG}.sh"

  if [ -z "$CFG" ] || [ ! -f "$CFG_FILE" ]
  then
    echo "This is strange, the configuration file does not exist: $CFG_FILE"
    exit 1
  fi

  echo "Loading configuration: $CFG"
  source "$CFG_FILE"
}

# Run a hook
run_hook() {
  local -r HOOK="$1"; shift

  if declare -F "$HOOK" >/dev/null
  then
    "$HOOK"
  fi
}

# Build in a subshell (isolated environment for each build)
function process_cfg() (
  local -r CFG="$1"; local -r BKIND=$2; local -r TRG="$3"; local -r NJOBS=$4; shift 4

  # Gera loggið læsilegra
  if [ -n "${PARALLEL_LOOP:-}" ] && [ "$PARALLEL_LOOP" -ne 0 ]
  then
    exec > >(sed "s/^/[$CFG:$TRG:$BKIND] /")
    exec 2>&1
  fi

  # Define a trash bin for temporary directories and files to be
  # deleted on exit from this subshell
  # Add to this bin with 'put_into_trash_bin "$WITHIN_BUILD_TRASH_BIN" dir_or_file, ...'
  declare -r WITHIN_BUILD_TRASH_BIN="$(mktemp -q)"
  trap 'empty_trash_bin "$WITHIN_BUILD_TRASH_BIN"' EXIT

  # Build, patch and install directories
  local -r PKG_SRC="$PKG_BLD_DIR/$TRG/$BKIND/src/$CFG"
  local -r PKG_BLD="$PKG_BLD_DIR/$TRG/$BKIND/build/$CFG"
  local -r PKG_INS="$PKG_INS_DIR/$TRG/$BKIND"
  mkdir -p -- "$PKG_SRC" "$PKG_BLD" "$PKG_INS"

  # Collect for deleting on exit
  if [ -n "${DELETE_PKG_SRC:-}" ] && [ "$DELETE_PKG_SRC" -ne 0 ]
  then
    put_into_trash_bin "$WITHIN_BUILD_TRASH_BIN" "$PKG_SRC"
  fi
  if [ -n "${DELETE_PKG_BLD:-}" ] && [ "$DELETE_PKG_BLD" -ne 0 ]
  then
    put_into_trash_bin "$WITHIN_BUILD_TRASH_BIN" "$PKG_BLD"
  fi

  local -r BIN="$INSTALL_DIRECTORY/cross/$TRG/bin"
  export PATH="$BIN:$PATH"
  export CC="$TRG-gcc"
  export CXX="$TRG-g++"
  export AR="$TRG-ar"
  export RANLIB="$TRG-ranlib"
  export STRIP="$TRG-strip"
  export WINDRES="$TRG-windres"

  export PKG_CONFIG_LIBDIR="$PKG_INS/lib/pkgconfig:$PKG_INS/lib64/pkgconfig:$PKG_INS/share/pkgconfig"
  export PKG_CONFIG_PATH=

  # Define variables for the meson ini file
  local cpu_family=''
  local cpu=''
  case "$TRG" in
  x86_64-*)
    cpu_family="x86_64"
    cpu="x86_64"
    ;;
  i686-*)
    cpu_family="x86"
    cpu="i686"
    ;;
  esac

  function create_meson_cross_file() {
    [ $# -eq 1 ] || return 1
    local -r CROSS_FILE="$1"; shift
    if [ ! -f "$CROSS_FILE" ] || \
       [ "$CROSS_FILE" -ot "$INSTALL_DIRECTORY/cross/$TRG" ]
    then
      cat > "$CROSS_FILE" <<EOD
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
windres = '$WINDRES'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOD
    fi
  }
  local -r MESON_CROSS_FILE="$PKG_BLD_DIR/$TRG/meson-$TRG.ini"
  local -r MESON_CROSS_LOCK="$PKG_BLD_DIR/$TRG.meson.lock"
  # Generate Meson cross file atomically to avoid concurrent writers.
  lock_run "$MESON_CROSS_LOCK" \
    create_meson_cross_file "$MESON_CROSS_FILE"
  unset cpu
  if [ -n "${DELETE_MESON_CONF:-}" ] && [ "$DELETE_MESON_CONF" -ne 0 ]
  then
    put_into_trash_bin "$AFTER_ALL_BUILDS_TRASH_BIN" "$MESON_CROSS_FILE"
  fi

  function create_cmake_toolchain_file() {
    [ $# -eq 1 ] || return 1
    local -r TOOLCHAIN_FILE="$1"; shift
    if [ ! -f "$TOOLCHAIN_FILE" ] || \
       [ "$TOOLCHAIN_FILE" -ot "$INSTALL_DIRECTORY/cross/$TRG" ]
    then
      cat > "$TOOLCHAIN_FILE" <<EOD
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $cpu_family)

set(CMAKE_C_COMPILER   "$BIN/$CC")
set(CMAKE_CXX_COMPILER "$BIN/$CXX")
set(CMAKE_RC_COMPILER  "$BIN/$WINDRES")

set(CMAKE_AR      "$BIN/$AR")
set(CMAKE_RANLIB  "$BIN/$RANLIB")
set(CMAKE_STRIP   "$BIN/$STRIP")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOD
    fi
  }
  local -r CMAKE_TOOLCHAIN_FILE="$PKG_BLD_DIR/$TRG/toolchain-$TRG.cmake"
  local -r CMAKE_TOOLCHAIN_LOCK="$PKG_BLD_DIR/$TRG.cmake.lock"
  # Generate Cmake toolchain file atomically to avoid concurrent writers.
  lock_run "$CMAKE_TOOLCHAIN_LOCK" \
    create_cmake_toolchain_file "$CMAKE_TOOLCHAIN_FILE"
  if [ -n "${DELETE_CMAKE_CONF:-}" ] && [ "$DELETE_CMAKE_CONF" -ne 0 ]
  then
    put_into_trash_bin "$AFTER_ALL_BUILDS_TRASH_BIN" "$CMAKE_TOOLCHAIN_FILE"
  fi
  unset cpu_family

  # Load the current configuration with information about the source and how to compile
  # static and shared libraries
  load_pkg_config "$CFG"

  # Make compilerflags available (note configuration specific additions)
  export CPPFLAGS="-I$PKG_INS/include ${CFG_CPPFLAGS[*]}"
  export CFLAGS="-I$PKG_INS/include ${CFG_CFLAGS[*]}"
  export CXXFLAGS="-I$PKG_INS/include ${CFG_CXXFLAGS[*]}"
  export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 ${CFG_LDFLAGS[*]}"
  export LIBS="${CFG_LIBS[*]}"

  # Find name of archive with and without suffix
  mapfile -d '' -t pkg_tars < <(
    find \
      "$PKG_TAR_DIR" \
      -maxdepth 1 \
      -name "${CFG_PKG_NAME}*${CFG_VERSION}*.tar.*" \
      -type f \
      -print0 | \
    sort -z
  )
  if [ "${#pkg_tars[@]}" -ne 1 ]
  then
    printf 'Expected exactly one tarball for configuration %s, found %d\n  %s\n' \
      "$CFG" "${#pkg_tars[@]}" "${pkg_tars[@]}" >&2
    exit 1
  fi
  local -r PKG_TAR="${pkg_tars[0]}"
  unset pkg_tars

  # Package extracted into its mutuable source directory, patches
  # applied and any post extraction configuration applied to the code.
  local -r PKG_EXTRACTED="$PKG_SRC/.extracted"
  if [ ! -f "$PKG_EXTRACTED" ]
  then
    tar --strip-components=1 --directory="$PKG_SRC" -xaf "$PKG_TAR"
    # Apply available patches for this packages
    while IFS= read -r -d '' ptc
    do
      apply_patch_file "$ptc" "$PKG_SRC"
    done < <(
      find "$PKG_PTC_DIR" -maxdepth 1 -iname "${CFG}-[0-9]*.patch" -type f -print0 | sort -z
    )
    # Apply specific configuration for this build
    run_hook cfg_post_extract
    touch -- "$PKG_EXTRACTED"
    unset ptc
  fi

  # Enter build directory
  cd -- "$PKG_BLD"

  # Determine the building system used.
  # Can be set differently for shared and static builds with
  # CFG_BUILD_SYSTEM_STATIC and CFG_BUILD_SYSTEM_SHARED or
  # the same for both with CFG_BUILD_SYSTEM.
  local build_system_case="CFG_BUILD_SYSTEM_${BKIND^^}"
  local build_system="${!build_system_case:-${CFG_BUILD_SYSTEM:-}}"
  case "$build_system" in
  "custom")
    # All other hooks are run inside this function
    run_hook cfg_custom_build
    ;;
  "autotools")
    if [ "${#CFG_AUTOTOOLS_BOOTSTRAP[@]}" -gt 0 ]
    then
      local -r BOOTSTRAP_FINISHED="$PKG_SRC/.autotools_bootstrapped"
      if [ ! -f "$BOOTSTRAP_FINISHED" ]
      then
        cd -- "$PKG_SRC"
        "${CFG_AUTOTOOLS_BOOTSTRAP[@]}"
        touch -- "$BOOTSTRAP_FINISHED"
        cd -- "$PKG_BLD"
      fi
    fi
    if [ -z "${CFG_CUSTOM_CONFIGURE:-}" ]
    then
      env "${CFG_CONFIGURE_ENV[@]}" \
        "$PKG_SRC/$CFG_CONFIGURE_SH" \
          --host="$TRG" \
          --prefix="$PKG_INS" \
          --disable-${BUILD_KINDS_REV[$BKIND]} \
          --enable-$BKIND \
          "${CFG_CONFIGURE_OPTS[@]}"
    fi
    run_hook cfg_post_configure
    if [ -z "${CFG_CUSTOM_BUILD:-}" ]
    then
      make -j "$NJOBS" "${CFG_MAKE_BUILD_OPTS[@]}" || comp_fail "failed building for $CFG"
    fi
    run_hook cfg_post_build
    if [ -z "${CFG_CUSTOM_INSTALL:-}" ]
    then
      make install "${CFG_MAKE_INSTALL_OPTS[@]}" || comp_fail "failed installing for $CFG"
    fi
    run_hook cfg_post_install
    ;;
  "meson")
    env "${CFG_MESON_ENV[@]}" \
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --wrap-mode=nofallback \
      --prefix "$PKG_INS" \
      --default-library "$BKIND" \
      --buildtype release \
      "${CFG_MESON_OPTS[@]}"
    run_hook cfg_post_configure
    ninja -j "$NJOBS" -C "$PKG_BLD" || comp_fail "failed compiling for $CFG"
    run_hook cfg_post_build
    ninja -j "$NJOBS" -C "$PKG_BLD" install || comp_fail "failed installing for $CFG"
    run_hook cfg_post_install
    ;;
  "cmake")
    cmake \
      -S "$PKG_SRC" \
      -B "$PKG_BLD" \
      -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
      -DBUILD_SHARED_LIBS=$([ "$BKIND" = "${BUILD_KINDS[0]}" ] && echo OFF || echo ON) \
      -DCMAKE_PREFIX_PATH="$PKG_INS" \
      -DCMAKE_FIND_ROOT_PATH="$PKG_INS" \
      -DCMAKE_INSTALL_PREFIX="$PKG_INS" \
      -DCMAKE_BUILD_TYPE=Release \
      "${CFG_CMAKE_CONFIGURE_OPTS[@]}"
    run_hook cfg_post_configure
    cmake \
      --build "$PKG_BLD" \
      --config Release \
      --parallel "$NJOBS" \
      "${CFG_CMAKE_BUILD_OPTS[@]}"
    run_hook cfg_post_build
    cmake \
      --install "$PKG_BLD" \
      --config Release \
      "${CFG_CMAKE_INSTALL_OPTS[@]}"
    run_hook cfg_post_install
    ;;
  *)
    echo "Consider supplying a config file in ./src/pkg/cfg/"
    exit 1
    ;;
  esac
)

for cfg in "${CFG_ORDER[@]}"
do
  declare after_config_build_trash_bin="$(mktemp -q)"
  declare prc=''
  declare pid=''
  declare -a failed=()
  declare -A pid_to_job=()
  for trg in "${TARGETS[@]}"
  do
    for bkind in "${BUILD_KINDS[@]}"
    do
      (
        echo
        echo "Processing configuration $cfg ($bkind build on $trg)"
        echo
        process_cfg "$cfg" "$bkind" "$trg" "$NCRS_PER_RUN"
      ) &
      pid=$!
      pid_to_job["$pid"]="$cfg:$trg:$bkind"
      while [ "${#pid_to_job[@]}" -ge "$PARALLEL_RUNS" ]
      do
        if ! wait -n -p prc
        then
          failed+=("${pid_to_job["$prc"]}")
        fi
        unset 'pid_to_job[$prc]'
      done
      # Exit the loop on error if not parallelising
      if [ "$PARALLEL_LOOP" -eq 0 ] && [ ${#failed[@]} -gt 0 ]
      then
        break 2
      fi
    done
  done
  while [ "${#pid_to_job[@]}" -gt 0 ]
  do
    if ! wait -n -p prc
    then
      failed+=("${pid_to_job["$prc"]}")
    fi
    unset 'pid_to_job[$prc]'
  done
  if [ "${#failed[@]}" -gt 0 ]
  then
    echo "${#failed[@]} packages failed to compile: ${failed[*]}"
    exit 1
  fi
  empty_trash_bin "$after_config_build_trash_bin"
  unset prc pid failed pid_to_job after_config_build_trash_bin
done

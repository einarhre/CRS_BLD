#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='icu'
declare -rg CFG_VERSION='78.3'
declare -rg CFG_WEBSITE='https://github.com/unicode-org/icu'
declare -rg CFG_BUILD_SYSTEM='custom'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
)

# Additional compiler dependencies
declare -rga CFG_CPPFLAGS=(
)
declare -rga CFG_CFLAGS=(
)
declare -rga CFG_CXXFLAGS=(
  '-std=gnu++17'
)
declare -rga CFG_LDFLAGS=(
)
declare -rga CFG_LIBS=(
  '-lstdc++'
)

# Configuration options
declare -rga CFG_CUSTOM_OPTS=(
)

# Hooks
function cfg_post_extract() {
  find -- "$PKG_INS/bin" "$PKG_INS/lib" "$PKG_INS/lib64" \
    -maxdepth 1 \
      \( -name 'libicu?*.a'  -o -name 'libicu?*.dll'  -o -name 'libicu?*.dll.a' -o     \
         -name 'libsicu?*.a' -o -name 'libsicu?*.dll' -o -name 'libsicu?*.dll.a' -o    \
         -name 'icu?*.a'     -o -name 'icu?*.dll'     -o -name 'icu?*.dll.a'        \) \
      -delete 2>/dev/null || true
}
function cfg_post_configure() {
  mkdir -p -- "$PKG_BLD/lib" "$PKG_BLD/bin"
}
function cfg_post_build() {
  if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
  then
    [[ -f "$PKG_BLD/lib/libsicuuc.a" ]] && ln -sf -- libsicuuc.a "$PKG_BLD/lib/libicuuc.a"
    [[ -f "$PKG_BLD/lib/libsicuin.a" ]] && ln -sf -- libsicuin.a "$PKG_BLD/lib/libicuin.a"
    [[ -f "$PKG_BLD/lib/libsicuio.a" ]] && ln -sf -- libsicuio.a "$PKG_BLD/lib/libicuio.a"
    [[ -f "$PKG_BLD/lib/libsicutu.a" ]] && ln -sf -- libsicutu.a "$PKG_BLD/lib/libicutu.a"
    [[ -f "$PKG_BLD/stubdata/libsicudt.a" ]] && ln -sf -- ../stubdata/libsicudt.a "$PKG_BLD/lib/libicudt.a"
  fi
}
function cfg_post_install() {
  if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
  then
    for libdir in "$PKG_INS/lib" "$PKG_INS/lib64"
    do
      [[ -d "$libdir" ]] || continue
      [[ -f "$libdir/libsicuuc.a" ]] && ln -sf -- libsicuuc.a "$libdir/libicuuc.a"
      [[ -f "$libdir/libsicuin.a" ]] && ln -sf -- libsicuin.a "$libdir/libicuin.a"
      [[ -f "$libdir/libsicuio.a" ]] && ln -sf -- libsicuio.a "$libdir/libicuio.a"
      [[ -f "$libdir/libsicutu.a" ]] && ln -sf -- libsicutu.a "$libdir/libicutu.a"
      [[ -f "$libdir/libsicudt.a" ]] && ln -sf -- libsicudt.a "$libdir/libicudt.a"
    done
  fi
}
function cfg_custom_build() {
  local -r ICU_HOST_TOOLS_BLD="$PKG_BLD_DIR/host-tools/build/$CFG_PKG_NAME"
  local -r ALREADY_BUILD="$ICU_HOST_TOOLS_BLD/.built"
  local -r ICU_HOST_TOOLS_LOCK="$ICU_HOST_TOOLS_BLD.lock"
  mkdir -p -- "$ICU_HOST_TOOLS_BLD"
  # Collect for deleting on exit
  if [[ -n "${DELETE_PKG_BLD:-}" ]] && [[ "$DELETE_PKG_BLD" -ne 0 ]]
  then
    put_into_trash_bin "$after_config_build_trash_bin" "$ICU_HOST_TOOLS_BLD"
  fi

  function build_host_tools() {
    if [[ ! -f "$ALREADY_BUILD" ]]
    then
      (
        cd -- "$ICU_HOST_TOOLS_BLD"
        env \
          CC=gcc \
          CXX=g++ \
          AR=ar \
          RANLIB=ranlib \
          STRIP=strip \
          CPPFLAGS= \
          CFLAGS= \
          CXXFLAGS=-std=gnu++17 \
          LDFLAGS= \
          LIBS=-lstdc++ \
          PKG_CONFIG_LIBDIR= \
          PKG_CONFIG_PATH= \
          "$PKG_SRC/icu4c/source/configure" \
            --enable-tests=no \
            --enable-samples=no
        make -j "$NJOBS"
        touch -- "$ALREADY_BUILD"
      ) # Previous environment resumed
    fi
  }
  # Build host tools atomically to avoid concurrent builds.
  lock_run "$ICU_HOST_TOOLS_LOCK" build_host_tools

  "$PKG_SRC/icu4c/source/configure" \
    --host="$TRG" \
    --prefix="$PKG_INS" \
    --libdir="$PKG_INS/lib" \
    --disable-${BUILD_KINDS_REV[$BKIND]} \
    --enable-$BKIND \
    --with-cross-build="$ICU_HOST_TOOLS_BLD" \
    --enable-icu-config=no \
    SHELL="$SHELL" \
    CXXFLAGS="-std=gnu++17 ${CXXFLAGS:-}" \
    LIBS="-lstdc++ ${LIBS:-}"

  run_hook cfg_post_configure

  make -C stubdata       -j "$NJOBS" VERBOSE=1 SO_TARGET_VERSION_SUFFIX=
  make -C common         -j "$NJOBS" VERBOSE=1 SO_TARGET_VERSION_SUFFIX=
  make -C i18n           -j "$NJOBS" VERBOSE=1 SO_TARGET_VERSION_SUFFIX=
  make -C io             -j "$NJOBS" VERBOSE=1 SO_TARGET_VERSION_SUFFIX=
  make -C tools/toolutil -j "$NJOBS" VERBOSE=1 SO_TARGET_VERSION_SUFFIX=

  run_hook cfg_post_build

  make -j "$NJOBS" VERBOSE=1 SO_TARGET_VERSION_SUFFIX=

  make install VERBOSE=1 SO_TARGET_VERSION_SUFFIX=

  run_hook cfg_post_install
}

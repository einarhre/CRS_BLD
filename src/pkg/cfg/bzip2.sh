#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='bzip2'
declare -rg CFG_VERSION='1.0.8'
declare -rg CFG_WEBSITE='https://sourceware.org/pub/bzip2/'
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
)
declare -rga CFG_LDFLAGS=(
)
declare -rga CFG_LIBS=(
)

# Configuration options
declare -rga CFG_CUSTOM_OPTS=(
)

# Hooks
function cfg_post_extract() {
  return
}
function cfg_post_configure() {
  return
}
function cfg_post_build() {
  return
}
function cfg_post_install() {
  install -d "$PKG_INS/lib/pkgconfig"

  cat > "$PKG_INS/lib/pkgconfig/${CFG_PKG_NAME}.pc" <<EOD
prefix=$PKG_INS
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: $CFG_PKG_NAME
Description: Lossless block-sorting data compression library
Version: $CFG_VERSION

Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOD
}
function cfg_custom_build() {
  make -C "$PKG_SRC" clean || true

  make -C "$PKG_SRC" -j "$NJOBS" libbz2.a \
    "PREFIX=$PKG_INS" \
    "CC=$CC" \
    "AR=$AR" \
    "RANLIB=$RANLIB"

  install -d "$PKG_INS/lib" "$PKG_INS/include" "$PKG_INS/bin"
  install -m644 "$PKG_SRC/bzlib.h" "$PKG_INS/include/"

  if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
  then
    install -m644 "$PKG_SRC/libbz2.a" "$PKG_INS/lib/"
  elif [[ "$BKIND" = "${BUILD_KINDS[1]}" ]]
  then
    "$CC" "$PKG_SRC"/*.o -shared \
      -o "$PKG_INS/bin/libbz2.dll" \
      -Wl,--out-implib,"$PKG_INS/lib/libbz2.dll.a"
  fi

  run_hook cfg_post_install
}

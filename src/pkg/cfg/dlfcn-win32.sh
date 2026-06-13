#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='dlfcn-win32'
declare -rg CFG_VERSION='1.4.2'
declare -rg CFG_WEBSITE='https://github.com/dlfcn-win32/dlfcn-win32'
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
  return
}
function cfg_custom_build() {
  cd -- "$PKG_SRC"
  ./configure \
    --prefix="$PKG_INS" \
    --libdir="$PKG_INS/lib" \
    --cross-prefix="$TRG-" \
    --enable-$BKIND \
    --disable-${BUILD_KINDS_REV[$BKIND]}
  make -j "$NJOBS"
  make install
  mkdir -p -- "$PKG_INS/lib/pkgconfig"
  cat -- > "$PKG_INS/lib/pkgconfig/dlfcn.pc" <<EOD
prefix=$PKG_INS
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: dlfcn-win32
Version: $CFG_VERSION
Description: POSIX dlfcn wrapper for Windows

Libs: -ldl
Libs.private: -lpsapi
Cflags: -I\${includedir}
EOD
}

#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='zlib'
declare -rg CFG_VERSION='1.3.2'
declare -rg CFG_WEBSITE='https://zlib.net/'
declare -rg CFG_BUILD_SYSTEM_STATIC='autotools'
declare -rg CFG_BUILD_SYSTEM_SHARED='custom'
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
# Autotools
declare -rg CFG_CUSTOM_CONFIGURE='yes'
declare -rg CFG_CUSTOM_BUILD=''
declare -rg CFG_CUSTOM_INSTALL=''
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
  '--static'
)
declare -rga CFG_CONFIGURE_ENV=(
  "CHOST=$TRG"
)
declare -rga CFG_MAKE_BUILD_OPTS=(
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
)
# Custom
declare -rga CFG_CUSTOM_OPTS=(
)

# Hooks
function cfg_post_extract() {
  return
}
function cfg_post_configure() {
  env "${CFG_CONFIGURE_ENV[@]}" \
    "$PKG_SRC/$CFG_CONFIGURE_SH" \
      --prefix="$PKG_INS" \
      --libdir="$PKG_INS/lib" \
      "${CFG_CONFIGURE_OPTS[@]}"
}
function cfg_post_build() {
  return
}
function cfg_post_install() {
  return
}
function cfg_custom_build() {
  make \
    -C "$PKG_SRC" \
    -f win32/Makefile.gcc \
    SHARED_MODE=1 \
    STATICLIB= \
    "BINARY_PATH=$PKG_INS/bin" \
    "INCLUDE_PATH=$PKG_INS/include" \
    "LIBRARY_PATH=$PKG_INS/lib" \
    "PREFIX=$TRG-" \
    -j "$NJOBS" \
    install
}

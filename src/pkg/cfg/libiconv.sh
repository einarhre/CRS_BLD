#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='libiconv'
declare -rg CFG_VERSION='1.19'
declare -rg CFG_WEBSITE='https://www.gnu.org/software/libiconv/'
declare -rg CFG_BUILD_SYSTEM='autotools'
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
declare -rg CFG_CUSTOM_CONFIGURE=''
declare -rg CFG_CUSTOM_BUILD='yes'
declare -rg CFG_CUSTOM_INSTALL='yes'
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
  '--disable-nls'
  "--libdir=$PKG_INS/lib"
)
declare -rga CFG_CONFIGURE_ENV=(
)
declare -rga CFG_MAKE_BUILD_OPTS=(
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
)

# Hooks
function cfg_post_extract() {
  sed -i 's, sed , sed ,g' "$PKG_SRC/windows/windres-options"
}
function cfg_post_configure() {
  return
}
function cfg_post_build() {
  make -j "$NJOBS" -C "$PKG_BLD/libcharset" install
  make -j "$NJOBS" -C "$PKG_BLD/lib" install

  install -d "$PKG_INS/include"
  install \
    -m644 \
    "$PKG_BLD/include/${CFG_PKG_NAME##lib}.h.inst" \
    "$PKG_INS/include/${CFG_PKG_NAME##lib}.h"
}
function cfg_post_install() {
  rm -f -- "$PKG_INS/lib/charset.alias"
  rm -f -- "$PKG_INS/lib64/charset.alias"
  return
}
function cfg_custom_build() {
  return
}

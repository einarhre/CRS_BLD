#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='libpng'
declare -rg CFG_VERSION='1.6.58'
declare -rg CFG_WEBSITE='http://www.libpng.org/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'zlib' #
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
declare -rg CFG_CUSTOM_BUILD=''
declare -rg CFG_CUSTOM_INSTALL=''
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
)
declare -rga CFG_CONFIGURE_ENV=(
)
declare -rga CFG_MAKE_BUILD_OPTS=(
  'bin_PROGRAMS='
  'sbin_PROGRAMS='
  'noinst_PROGRAMS='
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
  'bin_PROGRAMS='
  'sbin_PROGRAMS='
  'noinst_PROGRAMS='
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
  for pc in "$PKG_INS"/lib{,64}/pkgconfig/libpng16.pc
  do
    [[ -f "$pc" ]] || continue
    sed -i \
      -e 's/[[:space:]]-lz\([[:space:]]\|$\)/\1/g' \
      -e 's/[[:space:]][[:space:]]*/ /g' \
      -e 's/[[:space:]]*$//' \
      "$pc"
  done
}
function cfg_custom_build() {
  return
}

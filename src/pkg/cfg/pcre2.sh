#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='pcre2'
declare -rg CFG_VERSION='10.47'
declare -rg CFG_WEBSITE='https://www.pcre.org/'
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
declare -rg CFG_CUSTOM_BUILD=''
declare -rg CFG_CUSTOM_INSTALL=''
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
  "--enable-${CFG_PKG_NAME}-16"
  '--enable-utf'
  '--enable-unicode-properties'
  '--enable-cpp'
  "--disable-${CFG_PKG_NAME}grep-libz"
  "--disable-${CFG_PKG_NAME}grep-libbz2"
  "--disable-${CFG_PKG_NAME}test-libreadline"
)
declare -rga CFG_CONFIGURE_ENV=(
)
declare -rga CFG_MAKE_BUILD_OPTS=(
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
  'dist_html_DATA='
  'dist_doc_DATA='
  'dist_bin_SCRIPTS='
  'bin_PROGRAMS='
  'sbin_PROGRAMS='
  'noinst_PROGRAMS='
  'check_PROGRAMS='
)

# Hooks
function cfg_post_extract() {
  sed -i 's,__declspec(dllimport),,' "$PKG_SRC/src/${CFG_PKG_NAME}.h.in"
  sed -i 's,__declspec(dllimport),,' "$PKG_SRC/src/${CFG_PKG_NAME}posix.h"
  sed -i 's,__declspec(dllimport),,' "$PKG_SRC/src/${CFG_PKG_NAME}.h.generic"
}
function cfg_post_configure() {
  return
}
function cfg_post_build() {
  return
}
function cfg_post_install() {
  rm -f -- "$PKG_INS/share/man/man1/${CFG_PKG_NAME%%[0-9]*}*.1"
  rm -f -- "$PKG_INS/share/man/man3/${CFG_PKG_NAME%%[0-9]*}*.3"
}
function cfg_custom_build() {
  return
}

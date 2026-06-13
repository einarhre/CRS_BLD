#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='gettext'
declare -rg CFG_VERSION='1.0'
declare -rg CFG_WEBSITE='https://www.gnu.org/software/gettext/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'libiconv' #
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
declare -rg CFG_CONFIGURE_SH="${CFG_PKG_NAME}-runtime/configure"
declare -rga CFG_CONFIGURE_OPTS=(
  '--enable-threads=win32'
  '--without-libexpat-prefix'
  '--without-libxml2-prefix'
  "--libdir=$PKG_INS/lib"
)
declare -rga CFG_CONFIGURE_ENV=(
  'CONFIG_SHELL=/bin/bash'
)
declare -rga CFG_MAKE_BUILD_OPTS=(
  '-C'
  "$PKG_BLD/intl"
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
  '-C'
  "$PKG_BLD/intl"
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
  for la in "$PKG_INS"/lib/libintl.la
  do
    [[ -f "$la" ]] || continue
    sed -i \
      -e "s# -L$PKG_INS/lib64##g" \
      "$la"
  done
}
function cfg_custom_build() {
  return
}

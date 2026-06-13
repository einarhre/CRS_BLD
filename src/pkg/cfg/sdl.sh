#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='SDL'
declare -rg CFG_VERSION='1.2.15'
declare -rg CFG_WEBSITE='https://www.libsdl.org/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'libiconv'
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
declare -rg CFG_CUSTOM_INSTALL='yes'
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
  '--enable-threads'
  '--enable-directx'
  '--disable-stdio-redirect'
)
declare -rga CFG_CONFIGURE_ENV=(
)
declare -rga CFG_MAKE_BUILD_OPTS=(
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
)

# Hooks
function cfg_post_extract() {
  sed -i 's,-mwindows,-lwinmm -mwindows,' "$PKG_SRC/configure"
}
function cfg_post_configure() {
  return
}
function cfg_post_build() {
  make -j "$NJOBS" \
    install-bin install-hdrs install-lib install-data "${CFG_MAKE_INSTALL_OPTS[@]}" || \
    comp_fail "failed installing for $CFG"
}
function cfg_post_install() {
  return
}
function cfg_custom_build() {
  return
}

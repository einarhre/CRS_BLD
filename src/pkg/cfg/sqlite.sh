#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='sqlite'
declare -rg CFG_VERSION='3530100'
declare -rg CFG_WEBSITE='https://www.sqlite.org/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'dlfcn-win32' #
)

# Additional compiler dependencies
declare -rga CFG_CPPFLAGS=(
)
declare -rga CFG_CFLAGS=(
  '-Os'
  '-DSQLITE_THREADSAFE=1'
  '-DSQLITE_ENABLE_COLUMN_METADATA'
  '-DSQLITE_ENABLE_RTREE'
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
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_CONFIGURE_OPTS=(
    '--disable-readline'
  )
else
  declare -rga CFG_CONFIGURE_OPTS=(
    '--out-implib'
    '--disable-readline'
  )
fi
declare -rga CFG_CONFIGURE_ENV=(
)
declare -rga CFG_MAKE_BUILD_OPTS=(
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
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
  return
}

#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='mpg123'
declare -rg CFG_VERSION='1.33.5'
declare -rg CFG_WEBSITE='https://www.mpg123.de/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'sdl'
)

# Additional compiler dependencies
declare -rga CFG_CPPFLAGS=(
)
declare -rga CFG_CFLAGS=(
  '-std=gnu99'
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
  '--with-default-audio=win32'
  '--with-audio=win32,sdl,dummy'
  '--enable-modules=no'
)
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

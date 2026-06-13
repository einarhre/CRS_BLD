#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='package_name'
declare -rg CFG_VERSION='a.b.c' # a,b,c are integers
declare -rg CFG_BUILD_SYSTEM='custom'  # autotools, meson, cmake, or custom
declare -rg CFG_BUILD_SYSTEM_STATIC='' # if different system used between
declare -rg CFG_BUILD_SYSTEM_SHARED='' # static/shared builds
declare -rg CFG_NO_ARCHIVE=0           # tar archive is needed
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
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
)
# Meson
declare -rga CFG_MESON_OPTS=(
)
declare -rga CFG_MESON_ENV=(
)
# Cmake
declare -rg CFG_CMAKE_SRC_DIR=''
declare -rga CFG_CMAKE_CONFIGURE_OPTS=(
)
declare -rga CFG_CMAKE_BUILD_OPTS=(
)
declare -rga CFG_CMAKE_INSTALL_OPTS=(
)
# Custom
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
  return
}

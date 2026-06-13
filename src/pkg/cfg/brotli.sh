#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='brotli'
declare -rg CFG_VERSION='1.2.0'
declare -rg CFG_WEBSITE='https://github.com/google/brotli'
declare -rg CFG_BUILD_SYSTEM='cmake'
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
declare -rg CFG_CMAKE_SRC_DIR=''
declare -rga CFG_CMAKE_CONFIGURE_OPTS=(
)
declare -rga CFG_CMAKE_BUILD_OPTS=(
)
declare -rga CFG_CMAKE_INSTALL_OPTS=(
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
  rm -f -- "$PKG_INS/bin/${CFG_PKG_NAME}.exe"
}
function cfg_custom_build() {
  return
}

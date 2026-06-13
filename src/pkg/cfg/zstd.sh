#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='zstd'
declare -rg CFG_VERSION='1.5.7-kernel'
declare -rg CFG_WEBSITE='https://github.com/facebook/zstd'
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
declare -rg CFG_CMAKE_SRC_DIR='build/cmake/'
declare -rga CFG_CMAKE_CONFIGURE_OPTS=(
  "-DZSTD_BUILD_STATIC=$([[ "$BKIND" = "${BUILD_KINDS[0]}" ]] && echo ON || echo OFF)"
  "-DZSTD_BUILD_SHARED=$([[ "$BKIND" = "${BUILD_KINDS[1]}" ]] && echo ON || echo OFF)"
  '-DZSTD_BUILD_PROGRAMS=OFF'
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
  return
}
function cfg_custom_build() {
  return
}

#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='jasper'
declare -rg CFG_VERSION='4.2.9'
declare -rg CFG_WEBSITE='https://www.ece.uvic.ca/~mdadams/jasper/'
declare -rg CFG_BUILD_SYSTEM='cmake'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'jpeg' #
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
  "-DJAS_STDC_VERSION=$(
    "$CC" -dM -E - < /dev/null \
    | grep __STDC_VERSION__ \
    | sed 's/^\([^ ]\+ \)\{2\}//;'
  )"
  "-DJAS_ENABLE_SHARED=$(
    [[ "$BKIND" = 'shared' ]] && echo ON || echo OFF
  )"
  '-DJAS_ENABLE_LIBJPEG=ON'
  '-DJAS_ENABLE_OPENGL=OFF'
  '-DJAS_ENABLE_AUTOMATIC_DEPENDENCIES=OFF'
  '-DJAS_ENABLE_DOC=OFF'
  '-DJAS_ENABLE_PROGRAMS=OFF'
  '-DJAS_ENABLE_MULTITHREADING_SUPPORT=OFF'
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

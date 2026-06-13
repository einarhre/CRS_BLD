#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='pthreads'
declare -rg CFG_VERSION='POSIX 1003.1-2001'
declare -rg CFG_WEBSITE='https://en.wikipedia.org/wiki/POSIX_Threads'
declare -rg CFG_BUILD_SYSTEM='custom'
declare -rg CFG_NO_ARCHIVE=1
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
  mkdir -p -- "$PKG_INS/lib/pkgconfig"

  local pthread_libdir="$(
    dirname "$("$TRG-gcc" -print-file-name=libpthread.a)"
  )"
  cat > "$PKG_INS/lib/pkgconfig/pthreads.pc" <<EOD
prefix=$PKG_INS
exec_prefix=\${prefix}
libdir=$pthread_libdir
includedir=\${prefix}/include

Name: pthreads
Version: $CFG_VERSION
Description: POSIX Threads

Libs: -L\${libdir} -lpthread
Cflags:
EOD
}

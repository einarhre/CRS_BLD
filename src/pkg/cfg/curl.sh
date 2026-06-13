#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='curl'
declare -rg CFG_VERSION='8.20.0'
declare -rg CFG_WEBSITE='https://curl.haxx.se/libcurl/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'brotli' #
  'libidn2' #
  'libpsl' #
  'libssh2' #
  'nghttp2' #
  'pthreads' #
  'zstd' #
)

# Additional compiler dependencies
declare -rga CFG_CPPFLAGS=(
  "$(pkg-config libnghttp2 --cflags)"
)
declare -rga CFG_CFLAGS=(
)
declare -rga CFG_CXXFLAGS=(
)
declare -rga CFG_LDFLAGS=(
)
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_LIBS=(
    "$(pkg-config --static --libs libpsl libbrotlidec pthreads)"
    '-lnetio'
  )
else
  declare -rga CFG_LIBS=(
    "$(pkg-config --libs libpsl libbrotlidec pthreads)"
    '-lnetio'
  )
fi

# Configuration options
# Autotools
declare -rg CFG_CUSTOM_CONFIGURE=''
declare -rg CFG_CUSTOM_BUILD=''
declare -rg CFG_CUSTOM_INSTALL=''
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
  '--with-schannel'
  '--with-libidn2'
  '--with-libssh2'
  '--with-nghttp2'
  '--with-zstd'
  '--with-brotli'
  '--enable-sspi'
  '--enable-ipv6'
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

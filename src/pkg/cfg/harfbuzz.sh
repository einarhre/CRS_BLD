#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='harfbuzz'
declare -rg CFG_VERSION='14.2.0'
declare -rg CFG_WEBSITE='https://wiki.freedesktop.org/www/Software/HarfBuzz/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'brotli' #
  'cairo' #
  'freetype-bootstrap' #
  'glib' #
  'icu' #
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
declare -rga CFG_MESON_OPTS=(
  '-Dchafa=disabled'
  '-Dbenchmark=disabled'
  '-Dtests=disabled'
  '-Ddocs=disabled'
  '-Dintrospection=disabled'
)
declare -rga CFG_MESON_ENV=(
)

# Hooks
function cfg_post_extract() {
  return
}
function cfg_post_configure() {
  # mman-win32 is only a partial implementation.
  [[ -f "$PKG_BLD/config.h" ]] && sed -i '/HAVE_SYS_MMAN_H/d' "$PKG_BLD/config.h"
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

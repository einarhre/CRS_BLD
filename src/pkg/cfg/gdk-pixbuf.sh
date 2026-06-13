#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='gdk-pixbuf'
declare -rg CFG_VERSION='2.44.6'
declare -rg CFG_WEBSITE='https://gtk.org/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'glib' #
  'jasper' #
  'jpeg' #
  'libiconv' #
  'libpng' #
  'tiff' #
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
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_MESON_OPTS=(
    '-Dinstalled_tests=false'
    '-Dintrospection=disabled'
    '-Dman=false'
    '-Dbuiltin_loaders=all'
)
else
  declare -rga CFG_MESON_OPTS=(
    '-Dinstalled_tests=false'
    '-Dintrospection=disabled'
    '-Dman=false'
)
fi
declare -rga CFG_MESON_ENV=(
  "LDFLAGS=$(pkg-config --libs libjpeg libpng libtiff-4)"
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

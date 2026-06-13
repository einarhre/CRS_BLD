#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='gtk+'
declare -rg CFG_VERSION='3.24.43'
declare -rg CFG_WEBSITE='https://gtk.org/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'atk' #
  'cairo' #
  'gdk-pixbuf' #
  'gettext' #
  'glib' #
  'jasper' #
  'jpeg' #
  'libepoxy' #
  'libpng' #
  'pango' #
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
declare -rga CFG_MESON_OPTS=(
  '-Dtests=false'
  '-Dexamples=false'
  '-Ddemos=false'
  '-Dinstalled_tests=false'
  '-Dbuiltin_immodules=yes'
  '-Dc_link_args=-lstdc++'
  '-Dintrospection=false'
)
declare -rga CFG_MESON_ENV=(
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

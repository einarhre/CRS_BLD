#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='pango'
declare -rg CFG_VERSION='1.57.1'
declare -rg CFG_WEBSITE='https://www.pango.org/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'cairo' #
  'fontconfig' #
  'freetype' #
  'glib' #
  'harfbuzz' #
  'fribidi' #
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
# Meson
declare -rga CFG_MESON_OPTS=(
  '-Dintrospection=disabled'
  '-Dfreetype=enabled'
  '-Dfontconfig=enabled'
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

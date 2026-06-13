#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='atk'
declare -rg CFG_VERSION='2.36.0'
declare -rg CFG_WEBSITE='https://gtk.org/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'glib' #
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
  '-lz'
)

# Configuration options
declare -rga CFG_MESON_OPTS=(
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

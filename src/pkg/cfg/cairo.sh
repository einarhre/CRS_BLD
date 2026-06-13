#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='cairo'
declare -rg CFG_VERSION='1.18.4'
declare -rg CFG_WEBSITE='https://cairographics.org/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'fontconfig' #
  'freetype-bootstrap' #
  'glib' #
  'libpng' #
  'lzo' #
  'pixman' #
  'zlib' #
)

# Additional compiler dependencies
declare -rga CFG_CPPFLAGS=(
)
declare -rga CFG_CFLAGS=(
  '-Wno-incompatible-pointer-types'
)
declare -rga CFG_CXXFLAGS=(
)
declare -rga CFG_LDFLAGS=(
)
declare -rga CFG_LIBS=(
)

# Configuration options
declare -rga CFG_MESON_OPTS=(
  '-Dgtk_doc=false'
  '-Dtests=disabled'
  '-Dxcb=disabled'
  '-Dxlib=disabled'
  '-Dxlib-xcb=disabled'
  '-Dquartz=disabled'
  '-Dpng=enabled'
  '-Dfontconfig=enabled'
  '-Dfreetype=enabled'
  '-Dglib=enabled'
)
declare -rga CFG_MESON_ENV=(
)

# Hooks
function cfg_post_extract() {
  return
}
function cfg_post_configure() {
  if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
  then
    echo '#define CAIRO_WIN32_STATIC_BUILD 1' >> "$PKG_BLD/src/cairo-features.h"
  fi
}
function cfg_post_build() {
  return
}
function cfg_post_install() {
  if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
  then
    for pc in "$PKG_INS"/lib/pkgconfig/cairo.pc "$PKG_INS"/lib64/pkgconfig/cairo.pc
    do
      [[ -f "$pc" ]] || continue
      grep -q 'CAIRO_STATIC_BUILD' "$pc" || \
        sed -i 's/^Cflags: \(.*\)$/Cflags: \1 -DCAIRO_STATIC_BUILD -DCAIRO_WIN32_STATIC_BUILD/' "$pc"
    done
  fi
}
function cfg_custom_build() {
  return
}

#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='libgsf'
declare -rg CFG_VERSION='1.14.58'
declare -rg CFG_WEBSITE='https://developer.gnome.org/gsf/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'bzip2' #
  'glib' #
  'libxml2' #
  'zlib' #
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
declare -rg CFG_CUSTOM_CONFIGURE=''
declare -rg CFG_CUSTOM_BUILD='yes'
declare -rg CFG_CUSTOM_INSTALL='yes'
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
declare -rga CFG_CONFIGURE_OPTS=(
  '--disable-nls'
  '--disable-gtk-doc'
  '--without-python'
  '--with-zlib'
  '--with-bz2'
  '--with-gio'
)
declare -rga CFG_CONFIGURE_ENV=(
)
declare -rga CFG_MAKE_BUILD_OPTS=(
)
declare -rga CFG_MAKE_INSTALL_OPTS=(
  'bin_PROGRAMS='
  'sbin_PROGRAMS='
  'noinst_PROGRAMS='
)

# Hooks
function cfg_post_extract() {
  sed -i 's,^\(Requires:.*\),\1 gio-2.0,'    "$PKG_SRC/libgsf-1.pc.in"
  printf '%s\n' 'Libs.private: -lz -lbz2' >> "$PKG_SRC/libgsf-1.pc.in"
  sed -i 's,\ssed\s, sed ,g'              "$PKG_SRC/gsf/Makefile.in"
}
function cfg_post_configure() {
  return
}
function cfg_post_build() {
  make -C "$PKG_BLD" -j "$NJOBS" install-pkgconfigDATA && \
    make -C "$PKG_BLD/gsf" -j "$NJOBS" install "${CFG_MAKE_INSTALL_OPTS[@]}" || \
      comp_fail "failed building/installing for $CFG"
}
function cfg_post_install() {
  rm -f -- "$PKG_INS/lib/pkgconfig/libgsf-win32-1.pc"
}
function cfg_custom_build() {
  return
}

#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='freetype'
declare -rg CFG_VERSION='2.14.3'
declare -rg CFG_WEBSITE='https://www.freetype.org/'
declare -rg CFG_BUILD_SYSTEM='autotools'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'brotli' #
  'bzip2' #
  'harfbuzz' #
  'libpng' #
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
declare -rg CFG_CUSTOM_BUILD=''
declare -rg CFG_CUSTOM_INSTALL=''
declare -rga CFG_AUTOTOOLS_BOOTSTRAP=(
)
declare -rg CFG_CONFIGURE_SH='configure'
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_CONFIGURE_OPTS=(
    '--with-harfbuzz=yes'
    '--enable-freetype-config'
    "LIBPNG_CFLAGS=$(pkg-config libpng --cflags)"
    "LIBPNG_LDFLAGS=$(pkg-config --static --libs libpng)"
    "FT2_EXTRA_LIBS=$(pkg-config --static --libs libpng)"
    "HARFBUZZ_LIBS=$(pkg-config --static --libs harfbuzz)"
  )
elif [[ "$BKIND" = "${BUILD_KINDS[1]}" ]]
then
  declare -rga CFG_CONFIGURE_OPTS=(
    '--with-harfbuzz=yes'
    '--enable-freetype-config'
    "LIBPNG_CFLAGS=$(pkg-config libpng --cflags)"
    "LIBPNG_LDFLAGS=$(pkg-config libpng --libs)"
    "FT2_EXTRA_LIBS=$(pkg-config libpng --libs)"
  )
else
  declare -rga CFG_CONFIGURE_OPTS=(
  )
fi

declare -rga CFG_CONFIGURE_ENV=(
  GNUMAKE=make
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

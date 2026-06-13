#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='openssl'
declare -rg CFG_VERSION='4.0.0'
declare -rg CFG_WEBSITE='https://www.openssl.org/'
declare -rg CFG_BUILD_SYSTEM='custom'  # autotools, meson, cmake, or custom
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'zlib'
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
declare -rg CFG_CONFIGURE_SH='configure'
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_CONFIGURE_OPTS=(
    "mingw$([[ "$TRG" = "${TARGETS[1]}" ]] && echo 64)"
    "--prefix=$PKG_INS"
    "--libdir=$PKG_INS/lib"
    'zlib'
    'no-capieng'
    'no-tests'
    'no-module'
    'no-shared'
  )
elif [[ "$BKIND" = "${BUILD_KINDS[1]}" ]]
then
  declare -rga CFG_CONFIGURE_OPTS=(
    "mingw$([[ "$TRG" = "${TARGETS[1]}" ]] && echo 64)"
    "--prefix=$PKG_INS"
    "--libdir=$PKG_INS/lib"
    'zlib'
    'no-capieng'
    'no-tests'
    'shared'
  )
fi
declare -rga CFG_CONFIGURE_ENV=(
  "CC=$TRG-gcc"
  "RC=$TRG-windres"
)
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_MAKE_BUILD_OPTS=(
    "CC=$TRG-gcc"
    "RANLIB=$TRG-ranlib"
    "AR=$TRG-ar"
    "RC=$TRG-windres"
    "CROSS_COMPILE=$TRG-"
  )
elif [[ "$BKIND" = "${BUILD_KINDS[1]}" ]]
then
  declare -rga CFG_MAKE_BUILD_OPTS=(
    "CC=$TRG-gcc"
    "RANLIB=$TRG-ranlib"
    "AR=$TRG-ar"
    "RC=$TRG-windres"
    "CROSS_COMPILE=$TRG-"
    "ENGINESDIR=$PKG_INS/bin/engines"
  )
fi
if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
then
  declare -rga CFG_MAKE_INSTALL_OPTS=(
    "CC=$TRG-gcc"
    "RANLIB=$TRG-ranlib"
    "AR=$TRG-ar"
    "RC=$TRG-windres"
    "CROSS_COMPILE=$TRG-"
  )
elif [[ "$BKIND" = "${BUILD_KINDS[1]}" ]]
then
  declare -rga CFG_MAKE_INSTALL_OPTS=(
    "CC=$TRG-gcc"
    "RANLIB=$TRG-ranlib"
    "AR=$TRG-ar"
    "RC=$TRG-windres"
    "CROSS_COMPILE=$TRG-"
    "ENGINESDIR=$PKG_INS/bin/engines"
  )
fi

# Hooks
function cfg_post_extract() {
  # remove previous install
  rm -rfv "$PKG_INS/include/openssl"
  rm -rfv "$PKG_INS/bin/engines"
  rm -fv "$PKG_INS"/*/{libcrypto*,libssl*}
  rm -fv "$PKG_INS/lib/pkgconfig"/{libcrypto*,libssl*,openssl*}
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
  cd -- "$PKG_SRC"

  env "${CFG_CONFIGURE_ENV[@]}" \
    ./Configure "${CFG_CONFIGURE_OPTS[@]}"

  make -j "$NJOBS" "${CFG_MAKE_BUILD_OPTS[@]}" build_sw
  make -j "$NJOBS" "${CFG_MAKE_INSTALL_OPTS[@]}" install_sw
}

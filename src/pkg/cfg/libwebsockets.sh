#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='libwebsockets'
declare -rg CFG_VERSION='4.5.8'
declare -rg CFG_WEBSITE='https://libwebsockets.org/'
declare -rg CFG_BUILD_SYSTEM='cmake'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'openssl' #
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
declare -rg CFG_CMAKE_SRC_DIR=''
declare -rga CFG_CMAKE_CONFIGURE_OPTS=(
  "-DLWS_WITH_STATIC=$([[ "$BKIND" = "${BUILD_KINDS[0]}" ]] && echo ON || echo OFF)"
  "-DLWS_WITH_SHARED=$([[ "$BKIND" = "${BUILD_KINDS[1]}" ]] && echo ON || echo OFF)"
  '-DLWS_WITHOUT_TESTAPPS=ON'
  # MinGW: CMake falsely detects these POSIX functions / old OpenSSL symbol.
  '-DLWS_HAVE_RSA_verify_pss_mgf1=0'
  '-DLWS_HAVE_LOCALTIME_R=0'
  '-DLWS_HAVE_GMTIME_R=0'
)
declare -rga CFG_CMAKE_BUILD_OPTS=(
)
declare -rga CFG_CMAKE_INSTALL_OPTS=(
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
  find "$PKG_INS/lib/pkgconfig" \
    \( -name 'libwebsockets.pc' -o -name 'libwebsockets_static.pc' \) \
    -type f -exec sed -i \
      -e "s|^prefix=.*|prefix=$PKG_INS|" \
      -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
      -e 's|^libdir=.*|libdir=${exec_prefix}/lib|' \
      -e 's|^includedir=.*|includedir=${prefix}/include|' \
      {} +
  if [[ "$BKIND" = "${BUILD_KINDS[0]}" ]]
  then
    sed -i \
      -e 's|-lwebsockets|-lwebsockets_static|g' \
      -e 's|-l:libwebsockets\.a|-lwebsockets_static|g' \
      -e 's|-l:libwebsockets_static\.a|-lwebsockets_static|g' \
      "$PKG_INS/lib/pkgconfig/libwebsockets.pc" \
      "$PKG_INS/lib/pkgconfig/libwebsockets_static.pc"
    local -r SSL_LIBS="$(
      PKG_CONFIG_LIBDIR="$PKG_INS/lib/pkgconfig:$PKG_INS/lib64/pkgconfig:$PKG_INS/share/pkgconfig" \
      PKG_CONFIG_PATH="" \
      pkg-config --static --libs openssl zlib | \
      sed "s#-L$PKG_INS/lib\\b#-L\${libdir}#g"
    )"
    for pcfile in \
      "$PKG_INS/lib/pkgconfig/libwebsockets.pc" \
      "$PKG_INS/lib/pkgconfig/libwebsockets_static.pc"
    do
      if grep -q '^Libs.private:' "$pcfile"
      then
        sed -i \
          -e "s|^Libs.private:.*|Libs.private: $SSL_LIBS -lws2_32 -lcrypt32 -lbcrypt -ladvapi32|" \
          "$pcfile"
      else
        printf '\nLibs.private: %s -lws2_32 -lcrypt32 -lbcrypt -ladvapi32\n' \
          "$SSL_LIBS" >> "$pcfile"
      fi
    done
  else
    rm -f -- "$PKG_INS/lib/pkgconfig/libwebsockets_static.pc"
  fi
}
function cfg_custom_build() {
  return
}

#!/usr/bin/env bash
# shellcheck shell=bash

# Mandatory variables
declare -rg CFG_PKG_NAME='glib'
declare -rg CFG_VERSION='2.88.1'
declare -rg CFG_WEBSITE='https://gtk.org/'
declare -rg CFG_BUILD_SYSTEM='meson'
declare -rga CFG_BUILD_KINDS=(
  'static'
  'shared'
)

# Dependencies
declare -rga CFG_DEPS=(
  'gettext' #
  'libffi' #
  'libiconv' #
  'pcre2' #
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
declare -rga CFG_MESON_OPTS=(
  '-Dtests=false'
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
  for pc in \
    "$PKG_INS/lib/pkgconfig/gio-2.0.pc" \
    "$PKG_INS/lib64/pkgconfig/gio-2.0.pc" \
    "$PKG_INS/lib/pkgconfig/glib-2.0.pc" \
    "$PKG_INS/lib64/pkgconfig/glib-2.0.pc"
  do
    [[ -f "$pc" ]] || continue
    for tool in \
      glib-compile-resources \
      glib-compile-schemas \
      gdbus-codegen \
      glib-genmarshal \
      glib-mkenums
    do
      if command -v "$tool" >/dev/null 2>&1
      then
        case "$tool" in
          glib-compile-resources)
            sed -i "s|^glib_compile_resources=.*|glib_compile_resources=$(command -v "$tool")|" "$pc"
            ;;
          glib-compile-schemas)
            sed -i "s|^glib_compile_schemas=.*|glib_compile_schemas=$(command -v "$tool")|" "$pc"
            ;;
          gdbus-codegen)
            sed -i "s|^gdbus_codegen=.*|gdbus_codegen=$(command -v "$tool")|" "$pc"
            ;;
          glib-genmarshal)
            sed -i "s|^glib_genmarshal=.*|glib_genmarshal=$(command -v "$tool")|" "$pc"
            ;;
          glib-mkenums)
            sed -i "s|^glib_mkenums=.*|glib_mkenums=$(command -v "$tool")|" "$pc"
            ;;
        esac
      fi
    done
  done
}
function cfg_custom_build() {
  return
}

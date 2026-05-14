#!/bin/bash

set -euo pipefail

# Constant initialisation (read only -r)
declare -r PREF="${PREF:-/home/eoh/src/CRS_BLD}"
declare -r SOURCE_DIRECTORY="$PREF/src"
declare -r BUILD_DIRECTORY="$PREF/build"
declare -r INSTALL_DIRECTORY="$PREF/install"

declare -r TRG64="x86_64-w64-mingw32"
declare -r TRG32="i686-w64-mingw32"

declare -r NCRS="${NCRS:-$(nproc --all)}"

# Function definition
function comp_fail() {
  local -r comp="$1"; shift
  echo
  echo " compiling failed: $comp"
  echo
  exit 1
}

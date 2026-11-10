#!/usr/bin/env bash

set -euo pipefail

# Locate the repository independently of the current working directory.
common_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$common_dir/.." && pwd)"
unset common_dir

# Prefer Homebrew's GNU tools when building on macOS.
if [[ "$(uname -s)" == "Darwin" ]]
then
  if ! command -v brew >/dev/null 2>&1
  then
    echo "Homebrew is required to build CRS_BLD on macOS." >&2
    return 1 2>/dev/null || exit 1
  fi

  brew_prefix="$(brew --prefix)"
  export PATH="$brew_prefix/opt/flex/bin:$brew_prefix/opt/bison/bin:$brew_prefix/opt/texinfo/bin:$brew_prefix/opt/zip/bin:$brew_prefix/opt/gpatch/libexec/gnubin:$brew_prefix/opt/libtool/libexec/gnubin:$brew_prefix/opt/gnu-tar/libexec/gnubin:$brew_prefix/opt/make/libexec/gnubin:$brew_prefix/opt/grep/libexec/gnubin:$brew_prefix/opt/gnu-sed/libexec/gnubin:$brew_prefix/opt/findutils/libexec/gnubin:$brew_prefix/opt/coreutils/libexec/gnubin:$brew_prefix/bin:$brew_prefix/sbin:$PATH"
  unset brew_prefix
fi

# Constant initialisation (read only -r)
declare -r PREF="${PREF:-$project_dir}"
unset project_dir

declare -r SOURCE_DIRECTORY="$PREF/src"
declare -r BUILD_DIRECTORY="$PREF/build"
declare -r INSTALL_DIRECTORY="$PREF/install"

if ! PKG_CONFIG_BIN="$(command -v pkg-config)"
then
  echo "pkg-config was not found on PATH." >&2
  return 1 2>/dev/null || exit 1
fi
declare -r PKG_CONFIG_BIN

declare -r TRG32="i686-w64-mingw32"
declare -r TRG64="x86_64-w64-mingw32"
declare -ra TARGETS=("$TRG32" "$TRG64")

declare -r NCRS="${NCRS:-$(nproc --all)}"
if [ "$NCRS" -le 0 ]
then
  echo "No processing units appear to be available for this machine (nproc --all)!"
  exit 1
fi

# Function definition
function comp_fail() {
  local -r COMP="$1"; shift
  echo
  echo " compiling failed: $COMP"
  echo
  exit 1
}

# Diagnostic routines
check_pc_vs_files() {
  local prefix="$1"
  local pc lib flag name

  echo "== $prefix =="

  find "$prefix/lib/pkgconfig" "$prefix/lib64/pkgconfig" "$prefix/share/pkgconfig" \
    -name '*.pc' -type f 2>/dev/null |
  while IFS= read -r pc
  do
    grep -E '^(Libs|Libs.private):' "$pc" |
    grep -oE -- '-l[^ ]+' |
    sed 's/^-l//' |
    while IFS= read -r name
    do
      if ! find "$prefix/lib" "$prefix/lib64" \
        \( -name "lib${name}.a" -o -name "lib${name}.dll.a" \) \
        -type f 2>/dev/null | grep -q .
      then
        echo "MISSING: $pc -> -l$name"
      fi
    done
  done
}

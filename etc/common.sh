#!/usr/bin/env bash

set -euo pipefail

# Validate explicit input before consulting any host tools. Strip zeros as text
# before arithmetic so huge values and octal-looking strings cannot wrap.
_common_ncrs() {
  local value="$1" default="$2" LC_ALL=C
  if [[ ! "$value" =~ ^[0123456789]+$ ]]; then
    echo "NCRS must be an ASCII decimal integer in 1..4096 ($default)." >&2
    return 1
  fi
  value="${value#"${value%%[!0]*}"}"
  if [[ -z "$value" ]]; then
    echo "NCRS must be in 1..4096 ($default)." >&2
    return 1
  fi
  if [[ ${#value} -gt 4 || ( ${#value} -eq 4 && "$value" > 4096 ) ]]; then
    if [[ "$default" == 'nproc --all' ]]; then
      echo 'NCRS default from nproc --all exceeds 4096; clamping to 4096.' >&2
      value=4096
    else
      echo 'NCRS must be in 1..4096 (explicit input).' >&2
      return 1
    fi
  fi
  printf '%s\n' "$value"
}
if [[ ${NCRS+x} ]]; then
  NCRS="$(_common_ncrs "$NCRS" 'explicit input')" || { return 1 2>/dev/null || exit 1; }
fi

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

# Defaults use the GNU nproc selected by the platform PATH setup.
if [[ ! ${NCRS+x} ]]; then
  if ! common_ncrs_default="$(nproc --all)"; then
    echo 'NCRS default: nproc --all failed.' >&2
    return 1 2>/dev/null || exit 1
  fi
  NCRS="$(_common_ncrs "$common_ncrs_default" 'nproc --all')" || { return 1 2>/dev/null || exit 1; }
  unset common_ncrs_default
fi
declare -r NCRS
unset -f _common_ncrs

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

# Function definition
function comp_fail() {
  local -r COMP="$1"; shift
  echo
  echo " compiling failed: $COMP"
  echo
  exit 1
}

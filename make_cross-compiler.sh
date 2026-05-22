#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/etc/common.sh"
unset script_dir

# Constant initialisation
declare -rA DLLS=(["${TRG64}"]="libgcc_s_seh-1.dll" ["${TRG32}"]="libgcc_s_sjlj-1.dll")
declare -r VERSIONS="$(
  find -- "$SOURCE_DIRECTORY/cpl" -maxdepth 1 -name 'gcc-*.tar.gz' -print0 | \
    sed -ze 's#^.*-##' -e 's#\.tar\.gz#, #' | \
    tr -d '\0'
) git"

# Function definitions
function usage() {
  echo 
  echo " usage: $0 gcc-version"
  echo 
  echo " available gcc versions: $VERSIONS"
  echo 
  exit 1
}

# Argument handling
if [[ $# -ne 1 ]]
then
  usage
fi

declare -r GCC_VERSION="$1"; shift

case "$VERSIONS" in
  *"${GCC_VERSION}"*)
    [[ "$GCC_VERSION" =~ [0-9][0-9]\.[0-9]\.[0-9] ]] || [[ "$GCC_VERSION" = "git" ]] || usage
    ;;
  *) usage ;;
esac

# Prepare sources (delete the gcc symbolic link to force re-extracting of sources)
echo -e "\nPrepare sources ..."
if ! readlink -e -- "$SOURCE_DIRECTORY/cpl/gcc" || \
  [[ "$(readlink -- "$SOURCE_DIRECTORY/cpl/gcc")" != *"$GCC_VERSION" ]]
then
  # mingw-w64
  echo -e "\n mingw-w64..."
  # First remove source directories
  for d in "$SOURCE_DIRECTORY"/cpl/mingw-w64-v*
  do
    [[ -d "$d" ]] || continue
    rm -rf -- "$d"
  done
  unset d
  rm -f -- "$SOURCE_DIRECTORY/cpl/mingw-w64" # and the link.
  # Select the newest/highest version tar file to explode.
  declare -r MINGW_FN="$(
    find "$SOURCE_DIRECTORY/cpl" \
      -maxdepth 1 \
      -type f \
      -name 'mingw-w64-v*.tar.*' | \
      sort -V | \
      tail -n 1
  )"
  mkdir -- "${MINGW_FN%%.tar.*}"
  if ! tar --strip-components=1 --directory="${MINGW_FN%%.tar.*}" \
    -xaf "$MINGW_FN"
  then
    echo "Unable to extract sources from archive $MINGW_FN" >&2
    exit 1
  fi
  # and cretae a new link.
  ln -sf -- "$(basename "${MINGW_FN%%.tar.*}")" "$SOURCE_DIRECTORY/cpl/mingw-w64"

  # binutils
  echo -e "\n binutils..."
  # First remove source directories
  for d in "$SOURCE_DIRECTORY"/cpl/binutils-*
  do
    [[ -d "$d" ]] || continue
    rm -rf -- "$d"
  done
  unset d
  rm -f -- "$SOURCE_DIRECTORY/cpl/binutils" # and the link.
  # Select the newest/highest version tar file to explode.
  declare -r BINUTILS_FN="$(
    find "$SOURCE_DIRECTORY/cpl" \
      -maxdepth 1 \
      -type f \
      -name 'binutils-*.tar.*' \
      | sort -V \
      | tail -n 1
  )"
  mkdir -- "${BINUTILS_FN%%.tar.*}"
  if ! tar --strip-components=1 --directory="${BINUTILS_FN%%.tar.*}" \
    -xaf "$BINUTILS_FN"
  then
    echo "Unable to extract sources from archive $BINUTILS_FN" >&2
    exit 1
  fi
  # and create a new link.
  ln -sf -- "$(basename "${BINUTILS_FN%%.tar.*}")" "$SOURCE_DIRECTORY/cpl/binutils"

  # Change gcc version
  echo -e "\n gcc..."
  if [[ "$GCC_VERSION" != "git" ]]
  then
    # First remove source directories
    for d in "$SOURCE_DIRECTORY"/cpl/gcc-*
    do
      [[ -d "$d" ]] || continue
      rm -rf -- "$d"
    done
    unset d
    rm -f -- "$SOURCE_DIRECTORY/cpl/gcc" # and the link.
    # Explode the source tar file.
    mapfile -d '' -t gcc_src_files < <(
      find "$SOURCE_DIRECTORY/cpl" \
        -maxdepth 1 \
        -name "gcc-${GCC_VERSION}.tar.*" \
        -type f \
        -print0
    )
    case "${#gcc_src_files[@]}" in
    1)
      declare -r GCC_FN="${gcc_src_files[0]}"
      ;;
    *)
      echo "Multiple gcc archives found for version ${GCC_VERSION}:" >&2
      printf '  %s\n' "${gcc_src_files[@]}" >&2
      exit 1
      ;;
    esac
    unset gcc_src_files
    mkdir -- "$SOURCE_DIRECTORY/cpl/gcc-$GCC_VERSION"
    if ! tar --strip-components=1 --directory="$SOURCE_DIRECTORY/cpl/gcc-$GCC_VERSION" \
      -xaf "$GCC_FN"
    then
      echo "Unable to extract sources from archive $GCC_FN" >&2
      exit 1
    fi
  else
    # Update the git repository.
    if ! git -C "$SOURCE_DIRECTORY/cpl/gcc-$GCC_VERSION" pull
    then
      echo "Unable to pull in chnages from git repository gcc-$GCC_VERSION" >&2
      exit 1
    fi
  fi
  # and create a new link.
  ln -sf -- "gcc-$GCC_VERSION" "$SOURCE_DIRECTORY/cpl/gcc"
  cd -- "$SOURCE_DIRECTORY/cpl/gcc"
    contrib/download_prerequisites --force
  cd -- "$PREF"

  ## Clean previous build
  echo -e "\nClean previous build..."
  rm -rf -- "$BUILD_DIRECTORY"/{cross,native}
  rm -rf -- "$INSTALL_DIRECTORY"/{cross,native}
  mkdir -p -- "$BUILD_DIRECTORY"/{cross,native}/{"$TRG32","$TRG64"}/{binutils,gcc,mingw-w64}
  mkdir -p -- "$BUILD_DIRECTORY"/cross/{"$TRG32","$TRG64"}/mingw-w64-headers
  mkdir -p -- "$INSTALL_DIRECTORY"/{cross,native}/{"$TRG32","$TRG64"}
fi

## Build
echo -e "\nBuilding..."

# Function for building target TRG, using NJOBS parallell processes when making
function build_target() {
  [[ $# -eq 2 ]] || return
  local -r TRG="$1"; local -r NJOBS="$2"; shift 2

  # 1. Start with cross-binutils, the first component of the cross-compiler
  echo -e "\n Start with cross-binutils, the first component of the cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/binutils"
  [[ -f config.log ]] || \
    ../../../../src/cpl/binutils/configure \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG" \
    --target="$TRG" \
    --disable-multilib
  make -j "$NJOBS" && make install || comp_fail "cross binutils"
  # ...and make sure these are found on PATH
  local -r PATH="$INSTALL_DIRECTORY/cross/$TRG/bin:$PATH"

  # 2. Install the mingw-w64 headers into the target (Windows) sysroot of the cross-compiler
  echo -e "\n Install the mingw-w64 headers into the target (Windows) sysroot of the cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/mingw-w64-headers"
  [[ -f config.log ]] || \
    ../../../../src/cpl/mingw-w64/mingw-w64-headers/configure \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG/$TRG" \
    --host="$TRG"
  make install || comp_fail "host mingw-w64-headers"

  # 3. With the target headers installed, build the core gcc cross-compiler
  echo -e "\n With the target headers installed, build the core gcc cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/gcc"
  [[ -f config.log ]] || \
    ../../../../src/cpl/gcc/configure \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG" \
    --target="$TRG" \
    --disable-multilib \
    --enable-languages=c,c++,fortran
  make -j "$NJOBS" all-gcc && make install-gcc || comp_fail "cross all-gcc"

  # 4. Build mingw-w64 CRT and install into cross-compiler sysroot
  echo -e "\n Build mingw-w64 CRT and install into cross-compiler sysroot..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/mingw-w64"
  [[ -f config.log ]] || \
    ../../../../src/cpl/mingw-w64/configure \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG/$TRG" \
    --host="$TRG"
  make && make install || comp_fail "host mingw-w64"

  # 5. Finish building the gcc cross-compiler
  echo -e "\n Finish building the gcc cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/gcc"
  make -j "$NJOBS" && make install || comp_fail "cross gcc"

  # 6. Build winpthreads and install into cross-compiler sysroot
  echo -e "\n Build winpthreads and install into cross-compiler sysroot..."
  mkdir -p -- "$BUILD_DIRECTORY/cross/$TRG/winpthreads"
  cd -- "$BUILD_DIRECTORY/cross/$TRG/winpthreads"
  [[ -f config.log ]] || \
    ../../../../src/cpl/mingw-w64/mingw-w64-libraries/winpthreads/configure \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG/$TRG" \
    --host="$TRG" \
    --libdir="$INSTALL_DIRECTORY/cross/$TRG/$TRG/lib"
  make -j "$NJOBS" && make install || comp_fail "cross winpthreads"

  # 7. Build Windows-native binutils
  echo -e "\n Build Windows-native binutils..."
  cd -- "$BUILD_DIRECTORY/native/$TRG/binutils"
  [[ -f config.log ]] || \
    ../../../../src/cpl/binutils/configure \
    --prefix="$INSTALL_DIRECTORY/native/$TRG" \
    --host="$TRG" \
    --target="$TRG" \
    --disable-multilib
  make -j "$NJOBS" && make install || comp_fail "host binutils"

  # 8. Build Windows-native gcc
  echo -e "\n Build Windows-native gcc..."
  cd -- "$BUILD_DIRECTORY/native/$TRG/gcc"
  [[ -f config.log ]] || \
    ../../../../src/cpl/gcc/configure \
    --prefix="$INSTALL_DIRECTORY/native/$TRG" \
    --host="$TRG" \
    --target="$TRG" \
    --disable-multilib \
    --enable-languages=c,c++,fortran
  make -j "$NJOBS" && make install || comp_fail "host gcc"
  local -r DLL="$(
    find -- "$INSTALL_DIRECTORY/native/$TRG" -name "${DLLS["$TRG"]}" -type f | head -n 1
  )"
  [[ -n "$DLL" ]] || comp_fail "missing ${DLLS[$TRG]}"
  mv -- "$DLL" "$INSTALL_DIRECTORY/native/$TRG/bin/"

  # 9. Build mingw-w64 headers and libs (including winpthreads) and install into native toolchain sysroot
  echo -e "\n Build mingw-w64 headers and libs (including winpthreads) and install into native toolchain sysroot..."
  cd -- "$BUILD_DIRECTORY/native/$TRG/mingw-w64"
  [[ -f config.log ]] || \
    ../../../../src/cpl/mingw-w64/configure \
    --prefix="$INSTALL_DIRECTORY/native/$TRG/$TRG" \
    --host="$TRG" \
    --with-libraries=winpthreads
  make && make install || comp_fail "host mingw-w64"

  # 10. Package the native installation folder
  echo -e "\n Package the native installation folder..."
  cd -- "$INSTALL_DIRECTORY/native"
  zip --filesync --recurse-paths "$TRG" "$TRG"
}

# Make everything
for trgs in "${TARGETS[@]}"
do
  build_target "$trgs" "$NCRS"
done

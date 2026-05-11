#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Constant initialisation
declare -rA DLLS=([${TRG64}]="libgcc_s_seh-1.dll" [${TRG32}]="libgcc_s_sjlj-1.dll")
declare -r VERSIONS="$(ls -m $SOURCE_DIRECTORY/gcc-*.tar.gz | sed -e 's#^.*-##' -e 's#.tar.gz##' | \
  tr '\n' ' ' | sed -e 's#  *$#,#') git"

# Function definitions
function usage() {
  echo 
  echo " usage: $0 gcc-version"
  echo 
  echo " available gcc versions: $VERSIONS"
  #  | sed -e 's#, $##'
  echo 
  exit 1
}

# Argument handling
if [ $# -ne 1 ]
then
  usage
fi

declare -r GCC_VERSION=$1; shift

case $VERSIONS in
  *${GCC_VERSION}*)
    [[ "$GCC_VERSION" =~ [0-9][0-9]\.[0-9]\.[0-9] ]] || [[ "$GCC_VERSION" =~ "git" ]] || usage
    ;;
  *) usage ;;
esac

## Prepare sources
echo -e "\nPrepare sources ..."
if ! readlink -e $SOURCE_DIRECTORY/gcc || [[ "`readlink $SOURCE_DIRECTORY/gcc`" != *"$GCC_VERSION"* ]]
then
  # mingw-w64
  echo -e "\n mingw-w64..."
  # First remove the
  find $SOURCE_DIRECTORY -name mingw-w64-v\* -type d -exec rm -rf {} \; 2>/dev/null # directory
  rm -f $SOURCE_DIRECTORY/mingw-w64 # and the link.
  # Select the newest/highest version tar file to explode.
  MINGW_FN=$(ls -1r $SOURCE_DIRECTORY/mingw-w64-v*.tar.bz2 | head -n 1)
  if ! tar -C $SOURCE_DIRECTORY -xjf $MINGW_FN
  then
    exit 1
  fi
  # and cretae a new link.
  ln -sf ${MINGW_FN%%.tar.bz2} $SOURCE_DIRECTORY/mingw-w64

  # binutils
  echo -e "\n binutils..."
  # First remove the
  find $SOURCE_DIRECTORY -type d -name binutils-\* -exec rm -rf {} \; 2>/dev/null # directory
  rm -f $SOURCE_DIRECTORY/binutils # and the link.
  # Select the newest/highest version tar file to explode.
  BINUTILS_FN=$(ls -1r $SOURCE_DIRECTORY/binutils-*.tar.bz2 | head -n 1)
  if ! tar -C $SOURCE_DIRECTORY -xjf $BINUTILS_FN
  then
    exit 1
  fi
  # and cretae a new link.
  ln -sf ${BINUTILS_FN%%.tar.bz2} $SOURCE_DIRECTORY/binutils

  # Change gcc version
  echo -e "\n gcc..."
  if [[ "$GCC_VERSION" != "git" ]]
  then
    #rm -rf $(readlink $SOURCE_DIRECTORY/gcc) # don't delete the previous directory I think ...
    # First remove the
    rm -rf $SOURCE_DIRECTORY/gcc-$GCC_VERSION # directory
    rm -f $SOURCE_DIRECTORY/gcc # and the link.
    # Explode the source tar file.
    if !  tar -C $SOURCE_DIRECTORY -xzf $SOURCE_DIRECTORY/gcc-$GCC_VERSION.tar.gz
    then
      exit 1
    fi
  else
    # Update the git repository
    if ! git -C $SOURCE_DIRECTORY/gcc-$GCC_VERSION pull
    then
      exit 1
    fi
  fi
  # and cretae a new link.
  ln -sf gcc-$GCC_VERSION $SOURCE_DIRECTORY/gcc
  cd $SOURCE_DIRECTORY/gcc
    contrib/download_prerequisites --force
  cd $PREF

  ## Clean previous build
  echo -e "\nClean previous build..."
  rm -rf  $BUILD_DIRECTORY
  rm -rf  $INSTALL_DIRECTORY
  mkdir -p $BUILD_DIRECTORY/{cross,native}/{$TRG32,$TRG64}/{binutils,gcc,mingw-w64}
  mkdir -p $BUILD_DIRECTORY/cross/{$TRG32,$TRG64}/mingw-w64-headers
  mkdir -p $INSTALL_DIRECTORY/{cross,native}/{$TRG32,$TRG64}
fi

## Build
echo -e "\nBuilding..."

# Function for building target TRG, using NCR parallell processes when making
function build_target() {
  [[ $# -eq 2 ]] || return
  local -r TRG=$1; local -r NCR=$2; shift 2

  # 1. Start with cross-binutils, the first component of the cross-compiler
  echo -e "\n Start with cross-binutils, the first component of the cross-compiler..."
  cd $BUILD_DIRECTORY/cross/$TRG/binutils
  [[ -f config.log ]] || ../../../../src/binutils/configure --prefix=$INSTALL_DIRECTORY/cross/$TRG --target=$TRG --disable-multilib
  make -j $NCR && make install || comp_fail "cross binutils"
  # ...and make sure these are found on PATH
  local -r PATH=$INSTALL_DIRECTORY/cross/$TRG/bin:$PATH

  # 2. Install the mingw-w64 headers into the target (Windows) sysroot of the cross-compiler
  echo -e "\n Install the mingw-w64 headers into the target (Windows) sysroot of the cross-compiler..."
  cd $BUILD_DIRECTORY/cross/$TRG/mingw-w64-headers
  [[ -f config.log ]] || ../../../../src/mingw-w64/mingw-w64-headers/configure --host=$TRG --prefix=$INSTALL_DIRECTORY/cross/$TRG/$TRG
  make install || comp_fail "host mingw-w64-headers"

  # 3. With the target headers installed, build the core gcc cross-compiler
  echo -e "\n With the target headers installed, build the core gcc cross-compiler..."
  cd $BUILD_DIRECTORY/cross/$TRG/gcc
  [[ -f config.log ]] || ../../../../src/gcc/configure --prefix=$INSTALL_DIRECTORY/cross/$TRG --target=$TRG --disable-multilib --enable-languages=c,c++,fortran
  make -j $NCR all-gcc && make install-gcc || comp_fail "cross all-gcc"

  # 4. Build mingw-w64 CRT and install into cross-compiler sysroot
  echo -e "\n Build mingw-w64 CRT and install into cross-compiler sysroot..."
  cd $BUILD_DIRECTORY/cross/$TRG/mingw-w64
  [[ -f config.log ]] || ../../../../src/mingw-w64/configure --host=$TRG --prefix=$INSTALL_DIRECTORY/cross/$TRG/$TRG
  make && make install || comp_fail "host mingw-w64"

  # 5. Finish building the gcc cross-compiler
  echo -e "\n Finish building the gcc cross-compiler..."
  cd $BUILD_DIRECTORY/cross/$TRG/gcc
  make -j $NCR && make install || comp_fail "cross gcc"

  # 6. Build Windows-native binutils
  echo -e "\n Build Windows-native binutils..."
  cd $BUILD_DIRECTORY/native/$TRG/binutils
  [[ -f config.log ]] || ../../../../src/binutils/configure --prefix=$INSTALL_DIRECTORY/native/$TRG --host=$TRG --target=$TRG --disable-multilib
  make -j $NCR && make install || comp_fail "host binutils"

  # 7. Build Windows-native gcc
  echo -e "\n Build Windows-native gcc..."
  cd $BUILD_DIRECTORY/native/$TRG/gcc
  [[ -f config.log ]] || ../../../../src/gcc/configure --prefix=$INSTALL_DIRECTORY/native/$TRG --host=$TRG --target=$TRG --disable-multilib --enable-languages=c,c++,fortran
  make -j $NCR && make install || comp_fail "host gcc"
  mv $INSTALL_DIRECTORY/native/$TRG/lib/${DLLS[$TRG]} $INSTALL_DIRECTORY/native/$TRG/bin/

  # 8. Build mingw-w64 headers and libs (including winpthreads) and install into native toolchain sysroot
  echo -e "\n Build mingw-w64 headers and libs (including winpthreads) and install into native toolchain sysroot..."
  cd $BUILD_DIRECTORY/native/$TRG/mingw-w64
  [[ -f config.log ]] || ../../../../src/mingw-w64/configure --host=$TRG --prefix=$INSTALL_DIRECTORY/native/$TRG/$TRG --with-libraries=winpthreads
  make && make install || comp_fail "host mingw-w64"

  # 8. Package the native installation folder
  echo -e "\n Package the native installation folder..."
  cd $INSTALL_DIRECTORY/native
  zip -r $TRG.zip $TRG
}

# Make everything
#parallel -j 16 -n 2 build_target -- $TRG32 $NCRS $TRG64 $NCRS
for TRGS in $TRG32 $TRG64
do
  #sem -j 16 --wait build_target $TRGS $NCRS
  build_target $TRGS $NCRS
done

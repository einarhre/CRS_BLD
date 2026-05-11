#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Constant initialisation
declare -r PKG_DIR="$SOURCE_DIRECTORY/pkg"
declare -r PKGS=`ls -m $PKG_DIR | sed -e 's#\.tar\.[bglxz2]\+##g' | tr '\n' ' '`
#declare -r NCRS=16

# Function definitions
function usage() {
  echo 
  echo " usage: $0 pkg1 [pkg2...]"
  echo 
  echo " available gcc packages: $PKGS"
  echo 
  exit 1
}

# Deletes the temp directory on exit
declare TEMP_DIR
function cleanup() {
  rm -rf $TEMP_DIR
  echo -e " deleted temporary working directories: $TEMP_DIR\n"
}
trap cleanup EXIT

# Argument handling
if [ $# -lt 1 ]
then
  usage
fi
declare -r PKGS_TO_COMPILE=$1; shift

for PKG in $PKGS_TO_COMPILE
do
  case $PKGS in
    *${PKG}*)
      if [ `ls $PKG_DIR/${PKG}*.tar.* | wc -l` -ne 1 ]
      then
        echo -e "\nPackage not found: $PKG\n"
        usage
      fi
      ;;
    *)
      echo -e "\nPackage not found: $PKG\n"
      usage
      ;;
  esac
done

# Build
function build_pkg() {
  declare -r PKG=$1; declare -r TRG=$2; declare -r NCR=$3; shift 3

  # Find name of archive with and without suffix
  declare -r PKG_TAR=`ls $PKG_DIR/${PKG}*.tar.*`
  if [ ! -f $PKG_TAR ]
  then
    echo -e "\nPackage archive not found for package $PKG\n"
    usage
  fi
  declare -r SPKG=`basename ${PKG_TAR%%.tar.*}`

  # Create temporary build directory
  declare -r TEMP=`mktemp -dq -p $BUILD_DIRECTORY/native/pkg`
  if [ ! -d $TEMP ]
  then
    echo "Could not create temporary directory: $TEMP"
    exit 1
  fi

  # Build on host TRG from archive
  tar -C $TEMP -xaf $PKG_TAR
  mkdir $TEMP/build
  cd $TEMP/build
  declare -r PATH=$INSTALL_DIRECTORY/cross/$TRG/bin:$PATH 
  ../$SPKG/configure --prefix=$INSTALL_DIRECTORY/native/pkg --host=$TRG
  make -j $NCR

  # Collect for deleting the temporary directory on exit
  TEMP_DIR="$TEMP_DIR $TEMP"
}

for PKG in $PKGS_TO_COMPILE
do 
  for TRG in $TRG64 $TRG32
  do
    build_pkg $PKG $TRG $NCRS
  done
done

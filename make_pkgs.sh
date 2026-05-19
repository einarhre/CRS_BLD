#!/bin/bash
set -euo pipefail

# Optional behaviour
declare -r DELETE_PKG_SRC=0 # Delete source directory after compilation (no=0, yes=1)
declare -r DELETE_PKG_BLD=1 # Delete build directory after compilation (no=0, yes=1)
declare -r DELETE_MESON_CONF=0 # Delete meson ini file
declare -r DELETE_CMAKE_CONF=0 # Delete cmake toolchain file
declare -r PARALLEL_LOOP=1  # Parallelise the loop over build kinds (e.g. 32bit, 64bit)
                            # and targets (e.g. i686 mingw, x86_64 mingw) (no=0, yes=1)

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/etc/common.sh"
unset script_dir

# Constant initialisation
declare -ra BUILD_KINDS=([0]="static" [1]="shared")
declare -rA BUILD_KINDS_REV=(
  [${BUILD_KINDS[0]}]=${BUILD_KINDS[1]}
  [${BUILD_KINDS[1]}]=${BUILD_KINDS[0]}
)

# For parallelising the loop
declare -ri PARALLEL_RUNS=$((
  (1 + (${#TARGETS[@]} * ${#BUILD_KINDS[@]} -1) * PARALLEL_LOOP) <= $NCRS ?
  (1 + (${#TARGETS[@]} * ${#BUILD_KINDS[@]} -1) * PARALLEL_LOOP)          :
   $NCRS
)) # Always less than or equal to the number of cores
declare -ri NCRS_PER_RUN=$((
  PARALLEL_LOOP ?
    NCRS / PARALLEL_RUNS :
    NCRS
)) # Always greater than or equal to one, since PARELLEL_RUNS <= NCRS

# Define the directory structure
declare -r PKG_TAR_DIR="$SOURCE_DIRECTORY/pkg/tar"
declare -r PKG_CFG_DIR="$SOURCE_DIRECTORY/pkg/cfg"
declare -r PKG_PTC_DIR="$SOURCE_DIRECTORY/pkg/ptc"
declare -r PKG_BLD_DIR="$BUILD_DIRECTORY/pkg"
declare -r PKG_INS_DIR="$INSTALL_DIRECTORY/pkg"

# Collect the available configurations to compile
declare -a cfgs=()
while IFS= read -r fn
do
  cfgs+=("$(basename "${fn%.sh}")")
done < <(
  find "$PKG_CFG_DIR" -maxdepth 1 -name '*.sh'
)
unset fn

# Function definitions
function usage() {
  echo
  echo " usage: $0 cfg1 [cfg2...]"
  echo
  echo " configuration files must exist in: $PKG_CFG_DIR"
  echo " available gcc configurations: ${cfgs[*]}"
  echo
  exit 1
}

# Deletes temporary dirctories and files on exit
declare -r CLEANUP_LIST="$(mktemp -q)"
function cleanup() {
  local -a paths=()

  if [ -f "$CLEANUP_LIST" ]
  then
    mapfile -d '' -t paths < "$CLEANUP_LIST"
    rm -f -- "$CLEANUP_LIST"
  fi

  if [ "${#paths[@]}" -gt 0 ]
  then
    rm -rf -- "${paths[@]}"
    printf 'deleted the following directories/files: %s\n\n' "${paths[*]}"
  fi
}
trap cleanup EXIT

# Argument handling
if [ $# -lt 1 ]
then
  usage
fi
declare -ra CFG_ORDER=("$@"); shift $#

# Check that all configuration files can be uniquely determined
for cfg in "${CFG_ORDER[@]}"
do
  declare -i found=0
  for cfg_full in "${cfgs[@]}"
  do
    if [ "$cfg_full" = "${cfg}" ]
    then
      ! ((found++)) # "!" is a hack to have "set -e" option ignore the exit status of ((
      if [ $found -gt 1 ]
      then
        echo "Configuration not unique: $cfg"
        echo
        usage
      fi
    fi
  done
  if [ $found -lt 1 ]
  then
    echo "Configuration not found: $cfg"
    echo
    usage
  fi
done
unset cfg found cfg_full cfgs

# Helper functions
function setup_gtk_env() {
  local -r PREFIX="$1"; shift

  export GLIB_COMPILE_RESOURCES="$(command -v glib-compile-resources)"
  export GLIB_COMPILE_SCHEMAS="$(command -v glib-compile-schemas)"
  export GLIB_GENMARSHAL="$(command -v glib-genmarshal)"
  export GLIB_MKENUMS="$(command -v glib-mkenums)"

  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
  export PANGO_CFLAGS="$(pkg-config --cflags pangocairo pangoft2 pangowin32)"

  export PANGO_LIBS="-L$PREFIX/lib -L$PREFIX/lib64 \
    -Wl,--start-group \
    -lpangocairo-1.0 -lpangowin32-1.0 -lpango-1.0 \
    -lgio-2.0 -lgobject-2.0 -lgmodule-2.0 -lglib-2.0 \
    -lharfbuzz -lfribidi -lcairo -lfontconfig -lfreetype \
    -lpng16 -lpixman-1 -lz -lexpat \
    -lffi -lpcre2-8 -lintl -latomic \
    -lws2_32 -lwinmm -lshlwapi -ldnsapi -liphlpapi \
    -lgdi32 -lmsimg32 -ldwrite \
    -Wl,--end-group"

  export CFLAGS="$CFLAGS -DATK_STATIC_COMPILATION -DCAIRO_STATIC_BUILD -DCAIRO_WIN32_STATIC_BUILD"
  export CXXFLAGS="$CXXFLAGS -DATK_STATIC_COMPILATION -DCAIRO_STATIC_BUILD -DCAIRO_WIN32_STATIC_BUILD"
  export LIBS="-Wl,--allow-multiple-definition $PANGO_LIBS -lkernel32 -luser32 -lshell32 -lole32 -loleaut32 -luuid -lcomdlg32 -ladvapi32"
}

function patch_gtk_3_24_32() {
  local -r PKG_SRC="$1"; shift

  sed -i \
    's/gtk_widget_queue_resize (label);/gtk_widget_queue_resize (GTK_WIDGET (label));/' \
    "$PKG_SRC/gtk/gtklabel.c"

  sed -i \
    's/gdouble _gtk_get_slowdown ();/gdouble _gtk_get_slowdown (gdouble factor);/' \
    "$PKG_SRC/gtk/gtkprivate.h"

  sed -i \
    's/_gtk_get_slowdown ()/_gtk_get_slowdown (1.0)/g' \
    "$PKG_SRC/gtk/inspector/visual.c"

  sed -i \
    's/CreateDialogIndirectW (NULL, template, hwndOwner, measure_dialog_procedure)/CreateDialogIndirectW (NULL, (LPCDLGTEMPLATEW) template, hwndOwner, measure_dialog_procedure)/' \
    "$PKG_SRC/gtk/gtkprintoperation-win32.c"

  sed -i \
    's/page\.pResource = template;/page.pResource = (LPCDLGTEMPLATEW) template;/' \
    "$PKG_SRC/gtk/gtkprintoperation-win32.c"

  sed -i '1s|^.*$|#!/usr/bin/env python3|' \
    "$PKG_SRC/gtk/generate-uac-manifest.py"
  chmod +x "$PKG_SRC/gtk/generate-uac-manifest.py"

  perl -0pi -e 's/static int check_dir_mtime\s*\(\s*const char\s*\*dir,\s*const GStatBuf\s*\*sb,\s*int\s*tf\s*\)/static int check_dir_mtime (const char *dir, const struct stat *sb, int tf)/s' \
    "$PKG_SRC/gtk/updateiconcache.c"

  # Patch for tests
  sed -i \
  's/gdk_event_get_source_device (event)/gdk_event_get_source_device ((GdkEvent *) event)/g' \
  "$PKG_SRC/tests/testinput.c"

  find "$PKG_SRC" -name Makefile.[ai][mn] -exec \
    sed -i \
    's%^\([ \t]*\)\(test -n .*update_icon_cache.*\)$%\1#\2%' {} \;
}

# Apply patch
function apply_patch_file() {
  local -r PTC="$1"; local -r PKG_SRC="$2"; shift 2
  local -r PATCH_HISTORY="$PKG_SRC/.patches_applied"

  if [ -f $PKG_SRC/.patches_applied ] && \
     [ $(grep -F -m 1 -c -e "$PTC" -- $PATCH_HISTORY) -ge 1 ]
  then
    echo "Patch has already been applied: $PTC"
  else
    echo "Applying patch: $PTC"
    patch -d "$PKG_SRC" -p1 < "$PTC"
    echo "$PTC" >> "$PATCH_HISTORY"
  fi
}


function load_pkg_config() {
  local -r CFG="$1"; shift

  local -r CFG_FILE="$PKG_CFG_DIR/${CFG}.sh"

  if [ -z "$CFG" ] || [ ! -f "$CFG_FILE" ]
  then
    echo "This is strange, the configuration file does not exist: $CFG_FILE"
    exit 1
  fi

  echo "Loading configuration: $CFG"
  source "$CFG_FILE"
}

# Run a hook
run_hook() {
  local -r HOOK="$1"; shift

  if declare -F "$HOOK" >/dev/null
  then
    "$HOOK"
  fi
}

# Build in a subshell (isolated environment for each build)
function process_cfg() (
  local -r CFG="$1"; local -r BKIND=$2; local -r TRG="$3"; local -r NJOBS=$4; shift 4

  # Gera loggið læsilegra
  if [ -n "${PARALLEL_LOOP:-}" ] && [ "$PARALLEL_LOOP" -ne 0 ]
  then
    exec > >(sed "s/^/[$CFG:$TRG:$BKIND] /")
    exec 2>&1
  fi

  # Build, patch and install directories
  local -r PKG_SRC="$PKG_BLD_DIR/$TRG/$BKIND/src/$CFG"
  local -r PKG_BLD="$PKG_BLD_DIR/$TRG/$BKIND/build/$CFG"
  local -r PKG_INS="$PKG_INS_DIR/$TRG/$BKIND"
  mkdir -p -- "$PKG_SRC" "$PKG_BLD" "$PKG_INS"

  local -r BIN="$INSTALL_DIRECTORY/cross/$TRG/bin"
  export PATH="$BIN:$PATH"
  export CC="$TRG-gcc"
  export CXX="$TRG-g++"
  export AR="$TRG-ar"
  export RANLIB="$TRG-ranlib"
  export STRIP="$TRG-strip"
  export WINDRES="$TRG-windres"

  export PKG_CONFIG_LIBDIR="$PKG_INS/lib/pkgconfig:$PKG_INS/lib64/pkgconfig:$PKG_INS/share/pkgconfig"
  export PKG_CONFIG_PATH=

  # Define variables for the meson ini file
  local cpu_family=''
  local cpu=''
  case "$TRG" in
  x86_64-*)
    cpu_family="x86_64"
    cpu="x86_64"
    ;;
  i686-*)
    cpu_family="x86"
    cpu="i686"
    ;;
  esac

  local -r MESON_CROSS_FILE="$PKG_BLD_DIR/$TRG/meson-$TRG.ini"
  if [ ! -f $MESON_CROSS_FILE -o $MESON_CROSS_FILE -ot $INSTALL_DIRECTORY/cross/$TRG ]
  then
    cat > "$MESON_CROSS_FILE" <<EOD
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
windres = '$WINDRES'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOD
  fi
  unset cpu

  local -r CMAKE_TOOLCHAIN_FILE="$PKG_BLD_DIR/$TRG/toolchain-$TRG.cmake"
  if [ ! -f $CMAKE_TOOLCHAIN_FILE -o $CMAKE_TOOLCHAIN_FILE -ot $INSTALL_DIRECTORY/cross/$TRG ]
  then
    cat > "$CMAKE_TOOLCHAIN_FILE" <<EOD
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $cpu_family)

set(CMAKE_C_COMPILER   "$BIN/$CC")
set(CMAKE_CXX_COMPILER "$BIN/$CXX")
set(CMAKE_RC_COMPILER  "$BIN/$WINDRES")

set(CMAKE_AR      "$BIN/$AR")
set(CMAKE_RANLIB  "$BIN/$RANLIB")
set(CMAKE_STRIP   "$BIN/$STRIP")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOD
  fi
  unset cpu_family

  # Load the current configuration with information about the source and how to compile
  # static and shared libraries
  load_pkg_config "$CFG"

  # Make compilerflags available (note configuration specific additions)
  export CPPFLAGS="-I$PKG_INS/include ${CFG_CPPFLAGS[*]}"
  export CFLAGS="-I$PKG_INS/include ${CFG_CFLAGS[*]}"
  export CXXFLAGS="-I$PKG_INS/include ${CFG_CXXFLAGS[*]}"
  export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 ${CFG_LDFLAGS[*]}"
  export LIBS="${CFG_LIBS[*]}"

  # Find name of archive with and without suffix
  mapfile -d '' -t pkg_tars < <(
    find \
      "$PKG_TAR_DIR" \
      -maxdepth 1 \
      -name "${CFG_PKG_NAME}*${CFG_VERSION}*.tar.*" \
      -type f \
      -print0 | \
    sort -z
  )
  if [ "${#pkg_tars[@]}" -ne 1 ]
  then
    printf 'Expected exactly one tarball for configuration %s, found %d\n  %s\n' \
      "$CFG" "${#pkg_tars[@]}" "${pkg_tars[@]}" >&2
    exit 1
  fi
  local -r PKG_TAR="${pkg_tars[0]}"
  unset pkg_tars

  # Package extracted into its mutuable source directory, patches
  # applied and any post extraction configuration applied to the code.
  local -r PKG_EXTRACTED="$PKG_SRC/.extracted"
  if [ ! -f "$PKG_EXTRACTED" ]
  then
    tar --strip-components=1 --directory="$PKG_SRC" -xaf "$PKG_TAR"
    # Apply available patches for this packages
    while IFS= read -r -d '' ptc
    do
      apply_patch_file "$ptc" "$PKG_SRC"
    done < <(
      find "$PKG_PTC_DIR" -maxdepth 1 -iname "${CFG}-[0-9]*.patch" -type f -print0 | sort -z
    )
    # Apply specific configuration for this build
    run_hook cfg_post_extract
    touch -- "$PKG_EXTRACTED"
    unset ptc
  fi

  # Enter build directory
  cd -- "$PKG_BLD"

  # Special cases
#  case "$CFG" in
#  zlib*)
#    CHOST="$TRG" \
#    "$PKG_SRC/configure" \
#      --prefix="$PKG_INS"
#    ;;
#  pixman*)
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --buildtype release
#    ;;
#  expat*)
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --without-docbook
#    ;;
#  cairo*)
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz -lexpat"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Dspectre=disabled \
#      -Dglib=enabled \
#      -Ddwrite=disabled \
#      -Dfreetype=enabled \
#      -Dfontconfig=enabled \
#      -Dpng=enabled \
#      -Dzlib=enabled
#
#    ninja -j "$NJOBS" -C "$PKG_BLD"
#    ninja -C "$PKG_BLD" install
#
#    # Cairo is installed as a static library, so consumers must not use dllimport.
#    for pc in "$PKG_INS/lib/pkgconfig/cairo.pc" "$PKG_INS/lib64/pkgconfig/cairo.pc"
#    do
#      if [ -f "$pc" ] && ! grep -q 'CAIRO_STATIC_BUILD' "$pc"; then
#        sed -i \
#          's/^Cflags: \(.*\)$/Cflags: \1 -DCAIRO_STATIC_BUILD -DCAIRO_WIN32_STATIC_BUILD/' \
#          "$pc"
#      fi
#    done
#    return
#    ;;
#  harfbuzz*)
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz -lexpat"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Dicu=disabled \
#      -Dgraphite=disabled \
#      -Dglib=disabled \
#      -Ddocs=disabled
#    ;;
#  pango*)
#    export CFLAGS="$CFLAGS -DCAIRO_WIN32_STATIC_BUILD -DCAIRO_STATIC_BUILD"
#    export CXXFLAGS="$CXXFLAGS -DCAIRO_WIN32_STATIC_BUILD -DCAIRO_STATIC_BUILD"
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz -lexpat"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Dfontconfig=enabled \
#      -Dfreetype=enabled \
#      -Dcairo=enabled \
#      -Dintrospection=disabled \
#      -Dgtk_doc=false \
#      -Dinstall-tests=false \
#      -Dlibthai=disabled \
#      -Dxft=disabled
#  ;;
#  glib*)
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Dintrospection=disabled \
#      -Dnls=disabled \
#      -Dgtk_doc=false \
#      -Dman-pages=disabled \
#      -Dsysprof=disabled \
#      -Ddtrace=false
#    ;;
#  atk-*)
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Dintrospection=false
#
#    ninja -j "$NJOBS" -C "$PKG_BLD"
#    ninja -C "$PKG_BLD" install
#
#    sed -i \
#      's/^Cflags: \(.*\)$/Cflags: \1 -DATK_STATIC_COMPILATION/' \
#      "$PKG_INS/lib/pkgconfig/atk.pc"
#    return
#    ;;
#  gdk-pixbuf*)
#    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lpng16 -lz -lexpat"
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Dintrospection=disabled \
#      -Dgtk_doc=false \
#      -Dman=false \
#      -Dinstalled_tests=false
#    ;;
#  libepoxy*)
#    meson setup "$PKG_BLD" "$PKG_SRC" \
#      --cross-file "$MESON_CROSS_FILE" \
#      --wrap-mode=nofallback \
#      --prefix "$PKG_INS" \
#      --default-library $BKIND \
#      --buildtype release \
#      -Ddocs=false
#    ;;
#  gtk+*)
#    patch_gtk_3_24_32 $PKG_SRC
#    setup_gtk_env $PKG_INS
#
#    PANGO_CFLAGS="$PANGO_CFLAGS" PANGO_LIBS="$PANGO_LIBS" \
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --disable-cups \
#      --disable-glibtest \
#      --disable-demos \
#      --disable-installed-tests
#    ;;
#  curl*)
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --with-schannel \
#      --without-gnutls \
#      --without-mbedtls \
#      --without-wolfssl \
#      --without-zstd \
#      --without-brotli \
#      --without-libpsl \
#      --without-nghttp2 \
#      --without-ngtcp2 \
#      --without-nghttp3 \
#      --without-quiche \
#      --disable-ldap \
#      --disable-ldaps \
#      --disable-manual
#    ;;
#  libxml2*)
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --without-python
#    ;;
#  libcroco*)
#    export LIBS="-lole32 -luuid -lshlwapi -lws2_32 -lintl -lpcre2-8 -lffi -lz -lm"
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND
#    ;;
#  librsvg*)
#    perl -0pi -e \
#      's/rsvg_xml_noerror\s*\(\s*void\s*\*data,\s*xmlErrorPtr\s*error\s*\)/rsvg_xml_noerror (void *data, const xmlError *error)/s' \
#      "$PKG_SRC/rsvg-css.c"
#  
#    export LIBS="-lole32 -luuid -lshlwapi -lws2_32 -lintl -lpcre2-8 -lffi -lz -lm"
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --enable-introspection=no \
#      --disable-gtk-doc \
#      --disable-pixbuf-loader \
#      --disable-tools
#
#    sed -i \
#      's/rsvg-view-3$(EXEEXT)//g; s/rsvg_view_3-test-display\.\$(OBJEXT)//g' \
#      "$PKG_BLD/Makefile"
#    ;;
#  libwebsockets*)
#    sed -i \
#      's/-l:libwebsockets${CMAKE_STATIC_LIBRARY_SUFFIX}/-l:libwebsockets_static${CMAKE_STATIC_LIBRARY_SUFFIX}/' \
#      "$PKG_SRC/lib/CMakeLists.txt"
#
#    local LWS_SHARED=OFF
#    local LWS_STATIC=OFF
#    if [ "$BKIND" = "${BUILD_KINDS[1]}" ]; then
#      LWS_SHARED=ON
#    else
#      LWS_STATIC=ON
#    fi
#
#    cmake "$PKG_SRC" \
#      -DCMAKE_SYSTEM_NAME=Windows \
#      -DCMAKE_C_COMPILER="$CC" \
#      -DCMAKE_AR="$BIN/$AR" \
#      -DCMAKE_RANLIB="$BIN/$RANLIB" \
#      -DCMAKE_STRIP="$BIN/$STRIP" \
#      -DCMAKE_INSTALL_PREFIX="$PKG_INS" \
#      -DCMAKE_PREFIX_PATH="$PKG_INS" \
#      -DCMAKE_FIND_ROOT_PATH="$PKG_INS" \
#      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
#      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
#      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
#      -DCMAKE_BUILD_TYPE=Release \
#      -DLWS_WITH_SHARED=$LWS_SHARED \
#      -DLWS_WITH_STATIC=$LWS_STATIC \
#      -DLWS_WITH_SSL=OFF \
#      -DLWS_WITHOUT_TESTAPPS=ON \
#      -DLWS_WITHOUT_TEST_CLIENT=ON \
#      -DLWS_WITHOUT_TEST_SERVER=ON \
#      -DLWS_WITHOUT_TEST_PING=ON \
#      -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON \
#      -DLWS_WITH_ZLIB=ON
#    ;;
#  libao*)
#    cd -- "$PKG_SRC"
#
#    ./autogen.sh
#    BUILD_TYPE="aconf"
#
#    cd -- "$PKG_BLD"
#
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --disable-esd \
#      --disable-arts \
#      --disable-nas \
#      --disable-pulse \
#      --disable-macosx \
#      --disable-sndio
#    ;;
#  mpg123*)
#    sed -i \
#      's/dump_close(sd);/dump_close();/' \
#        "$PKG_SRC/src/streamdump.c"
#
#    "$PKG_SRC/configure" \
#      --host="$TRG" \
#      --prefix="$PKG_INS" \
#      --disable-${BUILD_KINDS_REV[$BKIND]} \
#      --enable-$BKIND \
#      --disable-modules \
#      --with-default-audio=win32
#    ;;
#  *)
#    if [ "X$BUILD_TYPE" = "Xaconf" ]
#    then
#      "$PKG_SRC/configure" \
#        --host="$TRG" \
#        --prefix="$PKG_INS" \
#        --disable-${BUILD_KINDS_REV[$BKIND]} \
#        --enable-$BKIND
#    elif [ "X$BUILD_TYPE" = "Xmeson" ]
#    then
#      meson setup "$PKG_BLD" "$PKG_SRC" \
#        --cross-file "$MESON_CROSS_FILE" \
#        --wrap-mode=nofallback \
#        --prefix "$PKG_INS" \
#        --default-library $BKIND \
#        --buildtype release \
#        -Ddocs=false
#    fi
#    ;;
#  esac
  local build_system_case="CFG_BUILD_SYSTEM_${BKIND^^}"
  local build_system="${!build_system_case:-${CFG_BUILD_SYSTEM:-}}"
  case "$build_system" in
  "custom")
    run_hook cfg_custom_build
    run_hook cfg_post_install
    ;;
  "autotools")
    if [ "${#CFG_AUTOTOOLS_BOOTSTRAP[@]}" -gt 0 ]
    then
      local -r BOOTSTRAP_FINISHED="$PKG_SRC/.autotools_bootstrapped"
      if [ ! -f "$BOOTSTRAP_FINISHED" ]
      then
        cd -- "$PKG_SRC"
        "${CFG_AUTOTOOLS_BOOTSTRAP[@]}"
        touch -- "$BOOTSTRAP_FINISHED"
        cd -- "$PKG_BLD"
      fi
    fi
    if [ -z "${CFG_CUSTOM_CONFIGURE:-}" ]
    then
      env "${CFG_CONFIGURE_ENV[@]}" \
        "$PKG_SRC/$CFG_CONFIGURE_SH" \
          --host="$TRG" \
          --prefix="$PKG_INS" \
          --disable-${BUILD_KINDS_REV[$BKIND]} \
          --enable-$BKIND \
          "${CFG_CONFIGURE_OPTS[@]}"
    fi
    run_hook cfg_post_configure
    if [ -z "${CFG_CUSTOM_BUILD:-}" ]
    then
      make -j "$NJOBS" "${CFG_MAKE_BUILD_OPTS[@]}" || comp_fail "failed building for $CFG"
    fi
    run_hook cfg_post_build
    if [ -z "${CFG_CUSTOM_INSTALL:-}" ]
    then
      make install "${CFG_MAKE_INSTALL_OPTS[@]}" || comp_fail "failed installing for $CFG"
    fi
    run_hook cfg_post_install
    ;;
  "meson")
    env "${CFG_MESON_ENV[@]}" \
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --wrap-mode=nofallback \
      --prefix "$PKG_INS" \
      --default-library "$BKIND" \
      --buildtype release \
      "${CFG_MESON_OPTS[@]}"
    run_hook cfg_post_configure
    ninja -j "$NJOBS" -C "$PKG_BLD" || comp_fail "failed compiling for $CFG"
    run_hook cfg_post_build
    ninja -j "$NJOBS" -C "$PKG_BLD" install || comp_fail "failed installing for $CFG"
    run_hook cfg_post_install
    ;;
  "cmake")
    cmake \
      -S "$PKG_SRC" \
      -B "$PKG_BLD" \
      -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
      -DBUILD_SHARED_LIBS=$([ "$BKIND" = "${BUILD_KINDS[0]}" ] && echo OFF || echo ON) \
      -DCMAKE_PREFIX_PATH="$PKG_INS" \
      -DCMAKE_FIND_ROOT_PATH="$PKG_INS" \
      -DCMAKE_INSTALL_PREFIX="$PKG_INS" \
      -DCMAKE_BUILD_TYPE=Release \
      "${CFG_CMAKE_CONFIGURE_OPTS[@]}"
    run_hook cfg_post_configure
    cmake \
      --build "$PKG_BLD" \
      --config Release \
      --parallel "$NJOBS" \
      "${CFG_CMAKE_BUILD_OPTS[@]}"
    run_hook cfg_post_build
    cmake \
      --install "$PKG_BLD" \
      --config Release \
      "${CFG_CMAKE_INSTALL_OPTS[@]}"
    run_hook cfg_post_install
    ;;
  *)
    echo "Consider supplying a config file in ./src/pkg/cfg/"
    exit 1
    ;;
  esac

  # Collect for deleting on exit
  if [ -n "${DELETE_PKG_SRC:-}" ] && [ "$DELETE_PKG_SRC" -ne 0 ]
  then
    printf '%s\0' "$PKG_SRC" >> "$CLEANUP_LIST"
  fi
  if [ -n "${DELETE_PKG_BLD:-}" ] && [ "$DELETE_PKG_BLD" -ne 0 ]
  then
    printf '%s\0' "$PKG_BLD" >> "$CLEANUP_LIST"
  fi
  if [ -n "${DELETE_MESON_CONF:-}" ] && [ "$DELETE_MESON_CONF" -ne 0 ]
  then
    printf '%s\0' "$MESON_CROSS_FILE" >> "$CLEANUP_LIST"
  fi
  if [ -n "${DELETE_CMAKE_CONF:-}" ] && [ "$DELETE_CMAKE_CONF" -ne 0 ]
  then
    printf '%s\0' "$CMAKE_TOOLCHAIN_FILE" >> "$CLEANUP_LIST"
  fi
)

for cfg in "${CFG_ORDER[@]}"
do
  declare prc=''
  declare pid=''
  declare -a failed=()
  declare -A pid_to_job=()
  for trg in "${TARGETS[@]}"
  do
    for bkind in "${BUILD_KINDS[@]}"
    do
      (
        echo
        echo "Processing configuration $cfg ($bkind build on $trg)"
        echo
        process_cfg "$cfg" "$bkind" "$trg" "$NCRS_PER_RUN"
      ) &
      pid=$!
      pid_to_job["$pid"]="$cfg:$trg:$bkind"
      while [ "${#pid_to_job[@]}" -ge "$PARALLEL_RUNS" ]
      do
        if ! wait -n -p prc
        then
          failed+=("${pid_to_job["$prc"]}")
        fi
        unset 'pid_to_job[$prc]'
      done
    done
  done
  while [ "${#pid_to_job[@]}" -gt 0 ]
  do
    if ! wait -n -p prc
    then
      failed+=("${pid_to_job["$prc"]}")
    fi
    unset 'pid_to_job[$prc]'
  done
  if [ "${#failed[@]}" -gt 0 ]
  then
    echo "${#failed[@]} packages failed to compile: ${failed[*]}"
    exit 1
  fi
  unset prc pid failed pid_to_job
done

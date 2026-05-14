#!/bin/bash -x
set -euo pipefail

declare -r DELETE_PKG_SRC=0
declare -r DELETE_PKG_BLD=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/etc/common.sh"

# Constant initialisation
declare -r ORIG_PATH="$PATH"
declare -r PKG_TAR_DIR="$SOURCE_DIRECTORY/pkg"
declare -r PKG_BLD_DIR="$BUILD_DIRECTORY/pkg"
declare -r PKG_INS_DIR="$INSTALL_DIRECTORY/pkg"
declare -r PKGS=`ls -m $PKG_TAR_DIR | sed -e 's#\.tar\.[^,]\+##g' | tr '\n' ' '`

# Function definitions
function usage() {
  echo
  echo " usage: $0 pkg1 [pkg2...]"
  echo
  echo " archives must exist in: $PKG_TAR_DIR"
  echo " available gcc packages: $PKGS"
  echo
  exit 1
}

# Deletes the temp directory on exit
declare TEMP_DIR=""
function cleanup() {
  if [ -n "${TEMP_DIR:-}" ]
  then
    rm -rf $TEMP_DIR
    echo -e " deleted temporary working directories: $TEMP_DIR\n"
  fi
}
trap cleanup EXIT

# Argument handling
if [ $# -lt 1 ]
then
  usage
fi
declare -r PKGS_TO_COMPILE="$@"; shift $#

for PKG in $PKGS_TO_COMPILE
do
  case $PKGS in
    *${PKG}*)
      if [ `ls $PKG_TAR_DIR/${PKG}*.tar.* | wc -l` -ne 1 ]
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

# Helper functions
function setup_gtk_env() {
  local -r PREFIX="$1"; shift

  export GLIB_COMPILE_RESOURCES="$(command -v glib-compile-resources)"
  export GLIB_COMPILE_SCHEMAS="$(command -v glib-compile-schemas)"
  export GLIB_GENMARSHAL="$(command -v glib-genmarshal)"
  export GLIB_MKENUMS="$(command -v glib-mkenums)"

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
  local -r PKG_SRC"$1"; shift

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

# Build
function build_pkg() {
  local -r PKG="$1"; local -r TRG="$2"; local -r PKG_SRC=$3; shift 3

  # Reset PATH
  PATH="$ORIG_PATH"
  case "$TRG" in
  x86_64-*)
    CPU_FAMILY="x86_64"
    CPU="x86_64"
    ;;
  i686-*)
    CPU_FAMILY="x86"
    CPU="i686"
    ;;
  esac

  # Build and install directories
  local -r PKG_INS="$PKG_INS_DIR/$TRG"
  local -r PKG_BLD="$PKG_BLD_DIR/$TRG/$SPKG"
  mkdir -p "$PKG_INS" "$PKG_BLD"

  export PATH="$INSTALL_DIRECTORY/cross/$TRG/bin:$PATH"
  export CC="$TRG-gcc"
  export CXX="$TRG-g++"
  export AR="$TRG-ar"
  export RANLIB="$TRG-ranlib"
  export STRIP="$TRG-strip"
  export WINDRES="$TRG-windres"

  export PKG_CONFIG_LIBDIR="$PKG_INS/lib/pkgconfig:$PKG_INS/lib64/pkgconfig:$PKG_INS/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

  export CPPFLAGS="-I$PKG_INS/include"
  export CFLAGS="-I$PKG_INS/include"
  export CXXFLAGS="-I$PKG_INS/include"
  export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64"

  # Collect for deleting the temporary directory on exit
  if [ "$DELETE_PKG_BLD" -ne 0 -a -n "${DELETE_PKG_BLD:-}" ]
  then
    TEMP_DIR="$TEMP_DIR $PKG_BLD"
  fi

  local -r MESON_CROSS_FILE="$PKG_BLD_DIR/$TRG/meson-$TRG.ini"
  if [ ! -f $MESON_CROSS_FILE -o $MESON_CROSS_FILE -ot $INSTALL_DIRECTORY/cross/$TRG ]
  then
    cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$TRG-gcc'
cpp = '$TRG-g++'
ar = '$TRG-ar'
strip = '$TRG-strip'
windres = '$TRG-windres'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$CPU_FAMILY'
cpu = '$CPU'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
  fi

  # Determine known default configurations
  if [ -f $PKG_SRC/meson.build ]
  then
    BUILD_TYPE="meson"
  elif [ -f $PKG_SRC/configure ]
  then
    BUILD_TYPE="aconf"
  fi

  # Enter build directory
  cd "$PKG_BLD"

  # Special cases
  case "$PKG" in
  zlib-*)
    [[ -f config.log ]] || \
    CHOST="$TRG" \
    "$PKG_SRC/configure" \
      --prefix="$PKG_INS"
    ;;
  pixman-*)
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --buildtype release
    ;;
  expat-*)
    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --disable-shared \
      --enable-static \
      --without-docbook
    ;;
  cairo-*)
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz -lexpat"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      -Dspectre=disabled \
      -Dglib=enabled \
      -Ddwrite=disabled \
      -Dfreetype=enabled \
      -Dfontconfig=enabled \
      -Dpng=enabled \
      -Dzlib=enabled

    ninja -j "$NCRS" -C "$PKG_BLD"
    ninja -C "$PKG_BLD" install

    # Cairo is installed as a static library, so consumers must not use dllimport.
    for pc in "$PKG_INS/lib/pkgconfig/cairo.pc" "$PKG_INS/lib64/pkgconfig/cairo.pc"
    do
      if [ -f "$pc" ] && ! grep -q 'CAIRO_STATIC_BUILD' "$pc"; then
        sed -i \
          's/^Cflags: \(.*\)$/Cflags: \1 -DCAIRO_STATIC_BUILD -DCAIRO_WIN32_STATIC_BUILD/' \
          "$pc"
      fi
    done
    return
    ;;
  harfbuzz-*)
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz -lexpat"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      -Dicu=disabled \
      -Dgraphite=disabled \
      -Dglib=disabled \
      -Ddocs=disabled
    ;;
  pango-*)
    export CFLAGS="$CFLAGS -DCAIRO_WIN32_STATIC_BUILD -DCAIRO_STATIC_BUILD"
    export CXXFLAGS="$CXXFLAGS -DCAIRO_WIN32_STATIC_BUILD -DCAIRO_STATIC_BUILD"
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz -lexpat"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      -Dfontconfig=enabled \
      -Dfreetype=enabled \
      -Dcairo=enabled \
      -Dintrospection=disabled \
      -Dgtk_doc=false \
      -Dinstall-tests=false \
      -Dlibthai=disabled \
      -Dxft=disabled
  ;;
  glib-*)
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      --wrap-mode=forcefallback \
      -Dintrospection=disabled \
      -Dnls=disabled \
      -Dgtk_doc=false \
      -Dman-pages=disabled \
      -Dsysprof=disabled \
      -Ddtrace=false
    ;;
  atk-*)
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lz"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      -Dintrospection=false

    ninja -j "$NCRS" -C "$PKG_BLD"
    ninja -C "$PKG_BLD" install

    sed -i \
      's/^Cflags: \(.*\)$/Cflags: \1 -DATK_STATIC_COMPILATION/' \
      "$PKG_INS/lib/pkgconfig/atk.pc"
    return
    ;;
  gdk-pixbuf-*)
    export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 -lpng16 -lz -lexpat"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      -Dintrospection=disabled \
      -Dgtk_doc=false \
      -Dman=false \
      -Dinstalled_tests=false
    ;;
  libepoxy-*)
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PKG_INS" \
      --default-library both \
      --buildtype release \
      -Ddocs=false
    ;;
  gtk+-*)
    patch_gtk_3_24_32 $PKG_SRC
    setup_gtk_env $PKG_INS

    [[ -f config.log ]] || \
    PANGO_CFLAGS="$PANGO_CFLAGS" PANGO_LIBS="$PANGO_LIBS" \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --disable-shared \
      --enable-static \
      --disable-cups \
      --disable-glibtest \
      --disable-demos \
      --disable-installed-tests
    ;;
  curl-*)
    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --enable-shared \
      --enable-static \
      --with-schannel \
      --without-gnutls \
      --without-mbedtls \
      --without-wolfssl \
      --without-zstd \
      --without-brotli \
      --without-libpsl \
      --without-nghttp2 \
      --without-ngtcp2 \
      --without-nghttp3 \
      --without-quiche \
      --disable-ldap \
      --disable-ldaps \
      --disable-manual
    ;;
  libxml2-*)
    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --enable-shared \
      --enable-static \
      --without-python
    ;;
  libcroco-*)
    export LIBS="-lole32 -luuid -lshlwapi -lws2_32 -lintl -lpcre2-8 -lffi -lz -lm"
    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --disable-shared \
      --enable-static
    ;;
  librsvg-*)
    perl -0pi -e \
      's/rsvg_xml_noerror\s*\(\s*void\s*\*data,\s*xmlErrorPtr\s*error\s*\)/rsvg_xml_noerror (void *data, const xmlError *error)/s' \
      "$PKG_SRC/rsvg-css.c"
  
    export LIBS="-lole32 -luuid -lshlwapi -lws2_32 -lintl -lpcre2-8 -lffi -lz -lm"
    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --disable-shared \
      --enable-static \
      --enable-introspection=no \
      --disable-gtk-doc \
      --disable-pixbuf-loader \
      --disable-tools

    sed -i \
      's/rsvg-view-3$(EXEEXT)//g; s/rsvg_view_3-test-display\.\$(OBJEXT)//g' \
      "$PKG_BLD/Makefile"
    ;;
  libwebsockets-*)
    sed -i \
      's/-l:libwebsockets${CMAKE_STATIC_LIBRARY_SUFFIX}/-l:libwebsockets_static${CMAKE_STATIC_LIBRARY_SUFFIX}/' \
      "$PKG_SRC/lib/CMakeLists.txt"

    cmake "$PKG_SRC" \
      -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_AR="$(which $AR)" \
      -DCMAKE_RANLIB="$(which $RANLIB)" \
      -DCMAKE_INSTALL_PKG_INS="$PKG_INS" \
      -DCMAKE_PKG_INS_PATH="$PKG_INS" \
      -DCMAKE_FIND_ROOT_PATH="$PKG_INS" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
      -DCMAKE_BUILD_TYPE=Release \
      -DLWS_WITH_SHARED=OFF \
      -DLWS_WITH_STATIC=ON \
      -DLWS_WITH_SSL=OFF \
      -DLWS_WITHOUT_TESTAPPS=ON \
      -DLWS_WITHOUT_TEST_CLIENT=ON \
      -DLWS_WITHOUT_TEST_SERVER=ON \
      -DLWS_WITHOUT_TEST_PING=ON \
      -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON \
      -DLWS_WITH_ZLIB=ON
    ;;
  libao-*)
    cd "$PKG_SRC"

    ./autogen.sh
    BUILD_TYPE="aconf"

    cd "$PKG_BLD"

    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --disable-shared \
      --enable-static \
      --disable-esd \
      --disable-arts \
      --disable-nas \
      --disable-pulse \
      --disable-macosx \
      --disable-sndio
    ;;
  mpg123-*)
    sed -i \
      's/dump_close(sd);/dump_close();/' \
        "$PKG_SRC/src/streamdump.c"

    [[ -f config.log ]] || \
    "$PKG_SRC/configure" \
      --host="$TRG" \
      --prefix="$PKG_INS" \
      --disable-shared \
      --enable-static \
      --disable-modules \
      --with-default-audio=win32
    ;;
  *)
    if [[ "X$BUILD_TYPE" == "Xaconf" ]]
    then
      [[ -f config.log ]] || \
      "$PKG_SRC/configure" \
        --host="$TRG" \
        --prefix="$PKG_INS" \
        --disable-shared \
        --enable-static \
        --enable-shared
    elif [[ "X$BUILD_TYPE" == "Xmeson" ]]
    then
      meson setup "$PKG_BLD" "$PKG_SRC" \
        --cross-file "$MESON_CROSS_FILE" \
        --prefix "$PKG_INS" \
        --default-library static \
        --buildtype release \
        -Ddocs=false
    fi
    ;;
  esac
  if [[ "X$BUILD_TYPE" == "Xaconf" ]]
  then
    make -j "$NCRS" && make install || \
      comp_fail "failed compiling $PKG"
  elif [[ "X$BUILD_TYPE" == "Xmeson" ]]
  then
    ninja -j "$NCRS" -C "$PKG_BLD" && ninja -C "$PKG_BLD" install || \
      comp_fail "failed compiling $PKG"
  else
    echo "No default way to compile $PKG"
    exit 1
  fi
}

for PKG in $PKGS_TO_COMPILE
do
  # Find name of archive with and without suffix
  PKG_TAR=`ls $PKG_TAR_DIR/${PKG}*.tar.*`
  SPKG=`basename ${PKG_TAR%%.tar.*}`
  # Package extracted source directory
  PKG_SRC="$PKG_TAR_DIR/$SPKG"
  mkdir -p "$PKG_SRC"
  if [ "$DELETE_PKG_SRC" -ne 0 -a -n "${DELETE_PKG_SRC:-}" ]
  then
    TEMP_DIR="$TEMP_DIR $PKG_SRC"
  fi
  tar --strip-components=1 --directory="$PKG_SRC" --skip-old-files -xaf "$PKG_TAR"

  for TRG in "$TRG64" "$TRG32"
  do
    echo
    echo "Building $PKG for $TRG"
    build_pkg "$PKG" "$TRG" "$PKG_SRC"
  done
done

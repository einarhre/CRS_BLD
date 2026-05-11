#!/bin/bash -x
set -euo pipefail

declare -r DELETE_BUILD=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Constant initialisation
declare -r ORIG_PATH="$PATH"
declare -r PKG_DIR="$SOURCE_DIRECTORY/pkg"
declare -r PKG_BUILD_DIR="$BUILD_DIRECTORY/pkg"
declare -r PKG_INSTALL_DIR="$INSTALL_DIRECTORY/pkg"
declare -r PKGS=`ls -m $PKG_DIR | sed -e 's#\.tar\.[^,]\+##g' | tr '\n' ' '`

# Function definitions
function usage() {
  echo
  echo " usage: $0 pkg1 [pkg2...]"
  echo
  echo " archives must exist in: $PKG_DIR"
  echo " available gcc packages: $PKGS"
  echo
  exit 1
}

# Deletes the temp directory on exit
declare TEMP_DIR=""
function cleanup() {
  if [ "$DELETE_BUILD" -ne 0 ] && [ -n "${TEMP_DIR:-}" ]
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
  local -r SRC_DIR="$1"; shift

  sed -i \
    's/gtk_widget_queue_resize (label);/gtk_widget_queue_resize (GTK_WIDGET (label));/' \
    "$SRC_DIR/gtk/gtklabel.c"

  sed -i \
    's/gdouble _gtk_get_slowdown ();/gdouble _gtk_get_slowdown (gdouble factor);/' \
    "$SRC_DIR/gtk/gtkprivate.h"

  sed -i \
    's/_gtk_get_slowdown ()/_gtk_get_slowdown (1.0)/g' \
    "$SRC_DIR/gtk/inspector/visual.c"

  sed -i \
    's/CreateDialogIndirectW (NULL, template, hwndOwner, measure_dialog_procedure)/CreateDialogIndirectW (NULL, (LPCDLGTEMPLATEW) template, hwndOwner, measure_dialog_procedure)/' \
    "$SRC_DIR/gtk/gtkprintoperation-win32.c"

  sed -i \
    's/page\.pResource = template;/page.pResource = (LPCDLGTEMPLATEW) template;/' \
    "$SRC_DIR/gtk/gtkprintoperation-win32.c"

  sed -i '1s|^.*$|#!/usr/bin/env python3|' \
    "$SRC_DIR/gtk/generate-uac-manifest.py"
  chmod +x "$SRC_DIR/gtk/generate-uac-manifest.py"

  perl -0pi -e 's/static int check_dir_mtime\s*\(\s*const char\s*\*dir,\s*const GStatBuf\s*\*sb,\s*int\s*tf\s*\)/static int check_dir_mtime (const char *dir, const struct stat *sb, int tf)/s' \
    "$SRC_DIR/gtk/updateiconcache.c"

  # Patch for tests
  sed -i \
  's/gdk_event_get_source_device (event)/gdk_event_get_source_device ((GdkEvent *) event)/g' \
  "$SRC_DIR/tests/testinput.c"

  find "$SRC_DIR" -name Makefile.[ai][mn] -exec \
    sed -i \
    's%^\([ \t]*\)\(test -n .*update_icon_cache.*\)$%\1#\2%' {} \;
}

# Build
function build_pkg() {
  local -r PKG="$1"; local -r TRG="$2"; shift 2

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

  # Find name of archive with and without suffix
  local -r PKG_TAR=`ls $PKG_DIR/${PKG}*.tar.*`
  local -r SPKG=`basename ${PKG_TAR%%.tar.*}`

  # Build and install directories
  local -r BUILD_ROOT="$PKG_BUILD_DIR/$TRG/$PKG"
  local -r PREFIX="$PKG_INSTALL_DIR/$TRG"

  local -r SRC_DIR="$BUILD_ROOT/src"
  local -r AUTOTOOLS_BUILD_DIR="$BUILD_ROOT/build"
  local -r MESON_BUILD_DIR="$BUILD_ROOT/meson-build"
  local -r MESON_CROSS_FILE="$BUILD_ROOT/meson-$TRG.ini"

  mkdir -p "$SRC_DIR" "$PREFIX"

  tar --strip-components=1 -C "$SRC_DIR" -xaf "$PKG_TAR"

  export PATH="$INSTALL_DIRECTORY/cross/$TRG/bin:$PATH"
  export CC="$TRG-gcc"
  export CXX="$TRG-g++"
  export AR="$TRG-ar"
  export RANLIB="$TRG-ranlib"
  export STRIP="$TRG-strip"
  export WINDRES="$TRG-windres"

  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

  export CPPFLAGS="-I$PREFIX/include"
  export CFLAGS="-I$PREFIX/include"
  export CXXFLAGS="-I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64"

  # Collect for deleting the temporary directory on exit
  TEMP_DIR="$TEMP_DIR $BUILD_ROOT"

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

  # Special cases
  case "$PKG" in
  zlib-*)
    mkdir -p "$AUTOTOOLS_BUILD_DIR"
    cd "$AUTOTOOLS_BUILD_DIR"
    [[ -f config.log ]] || \
    CHOST="$TRG" "$SRC_DIR/configure" \
      --prefix="$PREFIX" \
      --static
    ;;
  pixman-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lz"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install
    return
    ;;
  expat-*)
    mkdir -p "$AUTOTOOLS_BUILD_DIR"
    cd "$AUTOTOOLS_BUILD_DIR"

    [[ -f config.log ]] || \
    "$SRC_DIR/configure" \
      --host="$TRG" \
      --prefix="$PREFIX" \
      --disable-shared \
      --enable-static \
      --without-docbook
    ;;
  cairo-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lz -lexpat"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      -Dspectre=disabled \
      -Dglib=enabled \
      -Ddwrite=disabled \
      -Dfreetype=enabled \
      -Dfontconfig=enabled \
      -Dpng=enabled \
      -Dzlib=enabled

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install

    # Cairo is installed as a static library, so consumers must not use dllimport.
    for pc in "$PREFIX/lib/pkgconfig/cairo.pc" "$PREFIX/lib64/pkgconfig/cairo.pc"
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
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lz -lexpat"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      -Dicu=disabled \
      -Dgraphite=disabled \
      -Dglib=disabled \
      -Ddocs=disabled

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install
    return
    ;;
  pango-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export CFLAGS="$CFLAGS -DCAIRO_WIN32_STATIC_BUILD -DCAIRO_STATIC_BUILD"
    export CXXFLAGS="$CXXFLAGS -DCAIRO_WIN32_STATIC_BUILD -DCAIRO_STATIC_BUILD"
    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lz -lexpat"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      -Dgtk_doc=false \
      -Dintrospection=disabled

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install
    return
  ;;
  glib-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lz"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      --wrap-mode=forcefallback \
      -Dintrospection=disabled \
      -Dnls=disabled \
      -Dgtk_doc=false \
      -Dman-pages=disabled \
      -Dsysprof=disabled \
      -Ddtrace=false

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install
    return
    ;;
  atk-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lz"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      -Dintrospection=false

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install

    sed -i \
      's/^Cflags: \(.*\)$/Cflags: \1 -DATK_STATIC_COMPILATION/' \
      "$PREFIX/lib/pkgconfig/atk.pc"
    return
    ;;
  gdk-pixbuf-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -lpng16 -lz -lexpat"
    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      -Dintrospection=disabled \
      -Dgtk_doc=false \
      -Dman=false \
      -Dinstalled_tests=false

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install
    return
    ;;
  libepoxy-*)
    mkdir -p "$MESON_BUILD_DIR"
    cd "$MESON_BUILD_DIR"

    meson setup "$MESON_BUILD_DIR" "$SRC_DIR" \
      --cross-file "$MESON_CROSS_FILE" \
      --prefix "$PREFIX" \
      --default-library static \
      --buildtype release \
      -Ddocs=false

    ninja -C "$MESON_BUILD_DIR"
    ninja -C "$MESON_BUILD_DIR" install
    return
    ;;
  gtk+-*)
    mkdir -p "$AUTOTOOLS_BUILD_DIR"
    cd "$AUTOTOOLS_BUILD_DIR"

    patch_gtk_3_24_32 $SRC_DIR
    setup_gtk_env $PREFIX

    [[ -f config.log ]] || \
    PANGO_CFLAGS="$PANGO_CFLAGS" PANGO_LIBS="$PANGO_LIBS" \
    "$SRC_DIR/configure" \
      --host="$TRG" \
      --prefix="$PREFIX" \
      --disable-shared \
      --enable-static \
      --disable-cups \
      --disable-glibtest \
      --disable-demos \
      --disable-installed-tests
    ;;
  *)
    mkdir -p "$AUTOTOOLS_BUILD_DIR"
    cd "$AUTOTOOLS_BUILD_DIR"

    [[ -f config.log ]] || \
    "$SRC_DIR/configure" \
      --host="$TRG" \
      --prefix="$PREFIX" \
      --disable-shared \
      --enable-static
    ;;
  esac
  make -j "$NCRS" && make install || comp_fail "failed compiling $PKG"
}

for PKG in $PKGS_TO_COMPILE
do
  for TRG in "$TRG64" "$TRG32"
  do
    echo
    echo "Building $PKG for $TRG"
    build_pkg "$PKG" "$TRG"
  done
done

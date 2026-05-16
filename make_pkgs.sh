#!/bin/bash -x
set -euo pipefail

declare -r DELETE_PKG_SRC=0
declare -r DELETE_PKG_BLD=1
declare -r PARALLEL_LOOP=1

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
  (1 + (${#TARGETS[@]} * ${#BUILD_KINDS[@]} -1) * PARALLEL_LOOP) <= 16 ?
  (1 + (${#TARGETS[@]} * ${#BUILD_KINDS[@]} -1) * PARALLEL_LOOP)       :
   16
))
declare -ri NCRS_PER_RUN=$((
  (1 + (NCRS / PARALLEL_RUNS - 1) * PARALLEL_LOOP) >= 1 ? 
  (1 + (NCRS / PARALLEL_RUNS - 1) * PARALLEL_LOOP)      :
   1
))

# Define the directory structure
declare -r PKG_TAR_DIR="$SOURCE_DIRECTORY/pkg/tar"
declare -r PKG_CFG_DIR="$SOURCE_DIRECTORY/pkg/cfg"
declare -r PKG_PTC_DIR="$SOURCE_DIRECTORY/pkg/ptc"
declare -r PKG_BLD_DIR="$BUILD_DIRECTORY/pkg"
declare -r PKG_INS_DIR="$INSTALL_DIRECTORY/pkg"

# Collect the available packages to compile
declare -a pkgs=()
while IFS= read -r f
do
  pkgs+=("$(basename "${f%%.tar.*}")")
done < <(
  find "$PKG_TAR_DIR" -maxdepth 1 -name '*.tar.*'
)

# Function definitions
function usage() {
  echo
  echo " usage: $0 pkg1 [pkg2...]"
  echo
  echo " archives must exist in: $PKG_TAR_DIR"
  echo " available gcc packages: ${pkgs[@]}"
  echo
  exit 1
}

# Deletes the temp directory on exit
declare temp_dir=""
function cleanup() {
  if [ -n "${temp_dir:-}" ]
  then
    rm -rf -- "$temp_dir"
    echo -e " deleted temporary working directories: $temp_dir\n"
  fi
}
trap cleanup EXIT

# Argument handling
if [ $# -lt 1 ]
then
  usage
fi
declare -ra PKGS_TO_COMPILE=("$@"); shift $#

# Check that all packages can be uniquely determined
for pkg in "${PKGS_TO_COMPILE[@]}"
do
  found=0
  for pkg_full in "${pkgs[@]}"
  do
    if [[ "$pkg_full" == *"${pkg}"* ]]
    then
      found=$(($found + 1))
      echo $found
      if [ $found -gt 1 ]
      then
        echo "Package not unique: $pkg"
        echo
        usage
      fi
    fi
  done
  if [ $found -lt 1 ]
  then
    echo "Package not found: $pkg"
    echo
    usage
  fi
done
unset -v found pkg_full pkgs

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
  local -r PKG="$1"; shift

  local cfg=""

  if [ -f "$PKG_CFG_DIR/$PKG.sh" ]; then
    cfg="$PKG_CFG_DIR/$PKG.sh"
  else
    cfg="$(find "$PKG_CFG_DIR" -maxdepth 1 -name "${PKG%%-*}*.sh" -type f | sort | head -n 1)"
  fi

  if [ -n "$cfg" ]; then
    echo "Loading package config: $cfg"
    source "$cfg"
  fi
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
function build_pkg() (
  local -r PKG="$1"; local -r BKIND=$2; local -r TRG="$3"; local -r NJOBS=$4; shift 4

  # Gera loggið læsilegra
  if [ "$PARALLEL_LOOP" -ne 0 -a -n "${PARALLEL_LOOP:-}" ]
  then
    exec > >(sed "s/^/[$PKG:$TRG:$BKIND] /")
    exec 2>&1
  fi

  # Find name of archive with and without suffix
  mapfile -d '' -t pkg_tars < <(
    find "$PKG_TAR_DIR" -maxdepth 1 -name "${PKG}*.tar.*" -type f -print0 | sort -z
  )
  if [ "${#pkg_tars[@]}" -ne 1 ]
  then
    printf 'Expected exactly one tarball for %s, found %d\n' "$PKG" "${#pkg_tars[@]}" >&2
    printf '  %s\n' "${pkg_tars[@]}" >&2
    exit 1
  fi
  local -r PKG_TAR="${pkg_tars[0]}"
  local -r SPKG="$(basename "${PKG_TAR%%.tar.*}")"
  unset pkg_tars

  # Build, patch and install directories
  local -r PKG_INS="$PKG_INS_DIR/$TRG/$BKIND"
  local -r PKG_BLD="$PKG_BLD_DIR/$TRG/$BKIND/build/$SPKG"
  local -r PKG_SRC="$PKG_BLD_DIR/$TRG/$BKIND/src/$SPKG"
  mkdir -p -- "$PKG_SRC" "$PKG_INS" "$PKG_BLD"

  BIN="$INSTALL_DIRECTORY/cross/$TRG/bin"
  export PATH="$BIN:$PATH"
  export CC="$TRG-gcc"
  export CXX="$TRG-g++"
  export AR="$TRG-ar"
  export RANLIB="$TRG-ranlib"
  export STRIP="$TRG-strip"
  export WINDRES="$TRG-windres"

  export PKG_CONFIG_LIBDIR="$PKG_INS/lib/pkgconfig:$PKG_INS/lib64/pkgconfig:$PKG_INS/share/pkgconfig"
  export PKG_CONFIG_PATH=

  # Collect for deleting the temporary directory on exit
  if [ "$DELETE_PKG_BLD" -ne 0 -a -n "${DELETE_PKG_BLD:-}" ]
  then
    temp_dir="$temp_dir $PKG_BLD"
  fi
  if [ "$DELETE_PKG_SRC" -ne 0 -a -n "${DELETE_PKG_SRC:-}" ]
  then
    temp_dir="$temp_dir $PKG_SRC"
  fi

  # Define variables for the meson ini file
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
    cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$TRG-gcc'
cpp = '$TRG-g++'
ar = '$TRG-ar'
strip = '$TRG-strip'
windres = '$TRG-windres'
pkg-config = '/usr/bin/pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
  fi
  unset cpu_family cpu

  # Load available information about how to compile static and shared libraries
  # for current package
  load_pkg_config "$PKG"

  # Make compilerflags available (note configuration specific additions)
  export CPPFLAGS="-I$PKG_INS/include ${CFG_CPPFLAGS[*]}"
  export CFLAGS="-I$PKG_INS/include ${CFG_CFLAGS[*]}"
  export CXXFLAGS="-I$PKG_INS/include ${CFG_CXXFLAGS[*]}"
  export LDFLAGS="-L$PKG_INS/lib -L$PKG_INS/lib64 ${CFG_LDFLAGS[*]}"
  export LIBS="${CFG_LIBS[*]}"

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
      find "$PKG_PTC_DIR" -maxdepth 1 -iname "${PKG}*.patch" -type f -print0 | sort -z
    )
    # Apply specific configuration for this build
    run_hook cfg_post_extract
    touch -- "$PKG_EXTRACTED"
    unset ptc
  fi

  # Enter build directory
  cd -- "$PKG_BLD"

  # Special cases
#  case "$PKG" in
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
      make -j "$NJOBS" "${CFG_MAKE_BUILD_OPTS[@]}" || comp_fail "failed building $PKG"
    fi
    run_hook cfg_post_build
    if [ -z "${CFG_CUSTOM_INSTALL:-}" ]
    then
      make install "${CFG_MAKE_INSTALL_OPTS[@]}" || comp_fail "failed installing $PKG"
    fi
    run_hook cfg_post_install
    ;;
  "meson")
    [ ${#CFG_MESON_ENV[@]} -gt 0 ] && env "${CFG_MESON_ENV[@]}"
    meson setup "$PKG_BLD" "$PKG_SRC" \
      --cross-file "$MESON_CROSS_FILE" \
      --wrap-mode=nofallback \
      --prefix "$PKG_INS" \
      --default-library "$BKIND" \
      --buildtype release \
      "${CFG_MESON_OPTS[@]}"
    ninja -j "$NJOBS" -C "$PKG_BLD" && ninja -C "$PKG_BLD" install || \
      comp_fail "failed compiling $PKG"
    ;;
  "cmake")
    ;;
  *)
    echo "Consider supplying a config file in ./src/pkg/cfg/"
    exit 1
    ;;
  esac
)

for pkg in "${PKGS_TO_COMPILE[@]}"
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
        echo "Building $bkind $pkg for $trg"
        echo
        build_pkg "$pkg" "$bkind" "$trg" "$NCRS_PER_RUN"
      ) &
      pid=$!
      pid_to_job["$pid"]="$pkg:$trg:$bkind"
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

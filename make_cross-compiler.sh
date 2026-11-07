#!/usr/bin/env bash
set -euo pipefail

if [[ ${NCRS+x} && ! ${NCRS} =~ ^[0-9]+$ ]] ||
   [[ ${NCRS+x} && ! ${NCRS} =~ [1-9] ]]
then
  echo "NCRS must be a positive integer." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/etc/common.sh"
unset script_dir

declare -rA DLLS=(["${TRG64}"]="libgcc_s_seh-1.dll" ["${TRG32}"]="libgcc_s_sjlj-1.dll")

function recovery_error() {
  echo "Recovery stopped: $*. Existing sources, build and install artifacts were preserved." >&2
  echo "Use a separate PREF for a different build, or inspect and move incompatible artifacts aside manually." >&2
  exit 1
}

# Only invocation-owned disposable staging is removed. Source extractions and
# saved unverified sources remain available for inspection after failures.
temporary_dirs=()
git_staging=''
git_published=no
function cleanup_staging() {
  local directory preserve_git_staging=no
  if [[ -n "$git_staging" && ( -e "$git_staging/previous" || -L "$git_staging/previous" ) ]]; then
    if [[ ! -e "$SOURCE_DIRECTORY/cpl/gcc-git" && ! -L "$SOURCE_DIRECTORY/cpl/gcc-git" ]]; then
      mv -- "$git_staging/previous" "$SOURCE_DIRECTORY/cpl/gcc-git" || return
    elif [[ "$git_published" == no ]]; then
      # Publication stopped after moving the new tree into place. Keep the
      # previous checkout (which may contain local work) for manual recovery.
      echo "Previous GCC sources preserved in $git_staging/previous" >&2
      preserve_git_staging=yes
    fi
  fi
  for directory in "${temporary_dirs[@]}"; do
    if [[ "$directory" == "$git_staging" && "$preserve_git_staging" == yes ]]; then continue; fi
    rm -rf -- "$directory"
  done
}
trap cleanup_staging EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

function usage() {
  echo "usage: $0 GCC_VERSION (exact archive version, or git)" >&2
  echo "Available GCC archives:" >&2
  printf '  %s\n' "$SOURCE_DIRECTORY"/cpl/gcc-*.tar.* >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
GCC_VERSION="$1"
[[ "$GCC_VERSION" == git || "$GCC_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

# Discover every supported tar compression format, before changing any sources.
function select_archive() {
  local pattern="$1" selection="$2" file
  local -a files=()
  while IFS= read -r -d '' file; do files+=("$file"); done < <(
    find "$SOURCE_DIRECTORY/cpl" -maxdepth 1 -type f -name "$pattern" -print0 | sort -zV
  )
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No source archive matches $pattern" >&2
    if [[ "$selection" == exact ]]; then usage; fi
    recovery_error "required source archive is missing"
  fi
  # This also rejects all duplicate formats for an exact version selection.
  file="${files[${#files[@]}-1]}"
  local stem="${file%%.tar.*}" candidate count=0
  for candidate in "${files[@]}"; do
    [[ "${candidate%%.tar.*}" != "$stem" ]] || count=$((count + 1))
  done
  [[ $count -eq 1 ]] || recovery_error "ambiguous source archives for $stem"
  printf '%s\n' "$file"
}

MINGW_FN="$(select_archive 'mingw-w64-v*.tar.*' newest)"
BINUTILS_FN="$(select_archive 'binutils-*.tar.*' newest)"
# Empty directory scaffolding is disposable; files, links and other entries in
# either build or install trees require proven compatibility, including ZIPs.
artifacts_present=no
for directory in "$BUILD_DIRECTORY"/{cross,native} "$INSTALL_DIRECTORY"/{cross,native}; do
  if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
    artifacts_present=yes
  elif [[ -d "$directory" ]]; then
    entries="$(find "$directory" -mindepth 1 ! -type d -print -quit)" ||
      recovery_error "cannot inspect existing artifacts in $directory"
    [[ -z "$entries" ]] || artifacts_present=yes
  fi
done

GCC_FN=''
gcc_source="$SOURCE_DIRECTORY/cpl/gcc-git"
if [[ "$GCC_VERSION" != git ]]; then
  GCC_FN="$(select_archive "gcc-$GCC_VERSION.tar.*" exact)"
elif [[ "$artifacts_present" == no ]]; then
  # A new build gets fresh upstream sources. A continuation uses the existing
  # checkout and pinned HEAD; never download or touch its source timestamps.
  git_staging="$(mktemp -d "$SOURCE_DIRECTORY/cpl/.cross-git.XXXXXX")"
  temporary_dirs+=("$git_staging")
  gcc_source="$git_staging/source"
  git clone --depth 1 https://gcc.gnu.org/git/gcc.git "$git_staging/source" ||
    recovery_error "fresh GCC clone failed"
fi

mkdir -p -- "$BUILD_DIRECTORY"
# A single compatibility record, not build-stage checkpoints. NCRS is deliberately
# excluded: make can safely resume the same dependency graph with a new job count.
function build_inputs() {
  local name tool resolved prefix site identity
  printf '%s\n' 'cross-recovery-v2'
  printf 'PREF=%s\n' "$PREF"
  printf 'targets=%s\n' "${TARGETS[*]}"
  identity="$(uname -sm)" || return
  printf 'host=%s\n' "$identity"
  for name in CC CXX CPP AR AS LD NM RANLIB STRIP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS \
    CC_FOR_BUILD CXX_FOR_BUILD CFLAGS_FOR_BUILD CXXFLAGS_FOR_BUILD LDFLAGS_FOR_BUILD \
    CFLAGS_FOR_TARGET CXXFLAGS_FOR_TARGET LDFLAGS_FOR_TARGET CONFIG_SITE CONFIG_SHELL \
    PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR SDKROOT MACOSX_DEPLOYMENT_TARGET \
    CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH COMPILER_PATH GCC_EXEC_PREFIX; do
    printf '%s=%s:%s\n' "$name" "${!name+x}" "${!name-}"
  done
  # Hash this bounded set of host tools once per invocation: paths or version
  # strings alone miss replacements that can invalidate configured builds.
  for tool in "${CC:-cc}" "${CXX:-c++}" "${CPP:-cpp}" \
    "${CC_FOR_BUILD:-cc}" "${CXX_FOR_BUILD:-c++}" \
    "${AR:-ar}" "${AS:-as}" "${LD:-ld}" "${NM:-nm}" \
    "${RANLIB:-ranlib}" "${STRIP:-strip}" "${CONFIG_SHELL:-bash}" make "$PKG_CONFIG_BIN"; do
    resolved="$(command -v "${tool%% *}")" || recovery_error "cannot identify host tool $tool"
    [[ -f "$resolved" ]] || recovery_error "cannot fingerprint host tool $tool"
    identity="$(cksum < "$resolved")" || return
    printf 'tool %s=%s %s\n' "$tool" "$resolved" "$identity"
  done
  # Autoconf cache overrides and site scripts also affect configuration.
  while IFS= read -r name; do
    case "$name" in
      ac_cv_*|*_cv_*) printf '%s=%s\n' "$name" "${!name}" ;;
    esac
  done < <(compgen -e | LC_ALL=C sort)
  for name in ${CONFIG_SITE-}; do
    [[ -f "$name" ]] || recovery_error "cannot identify CONFIG_SITE file $name"
    cksum -- "$name" || return
  done
  if [[ ! ${CONFIG_SITE+x} ]]; then
    for prefix in "$INSTALL_DIRECTORY"/{cross,native}/{"$TRG32","$TRG64"}{,/"$TRG32",/"$TRG64"}; do
      for site in "$prefix/share/config.site" "$prefix/etc/config.site"; do
        printf 'site=%s\n' "$site"
        if [[ -e "$site" ]]; then cksum -- "$site" || return; fi
      done
    done
  fi
  cksum -- "$MINGW_FN" "$BINUTILS_FN" || return
  if [[ -n "$GCC_FN" ]]; then
    cksum -- "$GCC_FN"
  else
    local head
    head="$(git -C "$gcc_source" rev-parse --verify HEAD)" || return
    printf 'gcc-git HEAD=%s\n' "$head"
  fi
}
inputs="$(build_inputs)" || recovery_error "cannot identify build inputs"
input_record="$BUILD_DIRECTORY/.cross-inputs"
if [[ -f "$input_record" && "$(cat -- "$input_record")" != "$inputs" ]]; then
  if [[ "$artifacts_present" == yes ]]; then
    echo "Changed compatibility inputs (previous / current):" >&2
    diff -u -- "$input_record" <(printf '%s\n' "$inputs") >&2 || true
    recovery_error "source selection or build inputs changed ($input_record)"
  fi
  # No results exist to invalidate. Invalidate preparation before publishing the
  # new input record, so interruption cannot bless the old source selection.
  rm -f -- "$BUILD_DIRECTORY/.cross-prepared"
fi
if [[ ! -f "$input_record" ]]; then
  [[ "$artifacts_present" == no ]] || recovery_error "compatibility of existing artifacts is unknown (no $input_record)"
fi
if [[ "$artifacts_present" == no ]]; then
  record_tmp="$(mktemp "$BUILD_DIRECTORY/.cross-inputs.XXXXXX")"
  printf '%s\n' "$inputs" > "$record_tmp"
  mv -- "$record_tmp" "$input_record"
fi

# Extraction is published only after tar succeeds. An interrupted staging directory
# is left available for inspection; no existing source/build directory is removed.
function prepare_archive() {
  local archive="$1" link="$2" destination="${1%%.tar.*}" identity staging
  identity="$(cksum < "$archive")"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ "$refresh_sources" == yes || ! -d "$destination" || -L "$destination" || ! -f "$destination/.cross-extracted" ]] ||
       [[ "$(cat "$destination/.cross-extracted")" != "$identity" ]]; then
      staging="$(mktemp -d "$SOURCE_DIRECTORY/cpl/.cross-source-saved.XXXXXX")"
      mv -- "$destination" "$staging/source"
      echo "Saved unverified sources in $staging/source" >&2
    fi
  fi
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    staging="$(mktemp -d "$SOURCE_DIRECTORY/cpl/.cross-extract.XXXXXX")"
    tar --strip-components=1 --directory="$staging" -xaf "$archive" ||
      recovery_error "extraction failed for $archive (partial sources: $staging)"
    printf '%s\n' "$identity" > "$staging/.cross-extracted"
    mv -- "$staging" "$destination"
  fi
  [[ ! -e "$SOURCE_DIRECTORY/cpl/$link" || -L "$SOURCE_DIRECTORY/cpl/$link" ]] ||
    recovery_error "$SOURCE_DIRECTORY/cpl/$link is not a symbolic link"
  ln -sfn -- "$(basename "$destination")" "$SOURCE_DIRECTORY/cpl/$link"
}

# Include actual prepared contents and link targets, so local edits, changed
# prerequisites and missing files cannot silently reuse a configured build.
# A full content scan is intentional: archive checksums / Git HEAD do not cover
# local edits or downloaded prerequisites. A stat-only cache can miss edits with
# preserved size/timestamps. Compatible resumes scan once, never per component.
function expected_source_target() {
  case "$1" in
    binutils) basename "${BINUTILS_FN%%.tar.*}" ;;
    mingw-w64) basename "${MINGW_FN%%.tar.*}" ;;
    gcc)
      if [[ -n "$GCC_FN" ]]; then basename "${GCC_FN%%.tar.*}"; else echo gcc-git; fi ;;
  esac
}

function source_identity() {
  local name file target source_dir
  for name in binutils mingw-w64 gcc; do
    target="$(expected_source_target "$name")" || return
    source_dir="$SOURCE_DIRECTORY/cpl/$target"
    if [[ "$name" == gcc && -n "$git_staging" ]]; then
      source_dir="$git_staging/source"
    else
      # A missing link can be repaired after verification. An existing wrong
      # link or a real directory at its path must never be silently replaced.
      if [[ -e "$SOURCE_DIRECTORY/cpl/$name" || -L "$SOURCE_DIRECTORY/cpl/$name" ]]; then
        [[ "$(readlink "$SOURCE_DIRECTORY/cpl/$name")" == "$target" ]] || return 1
      fi
    fi
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || return 1
    printf '%s=%s\n' "$name" "$target"
    ( cd -- "$source_dir" || exit 1
      # Batch checksums: GCC contains many thousands of source files.
      find . -name .git -prune -o -type f -print0 | LC_ALL=C sort -z |
        xargs -0 cksum -- || exit 1
      find . -name .git -prune -o -type f -perm /111 -print0 | LC_ALL=C sort -z || exit 1
      find . -name .git -prune -o -type l -print0 | LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        target="$(readlink "$file")" || exit 1
        printf 'link %s=%s\n' "$file" "$target"
      done
    ) || return
  done | cksum
}
prepared_record="$BUILD_DIRECTORY/.cross-prepared"
if [[ "$artifacts_present" == yes && ! -f "$prepared_record" ]]; then
  recovery_error "source preparation cannot be verified for existing build or installation artifacts"
fi
if [[ -n "$git_staging" ]]; then
  ( cd -- "$git_staging/source"; contrib/download_prerequisites --force )
fi
if [[ "$artifacts_present" == yes ]]; then
  current_sources="$(source_identity)" || recovery_error "cannot verify prepared sources"
  [[ "$(cat "$prepared_record")" == "$current_sources" ]] || recovery_error "prepared sources changed or are incomplete"
else
  # Without valuable results, interrupted preparation can safely be retried.
  # Unverified archive trees are moved aside rather than destroyed. If a
  # completed preparation was damaged before any build, re-extract its sources
  # as well; the extraction marker alone cannot prove they are still complete.
  refresh_sources=no
  if [[ -f "$prepared_record" ]]; then
    if ! current_sources="$(source_identity)" || [[ "$(cat "$prepared_record")" != "$current_sources" ]]; then
      refresh_sources=yes
    fi
  fi
  prepare_archive "$MINGW_FN" mingw-w64
  prepare_archive "$BINUTILS_FN" binutils
  if [[ -n "$GCC_FN" ]]; then
    prepare_archive "$GCC_FN" gcc
    ( cd -- "$SOURCE_DIRECTORY/cpl/gcc"; contrib/download_prerequisites --force )
  fi
  current_sources="$(source_identity)" || recovery_error "cannot verify prepared sources"
fi
if [[ -n "$git_staging" ]]; then
  [[ ! -e "$SOURCE_DIRECTORY/cpl/gcc" || -L "$SOURCE_DIRECTORY/cpl/gcc" ]] ||
    recovery_error "gcc is not a symbolic link"
  if [[ -e "$SOURCE_DIRECTORY/cpl/gcc-git" || -L "$SOURCE_DIRECTORY/cpl/gcc-git" ]]; then
    mv -- "$SOURCE_DIRECTORY/cpl/gcc-git" "$git_staging/previous"
  fi
  mv -- "$git_staging/source" "$SOURCE_DIRECTORY/cpl/gcc-git"
  ln -sfn -- gcc-git "$SOURCE_DIRECTORY/cpl/gcc"
  git_published=yes
fi
# Verification above covers the expected directories even when links are absent.
for name in binutils mingw-w64 gcc; do
  if [[ ! -e "$SOURCE_DIRECTORY/cpl/$name" && ! -L "$SOURCE_DIRECTORY/cpl/$name" ]]; then
    ln -s -- "$(expected_source_target "$name")" "$SOURCE_DIRECTORY/cpl/$name"
  fi
done
if [[ "$artifacts_present" == no ]]; then
  record_tmp="$(mktemp "$BUILD_DIRECTORY/.cross-prepared.XXXXXX")"
  printf '%s\n' "$current_sources" > "$record_tmp"
  mv -- "$record_tmp" "$prepared_record"
fi

mkdir -p -- "$BUILD_DIRECTORY"/{cross,native}/{"$TRG32","$TRG64"}/{binutils,gcc,mingw-w64}
mkdir -p -- "$BUILD_DIRECTORY"/cross/{"$TRG32","$TRG64"}/mingw-w64-headers
mkdir -p -- "$INSTALL_DIRECTORY"/{cross,native}/{"$TRG32","$TRG64"}

function configure_component() {
  local signature log_copy record_tmp
  signature="$(printf '%s\0' "$@" | cksum)"
  if [[ -f .cross-configured ]]; then
    [[ "$(cat .cross-configured)" == "$signature" ]] || recovery_error "configure arguments changed in $PWD"
    [[ ! -f Makefile || ! -f config.status ]] || return 0
  fi
  # config.log is diagnostic output, including on failed configuration.
  if [[ -f config.log ]]; then
    log_copy="$(mktemp ./config.log.previous.XXXXXX)"
    cp -p -- config.log "$log_copy"
  fi
  rm -f -- .cross-configured
  if "$@"; then
    [[ -f Makefile && -f config.status ]] || recovery_error "configure did not complete in $PWD"
    record_tmp="$(mktemp ./.cross-configured.XXXXXX)"
    printf '%s\n' "$signature" > "$record_tmp"
    mv -- "$record_tmp" .cross-configured
  else
    recovery_error "configure failed in $PWD; see config.log"
  fi
}

## Build
echo -e "\nBuilding..."

# Function for building target TRG, using NJOBS parallell processes when making
function build_target() {
  [[ $# -eq 2 ]] || return
  local -r TRG="$1"; local -r NJOBS="$2"; shift 2

  # 1. Start with cross-binutils, the first component of the cross-compiler
  echo -e "\n Start with cross-binutils, the first component of the cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/binutils"
  configure_component "$SOURCE_DIRECTORY/cpl/binutils/configure" \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG" \
    --target="$TRG" \
    --disable-multilib
  make -j "$NJOBS" && make install || comp_fail "cross binutils"
  # ...and make sure these are found on PATH
  local -r PATH="$INSTALL_DIRECTORY/cross/$TRG/bin:$PATH"

  # 2. Install the mingw-w64 headers into the target (Windows) sysroot of the cross-compiler
  echo -e "\n Install the mingw-w64 headers into the target (Windows) sysroot of the cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/mingw-w64-headers"
  configure_component "$SOURCE_DIRECTORY/cpl/mingw-w64/mingw-w64-headers/configure" \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG/$TRG" \
    --host="$TRG"
  make install || comp_fail "host mingw-w64-headers"

  # 3. With the target headers installed, build the core gcc cross-compiler
  echo -e "\n With the target headers installed, build the core gcc cross-compiler..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/gcc"
  configure_component "$SOURCE_DIRECTORY/cpl/gcc/configure" \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG" \
    --target="$TRG" \
    --disable-multilib \
    --enable-languages=c,c++,fortran
  make -j "$NJOBS" all-gcc && make install-gcc || comp_fail "cross all-gcc"

  # 4. Build mingw-w64 CRT and install into cross-compiler sysroot
  echo -e "\n Build mingw-w64 CRT and install into cross-compiler sysroot..."
  cd -- "$BUILD_DIRECTORY/cross/$TRG/mingw-w64"
  configure_component "$SOURCE_DIRECTORY/cpl/mingw-w64/configure" \
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
  configure_component "$SOURCE_DIRECTORY/cpl/mingw-w64/mingw-w64-libraries/winpthreads/configure" \
    --prefix="$INSTALL_DIRECTORY/cross/$TRG/$TRG" \
    --host="$TRG" \
    --libdir="$INSTALL_DIRECTORY/cross/$TRG/$TRG/lib"
  make -j "$NJOBS" && make install || comp_fail "cross winpthreads"

  # 7. Build Windows-native binutils
  echo -e "\n Build Windows-native binutils..."
  cd -- "$BUILD_DIRECTORY/native/$TRG/binutils"
  configure_component "$SOURCE_DIRECTORY/cpl/binutils/configure" \
    --prefix="$INSTALL_DIRECTORY/native/$TRG" \
    --host="$TRG" \
    --target="$TRG" \
    --disable-multilib \
    --without-zstd
  make -j "$NJOBS" && make install || comp_fail "host binutils"

  # 8. Build Windows-native gcc
  echo -e "\n Build Windows-native gcc..."
  cd -- "$BUILD_DIRECTORY/native/$TRG/gcc"
  configure_component "$SOURCE_DIRECTORY/cpl/gcc/configure" \
    --prefix="$INSTALL_DIRECTORY/native/$TRG" \
    --host="$TRG" \
    --target="$TRG" \
    --disable-multilib \
    --enable-languages=c,c++,fortran
  make -j "$NJOBS" && make install || comp_fail "host gcc"
  local dll_destination="$INSTALL_DIRECTORY/native/$TRG/bin/${DLLS[$TRG]}" DLL
  # Prefer a freshly installed runtime outside bin, irrespective of find order.
  # Sort multiple candidates for a repeatable choice, without head/SIGPIPE.
  DLL="$(find -- "$INSTALL_DIRECTORY/native/$TRG" -name "${DLLS[$TRG]}" -type f \
    ! -path "$dll_destination" -print | LC_ALL=C sort | sed -n '1p')"
  if [[ -n "$DLL" ]]; then
    mv -f -- "$DLL" "$dll_destination"
  else
    [[ -f "$dll_destination" ]] || comp_fail "missing ${DLLS[$TRG]}"
  fi

  # 9. Build mingw-w64 headers and libs (including winpthreads) and install into native toolchain sysroot
  echo -e "\n Build mingw-w64 headers and libs (including winpthreads) and install into native toolchain sysroot..."
  cd -- "$BUILD_DIRECTORY/native/$TRG/mingw-w64"
  configure_component "$SOURCE_DIRECTORY/cpl/mingw-w64/configure" \
    --prefix="$INSTALL_DIRECTORY/native/$TRG/$TRG" \
    --host="$TRG" \
    --with-libraries=winpthreads
  make && make install || comp_fail "host mingw-w64"

  # 10. Package the native installation folder
  echo -e "\n Package the native installation folder..."
  cd -- "$INSTALL_DIRECTORY/native"
  local package_dir
  package_dir="$(mktemp -d "$INSTALL_DIRECTORY/native/.cross-package.XXXXXX")"
  temporary_dirs+=("$package_dir")
  if [[ -f "$TRG.zip" ]]; then
    cp -p -- "$TRG.zip" "$package_dir/$TRG.zip"
  fi
  zip --filesync --recurse-paths "$package_dir/$TRG.zip" "$TRG" ||
    recovery_error "packaging failed for $TRG; previous archive was preserved"
  mv -- "$package_dir/$TRG.zip" "$TRG.zip"
  rmdir -- "$package_dir"
}

# Make everything
for trgs in "${TARGETS[@]}"
do
  build_target "$trgs" "$NCRS"
done

#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

declare -r ROOTPATH="${1:-/home/eoh/src/CRS_BLD/install/pkg}"; shift $#

declare -ra TARGETS=(
  'i686-w64-mingw32'
  'x86_64-w64-mingw32'
)

declare -ra BUILD_KINDS=(
  'static'
  'shared'
)

function is_system_lib() {
  [ $# -eq 1 ] || return 1
  local -r LIB="$1"; shift

  case "$LIB" in
    m|dl|rt|pthread|atomic|stdc++|gcc|gcc_s|mingw32|mingwex|msvcrt|ucrt|ksuser)
      return 0
      ;;
    cfgmgr32|kernel32|user32|gdi32|winspool|shell32|ole32|oleaut32|uuid|comdlg32|advapi32|bcrypt|crypt32)
      return 0
      ;;
    ws2_32|winmm|shlwapi|dnsapi|iphlpapi|setupapi|comctl32|dwmapi|imm32|opengl32|hid)
      return 0
      ;;
    dwrite|d2d1|windowscodecs|msimg32)
      return 0
      ;;
    dxguid|psapi|netio|secur32|wldap32)
      return 0
      ;;
  esac

  return 1
}

function pc_var_value() {
  [ $# -eq 2 ] || return 1
  local -r PC="$1"; local -r VAR="$2"; shift 2

  grep -m 1 "^${VAR}=" "$PC" 2>/dev/null | sed "s#^${VAR}=##"
}

function expand_pc_path() {
  [ $# -eq 2 ] || return 1
  local -r PC="$1"; local value="$2"; shift 2

  local prefix=''
  local exec_prefix=''
  local libdir=''

  prefix="$(pc_var_value "$PC" prefix || true)"
  exec_prefix="$(pc_var_value "$PC" exec_prefix || true)"
  libdir="$(pc_var_value "$PC" libdir || true)"
  sharedlibdir="$(pc_var_value "$PC" sharedlibdir || true)"
  toolexeclibdir="$(pc_var_value "$PC" toolexeclibdir || true)"
  

  [ -n "$exec_prefix" ] || exec_prefix='${prefix}'
  [ -n "$sharedlibdir" ] || sharedlibdir='${libdir}'
  [ -n "$toolexeclibdir" ] || toolexeclibdir='${libdir}'

  local cnt=0
  while grep -F -e '${' &>/dev/null <<< "$value"
  do
    value="${value//\$\{prefix\}/$prefix}"
    value="${value//\$\{exec_prefix\}/$exec_prefix}"
    value="${value//\$\{libdir\}/$libdir}"
    value="${value//\$\{sharedlibdir\}/$sharedlibdir}"
    value="${value//\$\{toolexeclibdir\}/$toolexeclibdir}"
    [ "$((++cnt))" -ge 5 ] && break
  done

  printf '%s\n' "$(realpath -mq "$value")"
}

function pc_libdirs() {
  [ $# -eq 1 ] || return 1
  local -r PC="$1"; shift

    while IFS= read -r dir
    do
      expand_pc_path "$PC" "$dir"
    done < <(
      grep -E '^(Libs|Libs.private):' "$PC" 2>/dev/null | \
        grep -oE -- '-L([^ ]+)' | \
        sed 's/^-L//'
    )
}

function pc_libnames() {
  [ $# -eq 1 ] || return 1
  local -r PC="$1"; shift

    while IFS= read -r lib
    do
      is_system_lib "$lib" && continue
      printf '%s\n' "$lib"
    done < <(
      grep -E '^(Libs|Libs.private):' "$PC" 2>/dev/null | \
        grep -oE -- '-l[^ ]+' | \
        sed 's/^-l//' | sort -u
    )
}

function find_library_locations() {
  [ $# -eq 2 ] || return 1
  local -r PREFIX="$1"; local -r LIB="$2"; shift 2

  local -a dirs=()
  [ -d "$PREFIX/lib" ] && dirs+=("$PREFIX/lib")
  [ -d "$PREFIX/lib64" ] && dirs+=("$PREFIX/lib64")

  [ "${#dirs[@]}" -gt 0 ] || return 0

  find -L "${dirs[@]}" \
    \( -name "lib${LIB}.a" -o -name "lib${LIB}.dll.a" \) \
    -type f 2>/dev/null | sort -u
}

function check_pc_libdir_exists() {
  [ $# -eq 1 ] || return 1
  local -r PC="$1"; shift

  local raw_libdir=''
  local expanded_libdir=''

  raw_libdir="$(pc_var_value "$PC" libdir || true)"
  [ -n "$raw_libdir" ] || return 0

  expanded_libdir="$(expand_pc_path "$PC" "$raw_libdir")"

  if [ ! -d "$expanded_libdir" ]
  then
    printf 'BAD_LIBDIR: %s\n' "$PC"
    printf '  pc libdir: %s\n' "$raw_libdir"
    printf '  expands : %s\n\n' "$expanded_libdir"
  fi
}

function check_pc_vs_files() {
  [ $# -eq 3 ] || return 1
  local -r PREFIX="$1"; local -r TRG="$2"; local -r BKIND="$3"; shift 3

  local -a pcdirs=()
  [ -d "$PREFIX/lib/pkgconfig" ] && pcdirs+=("$PREFIX/lib/pkgconfig")
  [ -d "$PREFIX/lib64/pkgconfig" ] && pcdirs+=("$PREFIX/lib64/pkgconfig")
  [ -d "$PREFIX/share/pkgconfig" ] && pcdirs+=("$PREFIX/share/pkgconfig")

  [ "${#pcdirs[@]}" -gt 0 ] || return 0

  echo
  echo "== ${TRG}/${BKIND} =="
  echo

  local -A seen_pc=()
  while IFS= read -r pc # all pc files found
  do
    local pc_file="$(basename "$pc" .pc)"
    if [[ -v 'seen_pc[$pc_file]' ]]
    then
      printf 'DUPLICATE_PC: %s\n' "$pc_file"
      printf '  first: %s\n' "${seen_pc[$pc_file]}"
      printf '  again: %s\n' "$pc"
    else
      seen_pc["$pc_file"]="$pc"
    fi

    check_pc_libdir_exists "$pc" # Check if expanded libdir variable in pc is a real path

    while IFS= read -r lib # LIB from -lLIB stuff in a pc file (except system LIB)
                           # in Libs: or Libs.private:
    do
      local actual=''
      # only look for real files (not links) of the form:
      # lib${lib}.a or lib${lib}.dll.a
      actual="$(find_library_locations "$PREFIX" "$lib")"

      if [ -z "$actual" ]
      then
        printf 'MISSING_LIB_FROM_PC: %s\n' "${pc#$PREFIX/}"
        printf '  pc wants : -l%s\n' "$lib"
        printf '  searched : %s/lib and %s/lib64\n\n' "$PREFIX" "$PREFIX"
        continue
      fi

      local pc_dirs=''
      pc_dirs="$(pc_libdirs "$pc" || true)" # LIBDIR from -LLIBDIR stuff in a pc file

      if [ -n "$pc_dirs" ]
      then
        local found_match=0

        while IFS= read -r libpath
        do
          local libdir
          libdir="$(dirname "$libpath")"

          if printf '%s\n' "$pc_dirs" | grep -Fxq -- "$libdir"
          then
            found_match=1
          fi
        done <<< "$actual"

        if [ "$found_match" -eq 0 ]
        then
          printf 'PC_FILE_LOCATION_MISMATCH: %s\n' "${pc#$PREFIX/}"
          printf '  pc wants      : -l%s\n' "$lib"
          printf '  pc -L dirs    :\n'
          printf '%s\n' "$pc_dirs" | sed 's/^/    /'
          printf '  actual files  :\n'
          printf '%s\n' "$actual" | sed 's/^/    /'
          printf '\n'
        fi
      fi
    done < <(pc_libnames "$pc")
  done < <(find "${pcdirs[@]}" -name '*.pc' -type f 2>/dev/null | sort)
}

for trg in "${TARGETS[@]}"
do
  for bkind in "${BUILD_KINDS[@]}"
  do
    prefix="$ROOTPATH/$trg/$bkind"

    if [ ! -d "$prefix" ]
    then
      echo "SKIP: missing prefix: $prefix"
      continue
    fi

    check_pc_vs_files "$prefix" "$trg" "$bkind"
  done
done

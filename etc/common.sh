#!/bin/bash

set -euo pipefail

# Constant initialisation (read only -r)
declare -r PREF="${PREF:-/home/eoh/src/CRS_BLD}"
declare -r SOURCE_DIRECTORY="$PREF/src"
declare -r BUILD_DIRECTORY="$PREF/build"
declare -r INSTALL_DIRECTORY="$PREF/install"

declare -r TRG32="i686-w64-mingw32"
declare -r TRG64="x86_64-w64-mingw32"
declare -ra TARGETS=("$TRG32" "$TRG64")

declare -r NCRS="${NCRS:-$(nproc --all)}"
if [ "$NCRS" -le 0 ]
then
  echo "No processing units appear to be available for this machine (nproc --all)!"
  exit 1
fi

# Function definition
function comp_fail() {
  local -r COMP="$1"; shift
  echo
  echo " compiling failed: $COMP"
  echo
  exit 1
}

# Deletes temporary directories and files on exit
function empty_trash_bin() {
  [ $# -ne 1 ] && return 1
  local -r TRASH_BIN="$1"; shift
  local -a paths=()

  if [ -f "$TRASH_BIN" ]
  then
    mapfile -d '' -t paths < <(sort -u -z -- "$TRASH_BIN")
    rm -f -- "$TRASH_BIN"
  fi

  if [ "${#paths[@]}" -gt 0 ]
  then
    if  rm -rf -- "${paths[@]}"
    then
      printf 'deleted the following directories/files:\n'
      printf '  %s\n' "${paths[@]}"
      printf '\n'
    fi
  fi
}

# Add content into a trashbin to be deleted on exit (with empty_trash_bin above)
function put_into_trash_bin() {
  [ $# -lt 2 ] && return 1
  local -r TRASH_BIN="$1"; shift
  [ -z "$TRASH_BIN" ] && return 1
  [ -f "$TRASH_BIN" ] || return 1

  printf '%s\0' "$@" >> "$TRASH_BIN"
}

# Acquire a lock using atomic mkdir.
function lock_acquire() {
  [ $# -eq 1 ] || return 1
  local -r LOCKDIR="$1"; shift
  [ -n "$LOCKDIR" ] || return 1

  while ! mkdir -- "$LOCKDIR" 2>/dev/null
  do
    sleep 1
  done
}

# Release a lock acquired with lock_acquire.
function lock_release() {
  [ $# -eq 1 ] || return 1
  local -r LOCKDIR="$1"; shift
  [ -n "$LOCKDIR" ] || return 1

  rmdir -- "$LOCKDIR"
}

# Run a command while holding a lock.
function lock_run() {
  [ $# -ge 2 ] || return 1
  local -r LOCKDIR="$1"; shift
  lock_acquire "$LOCKDIR" || return 1

  "$@"
  local -r STATUS=$?

  lock_release "$LOCKDIR" 2>/dev/null || true

  return "$STATUS"
}

# Diagnostic routines
check_pc_vs_files() {
  local prefix="$1"
  local pc lib flag name

  echo "== $prefix =="

  find "$prefix/lib/pkgconfig" "$prefix/lib64/pkgconfig" "$prefix/share/pkgconfig" \
    -name '*.pc' -type f 2>/dev/null |
  while IFS= read -r pc
  do
    grep -E '^(Libs|Libs.private):' "$pc" |
    grep -oE -- '-l[^ ]+' |
    sed 's/^-l//' |
    while IFS= read -r name
    do
      if ! find "$prefix/lib" "$prefix/lib64" \
        \( -name "lib${name}.a" -o -name "lib${name}.dll.a" \) \
        -type f 2>/dev/null | grep -q .
      then
        echo "MISSING: $pc -> -l$name"
      fi
    done
  done
}


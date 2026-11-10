#!/usr/bin/env bash
# Package-only definitions. Source after common.sh for Homebrew GNU PATH setup.
# Requires Bash >= 4.4 (mapfile -d); the package driver requires >= 5.1.

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


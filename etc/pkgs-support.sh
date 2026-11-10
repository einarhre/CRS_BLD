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

# Run protected work in a child shell; callback scope/traps cannot alter cleanup.
# A conditional caller disables errexit throughout callbacks: check critical steps.
function lock_run() (
  [ $# -ge 2 ] || return 1
  local -r LOCKDIR="$1"; shift
  lock_acquire "$LOCKDIR" || return 1

  # Bind every path reference now, never from callback dynamic scope at EXIT.
  # %q also protects spaces, newlines, quotes and shell metacharacters in paths.
  local __lock_run_cleanup
  printf -v __lock_run_cleanup '
    __lock_run_status=$?
    if ! rmdir -- %q 2>/dev/null; then
      if [[ -e %q || -L %q ]]; then
        printf "Cannot release lock: %%s\\n" %q >&2
        [[ "$__lock_run_status" -ne 0 ]] || __lock_run_status=1
      fi
    fi
    exit "$__lock_run_status"
  ' "$LOCKDIR" "$LOCKDIR" "$LOCKDIR" "$LOCKDIR"
  trap "$__lock_run_cleanup" EXIT
  # Bash defers these traps until the protected foreground child has finished.
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  ( "$@" )
)

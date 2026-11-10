# Package-only helper characterization; fresh common + support per invocation.
_LOCK_ACQUIRE='lock_acquire "$1"; echo acquired'

# --------------------------------------------------------------- trash bin

t_pkgs_support_trash_put_and_empty_removes_paths() {
  sandbox_new
  mkdir -p "$SB/d/sub"; : > "$SB/d/sub/f"; : > "$SB/file"
  : > "$SB/bin"
  run_pkgs_support -- 'put_into_trash_bin "$1" "$2" "$3"; empty_trash_bin "$1"' "$SB/bin" "$SB/d" "$SB/file"
  assert_rc 0 "$RC" 'empty_trash_bin'
  assert_absent "$SB/d" 'directory removed'
  assert_absent "$SB/file" 'file removed'
  assert_absent "$SB/bin" 'bin file removed'
  assert_eq "deleted the following directories/files:
  $SB/d
  $SB/file
" "$OUT"$'\n' 'report (sorted, one per line, trailing blank line)'
}

t_pkgs_support_trash_paths_with_whitespace_and_newlines() {
  sandbox_new
  local sp="$SB/with space" nl="$SB/new"$'\n'"line" lead="$SB/-rf" tab="$SB/t"$'\t'"ab" ap="$SB/it's"
  mkdir -p -- "$sp" "$nl" "$lead" "$tab" "$ap"; : > "$nl/x"
  : > "$SB/bin"
  run_pkgs_support -- 'put_into_trash_bin "$@"; empty_trash_bin "$1"' "$SB/bin" "$sp" "$nl" "$lead" "$tab" "$ap"
  assert_rc 0 "$RC" 'empty_trash_bin'
  assert_absent "$sp"; assert_absent "$nl"; assert_absent "$lead"; assert_absent "$tab"; assert_absent "$ap"
  # the report prints each entry raw, so a newline splits the display line
  assert_contains "$OUT"$'\n' "  $nl"$'\n' 'newline path shown raw'
  assert_contains "$OUT"$'\n' "  $sp"$'\n' 'space path shown'
  assert_contains "$OUT"$'\n' "  $ap"$'\n' 'apostrophe path shown'
  [[ -d "$SB" ]] || fail 'sandbox itself must survive'
}

t_pkgs_support_trash_entries_with_glob_chars_are_literal() {
  sandbox_new
  mkdir -p "$SB/g1" "$SB/g2"; : > "$SB/keep1"
  : > "$SB/bin"
  run_pkgs_support -- 'put_into_trash_bin "$1" "$SB/g*"; empty_trash_bin "$1"' "$SB/bin"
  assert_rc 0 "$RC" 'status'
  assert_exists "$SB/g1" 'glob not expanded'
  assert_exists "$SB/g2" 'glob not expanded'
  assert_exists "$SB/keep1" 'unrelated file survives'
}

t_pkgs_support_trash_duplicates_are_removed_once_and_listed_once() {
  sandbox_new
  mkdir -p "$SB/dup"; : > "$SB/bin"
  run_pkgs_support -- 'put_into_trash_bin "$1" "$2" "$2"; put_into_trash_bin "$1" "$2"; empty_trash_bin "$1"' "$SB/bin" "$SB/dup"
  assert_rc 0 "$RC" 'status'
  assert_absent "$SB/dup"
  assert_eq 1 "$(count_substr "$OUT" "  $SB/dup")" 'listed exactly once'
}

t_pkgs_support_trash_missing_files_are_ignored_but_still_reported() {
  sandbox_new
  : > "$SB/bin"
  run_pkgs_support -- 'put_into_trash_bin "$1" "$2"; empty_trash_bin "$1"' "$SB/bin" "$SB/never-existed"
  assert_rc 0 "$RC" 'rm -f tolerates missing paths'
  assert_absent "$SB/bin"
  assert_contains "$OUT" "  $SB/never-existed" 'reported as deleted although it never existed'
}

t_pkgs_support_trash_empty_and_missing_bin() {
  sandbox_new
  : > "$SB/emptybin"
  run_pkgs_support -- 'empty_trash_bin "$1"' "$SB/emptybin"
  assert_rc 0 "$RC" 'empty bin'
  assert_eq '' "$OUT" 'no output for an empty bin'
  assert_absent "$SB/emptybin" 'empty bin file still removed'
  run_pkgs_support -- 'empty_trash_bin "$1"' "$SB/nonexistent-bin"
  assert_rc 0 "$RC" 'missing bin is not an error'
  assert_eq '' "$OUT" 'no output for a missing bin'
}

t_pkgs_support_trash_argument_and_bin_validation() {
  sandbox_new
  : > "$SB/bin"; mkdir "$SB/dirbin"
  run_pkgs_support -- 'empty_trash_bin || echo e0=$?; empty_trash_bin a b || echo e2=$?
    put_into_trash_bin || echo p0=$?; put_into_trash_bin "$1" || echo p1=$?
    put_into_trash_bin "" x || echo pempty=$?; put_into_trash_bin "$2" x || echo pmissing=$?
    put_into_trash_bin "$3" x || echo pdir=$?' "$SB/bin" "$SB/missing-bin" "$SB/dirbin"
  local t
  for t in e0=1 e2=1 p0=1 p1=1 pempty=1 pmissing=1 pdir=1; do
    assert_contains "$OUT" "$t" "argument validation $t"
  done
  assert_absent "$SB/missing-bin" 'put does not create the bin'
  assert_eq 0 "$(wc -c < "$SB/bin")" 'rejected calls append nothing'
}

t_pkgs_support_trash_bin_content_is_nul_separated() {
  sandbox_new
  : > "$SB/bin"
  run_pkgs_support -- 'put_into_trash_bin "$1" "a b" $'"'"'c\nd'"'"'' "$SB/bin"
  assert_rc 0 "$RC" 'put'
  assert_eq "$(printf 'a b\0c\nd\0' | od -An -c | tr -s ' ')" "$(od -An -c < "$SB/bin" | tr -s ' ')" 'NUL-separated records'
}

# -------------------------------------------------------------------- locks

t_pkgs_support_lock_acquire_creates_and_release_removes() {
  sandbox_new
  run_pkgs_support -- 'lock_acquire "$1" && test -d "$1" && echo held; lock_release "$1"; test ! -e "$1" && echo released' "$SB/L"
  assert_rc 0 "$RC" 'acquire/release'
  assert_contains "$OUT" held; assert_contains "$OUT" released
}

t_pkgs_support_lock_argument_validation() {
  sandbox_new
  run_pkgs_support -- 'lock_acquire || echo a0=$?; lock_acquire x y || echo a2=$?; lock_acquire "" || echo ae=$?
    lock_release || echo r0=$?; lock_release x y || echo r2=$?; lock_release "" || echo re=$?
    lock_run || echo u0=$?; lock_run "$1" || echo u1=$?' "$SB/L"
  local t
  for t in a0=1 a2=1 ae=1 r0=1 r2=1 re=1 u0=1 u1=1; do assert_contains "$OUT" "$t" "validation $t"; done
  assert_absent "$SB/L" 'rejected lock_run must not create the lock'
}

t_pkgs_support_lock_release_of_unheld_lock_fails() {
  sandbox_new
  run_pkgs_support -- 'lock_release "$1" || echo rc=$?' "$SB/none"
  assert_contains "$OUT" 'rc=1' 'rmdir failure is returned'
}

t_pkgs_support_lock_contention_blocks_until_release() {
  sandbox_new
  mkdir "$SB/L"
  # Held lock: a second acquirer must still be waiting after 3 seconds.
  run_pkgs_support -t 3 -- "$_LOCK_ACQUIRE" "$SB/L"
  assert_eq 124 "$RC" 'acquirer times out while the lock is held'
  assert_not_contains "$OUT" acquired 'must not acquire a held lock'
  # Released after a delay: the waiter proceeds and ends up holding it.
  spawn_ctl "$SB/.run/releaser" -t 10 -- "$BASH_BIN" --noprofile --norc -c 'sleep 2; rmdir "$1"' _ "$SB/L"
  local rel="$SPAWN_PID"
  run_pkgs_support -t 20 -- "$_LOCK_ACQUIRE" "$SB/L"
  local waiter_rc="$RC" waiter_out="$OUT"
  reap_ctl "$rel"
  assert_rc 0 "$waiter_rc" 'waiter acquires after release'
  assert_contains "$waiter_out" acquired
  assert_exists "$SB/L" 'waiter now holds the lock'
}

t_pkgs_support_lock_run_is_mutually_exclusive() {
  sandbox_new
  local i pids=() p
  for i in 1 2 3; do
    spawn_ctl "$SB/.run/worker$i" -t 40 -- "$BASH_BIN" --noprofile --norc -c 'source "$COMMON_SH"; source "$PKGS_SUPPORT_SH"
      section() { echo "start $1" >> "$2"; sleep 0.3; echo "end $1" >> "$2"; }
      lock_run "$3" section "$1" "$2"' _ "$i" "$SB/log" "$SB/L"
    pids+=("$SPAWN_PID")
  done
  # Any early failure below leaves workers running; the runner reaps them.
  for p in "${pids[@]}"; do reap_ctl "$p"; [[ "$RC" -eq 0 ]] || fail "worker exit $RC"; done
  assert_eq 6 "$(wc -l < "$SB/log")" 'six log lines'
  local expect="" line k=0
  while IFS= read -r line; do
    if (( k % 2 == 0 )); then
      [[ "$line" == start* ]] || fail "interleaved: $(cat "$SB/log")"; expect="end ${line#start }"
    else
      [[ "$line" == "$expect" ]] || fail "interleaved: $(cat "$SB/log")"
    fi
    k=$((k + 1))
  done < "$SB/log"
  assert_absent "$SB/L" 'lock released at the end'
}

t_pkgs_support_lock_run_success_passes_arguments_and_releases() {
  sandbox_new
  run_pkgs_support -- 'f() { echo "args=$# [$1] [$2]"; }; lock_run "$1" f "a b" ""; echo rc=$?; test ! -e "$1" && echo free' "$SB/L"
  assert_contains "$OUT" 'args=2 [a b] []'
  assert_contains "$OUT" 'rc=0'; assert_contains "$OUT" free
}

t_pkgs_support_lock_run_failure_status_released_when_errexit_suppressed() {
  sandbox_new
  # In an `||` context set -e is inactive, so the failure status is returned
  # and the lock IS released.  Contrast with k_pkgs_support_lock_run_leaks_*.
  run_pkgs_support -- 'lock_run "$1" false || echo status=$?; test ! -e "$1" && echo free' "$SB/L"
  assert_contains "$OUT" 'status=1'; assert_contains "$OUT" free
}

t_pkgs_support_lock_run_ignores_release_failure() {
  sandbox_new
  run_pkgs_support -- 'f() { rmdir "$L"; }; L="$1"; lock_run "$1" f; echo rc=$?' "$SB/L"
  assert_contains "$OUT" 'rc=0' 'a vanished lock does not change the status'
}

k_pkgs_support_lock_run_leaks_lock_when_command_fails_under_errexit() {
  # KNOWN DEFECT: common.sh enables `set -e`; lock_run runs "$@" as a plain
  # command, so a failing command aborts the shell before lock_release.  The
  # lock directory is left behind and the next acquirer waits forever.
  # Reproduced -> exit 0; non-gating.
  sandbox_new
  run_pkgs_support -- 'lock_run "$1" false; echo not-reached' "$SB/L"
  [[ "$RC" -ne 0 ]] || fail "shell was not aborted (rc=$RC)"
  assert_not_contains "$OUT" not-reached 'errexit aborted the shell'
  assert_exists "$SB/L" 'defect: lock directory leaked'
  run_pkgs_support -t 3 -- "$_LOCK_ACQUIRE" "$SB/L"
  assert_eq 124 "$RC" 'defect: next acquirer blocks (killed by timeout)'
  echo "lock leaked after failing command; next acquirer timed out"
}

k_pkgs_support_lock_acquire_spins_forever_when_parent_missing() {
  # KNOWN DEFECT: mkdir errors are hidden, so an uncreatable lock path (missing
  # parent directory) is indistinguishable from contention; the loop never ends.
  sandbox_new
  run_pkgs_support -t 3 -- "$_LOCK_ACQUIRE" "$SB/no/such/parent/L"
  assert_eq 124 "$RC" 'spins until killed'
  echo "lock_acquire on an uncreatable path never returns"
}


t_pkgs_support_source_only_adds_five_definitions() {
  sandbox_new
  run_common -- '
    trap ": parent" EXIT
    compgen -A variable | sort > "$SB/vars.before"
    set +o > "$SB/options.before"
    trap -p > "$SB/traps.before"
    printf "%s" "$PATH" > "$SB/path.before"
    source "$PKGS_SUPPORT_SH" > "$SB/source.out"
    compgen -A variable | sort > "$SB/vars.after"
    set +o > "$SB/options.after"
    trap -p > "$SB/traps.after"
    printf "%s" "$PATH" > "$SB/path.after"
    for part in vars options traps path; do
      cmp "$SB/$part.before" "$SB/$part.after" || exit 1
    done
    test ! -s "$SB/source.out"
    declare -F | sed "s/declare -f //" | sort'
  assert_rc 0 "$RC" 'definitions-only source'
  assert_eq $'comp_fail\nempty_trash_bin\nlock_acquire\nlock_release\nlock_run\nput_into_trash_bin' "$OUT" 'exact exported functions'
}

t_pkgs_support_compiler_and_diagnostics_source_graph() {
  sandbox_new
  local f
  for f in make_cross-compiler.sh etc/common.sh etc/diagnostics.sh; do
    if grep -q pkgs-support "$CRS_ROOT/$f"; then fail "$f depends on package support"; fi
  done
  if grep -Eq '^[[:space:]]*(source|\.)[[:space:]]' "$PKGS_SUPPORT_SH"; then
    fail 'package support sources another script'
  fi
}

# Shared helpers for the infrastructure characterization tests.
# Sourced by run-infrastructure-tests.sh (discovery) and by each test process;
# never executed directly.  Tests only ever touch a disposable sandbox.
#
#   CRS_ROOT          checkout holding etc/common.sh, etc/diagnostics.sh and
#                     make_pkgs.sh (default: this repository).  Test discovery
#                     stays in this checkout.
#   INFRA_TEST_ROOT   per-test directory created and later removed by the
#                     runner (the surviving supervisor owns cleanup).  Without
#                     it, sandbox_new allocates and removes its own directory.
#
# Safety model (see tests/README.md):
#   * sandbox_new aborts the test process (exit 90) on any allocation or
#     validation failure, before the body can build a path from SB.  Test
#     processes run with nounset, so SB is unset, never empty, until then.
#   * Scripts under test run only through run_ctl: `env -i` with an explicit
#     variable list, PATH restricted to an allowlist of ordinary utilities plus
#     dedicated spies, a pinned (Linux) uname, HOME inside the sandbox, and no
#     Bash startup files.  Compilers, linkers, assemblers, downloaders and
#     installers are absent from PATH; well-known names are "forbidden" spies
#     whose invocation fails the test.
#   * run_ctl always runs under GNU timeout, which leads its own process group;
#     the group id is registered in INFRA_TEST_ROOT so the runner can sweep it
#     even if this test process is killed.

unset SB INFRA_OWN_ROOT
INFRA_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CRS_ROOT="${CRS_ROOT:-$(cd -- "$INFRA_HERE/../.." && pwd)}"
CRS_ROOT="$(cd -- "$CRS_ROOT" && pwd)"
export CRS_ROOT
export LC_ALL=C
# Never leak caller configuration into the scripts under test.
unset PREF NCRS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR MOCK_FAIL_CC MOCK_FAIL_TOOL

COMMON_SH="$CRS_ROOT/etc/common.sh"
DIAG_SH="$CRS_ROOT/etc/diagnostics.sh"
PKGS_SH="$CRS_ROOT/make_pkgs.sh"
export COMMON_SH DIAG_SH PKGS_SH

TRG32=i686-w64-mingw32
TRG64=x86_64-w64-mingw32

BASH_BIN="${BASH:-$(command -v bash)}"
ENV_BIN="$(command -v env)"
TIMEOUT_BIN="$(command -v timeout || true)"

# Ordinary utilities admitted into the controlled PATH.  Nothing that can
# compile, link, assemble, download or install software belongs here.
CTL_ALLOW=(bash sh dirname basename cat cp mv rm rmdir mkdir ln chmod touch date
  sleep sort find sed grep head tail tr wc od env mktemp realpath nproc tar gzip)
CTL_ALLOW_OPTIONAL=(xz)
# Names that resolve to a logging, failing spy instead of falling through.
CTL_FORBID=(gcc g++ cc c++ cpp clang clang++ clang-cpp as ld ld.bfd ld.gold ld.lld
  lld nasm yasm ar ranlib strip objcopy objdump nm windres dlltool make gmake
  meson ninja cmake autoreconf autoconf automake libtool
  curl wget git svn hg rsync scp ssh ftp
  apt apt-get dpkg dnf yum rpm zypper pacman apk brew port pip pip3 npm gem cargo go
  patch install sudo su)
for _t in gcc g++ cpp as ld ar ranlib strip windres dlltool objdump; do
  CTL_FORBID+=("$TRG32-$_t" "$TRG64-$_t")
done
unset _t

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
harness_abort() { echo "HARNESS-ERROR: $*" >&2; exit 90; }

# True for an existing, absolute, non-symlink directory owned by this user.
owned_dir() {
  [[ -n "${1:-}" && "$1" == /* && "$1" != / && -d "$1" && ! -L "$1" && -O "$1" ]]
}

# Physical path of an existing directory, or failure.  A name ending in a
# newline cannot round-trip through $(...) and is therefore rejected (the
# caller compares the result with the spelling it was given).
_phys_dir() { local r; r="$(cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1; printf '%s' "$r"; }

# Remove a tree only if it is physically contained in ROOT.  Rule (simple and
# auditable, ambiguous paths are rejected rather than normalized):
#   * ROOT is an owned, non-symlink directory equal to its own physical path;
#   * PATH is spelled ROOT/..., without empty, "." or ".." components;
#   * PATH's parent directory resolves physically to exactly its spelling, so
#     no component between ROOT and PATH is a symlink;
#   * PATH itself is an owned, non-symlink directory.
#   safe_rm_tree ROOT PATH
safe_rm_tree() {
  local root="${1:-}" p="${2:-}" parent
  owned_dir "$root" || { echo "refusing cleanup: bad root [$root]" >&2; return 1; }
  [[ "$(_phys_dir "$root")" == "$root" ]] || { echo "refusing cleanup: root [$root] is not a physical path" >&2; return 1; }
  [[ "$p" == "$root"/?* ]] || { echo "refusing cleanup: [$p] not inside [$root]" >&2; return 1; }
  [[ "$p/" != *//* && "$p/" != */./* && "$p/" != */../* ]] || { echo "refusing cleanup: [$p] has empty or dot components" >&2; return 1; }
  [[ -e "$p" || -L "$p" ]] || return 0
  parent="${p%/*}"
  [[ "$(_phys_dir "$parent")" == "$parent" ]] || { echo "refusing cleanup: [$p] has a symlinked or unresolvable ancestor" >&2; return 1; }
  owned_dir "$p" || { echo "refusing cleanup: [$p] is not an owned directory" >&2; return 1; }
  rm -rf -- "$p"
  [[ ! -e "$p" && ! -L "$p" ]] || { echo "cleanup failed: [$p]" >&2; return 1; }
}

_infra_exit() {
  local rc=$? j
  j="$(jobs -p)"
  # Direct background children only; the runner sweeps the whole group.
  [[ -z "$j" ]] || kill $j 2>/dev/null
  # Fallback mode only (no runner): remove the directory this process made.
  if [[ -n "${INFRA_OWN_ROOT:-}" && -z "${KEEP_SANDBOX:-}" ]]; then
    if [[ "${INFRA_OWN_ROOT##*/}" == crs-infra.?* ]] && owned_dir "$INFRA_OWN_ROOT"; then
      rm -rf -- "$INFRA_OWN_ROOT"
    else
      echo "refusing cleanup of [$INFRA_OWN_ROOT]" >&2
    fi
    if [[ -e "$INFRA_OWN_ROOT" || -L "$INFRA_OWN_ROOT" ]]; then
      echo "HARNESS-ERROR: sandbox cleanup failed: [$INFRA_OWN_ROOT]" >&2
      [[ "$rc" -ne 0 ]] || rc=90
    fi
  fi
  exit "$rc"
}

# Allocate the sandbox SB (physical path), TMPDIR=$SB/tmp and the controlled
# command directory CTL_BIN.  Any failure terminates the test process.
sandbox_new() {
  [[ -z "${SB+set}" ]] || harness_abort 'sandbox_new called twice'
  [[ -n "$TIMEOUT_BIN" ]] || skip 'GNU timeout is required'
  local root phys
  if [[ -n "${INFRA_TEST_ROOT:-}" ]]; then
    root="$INFRA_TEST_ROOT"
  else
    case "${TMPDIR:-/tmp}" in
      *:*) harness_abort "unsupported TMPDIR (contains ':'): [$TMPDIR]" ;;
    esac
    root="$(mktemp -d "${TMPDIR:-/tmp}/crs-infra.XXXXXX")" || harness_abort 'mktemp -d failed'
    [[ -n "$root" ]] || harness_abort 'mktemp -d returned an empty path'
    # Register for removal on exit only a directory that is really ours.
    if [[ "${root##*/}" == crs-infra.?* ]] && owned_dir "$root"; then
      INFRA_OWN_ROOT="$root"
      trap _infra_exit EXIT
    fi
  fi
  owned_dir "$root" || harness_abort "sandbox root is not an owned directory: [$root]"
  phys="$(cd -P -- "$root" && pwd -P)" || harness_abort "cannot resolve sandbox root [$root]"
  owned_dir "$phys" || harness_abort "resolved sandbox root is invalid: [$phys]"
  [[ -n "${INFRA_OWN_ROOT:-}" ]] && INFRA_OWN_ROOT="$phys"
  trap _infra_exit EXIT
  # A colon would split the controlled PATH ($SB/.ctl/bin) into two search
  # directories, one of them outside the sandbox: refuse before building it.
  [[ "$phys" != *:* ]] || harness_abort "unsupported sandbox path (contains ':'): [$phys]"
  mkdir -- "$phys/sb" || harness_abort "cannot create $phys/sb"
  owned_dir "$phys/sb" || harness_abort "sandbox is not an owned directory"
  SB="$phys/sb"
  export SB
  mkdir -- "$SB/tmp" "$SB/home" "$SB/.run" "$SB/.ctl" "$SB/.ctl/bin" || harness_abort 'cannot populate sandbox'
  export TMPDIR="$SB/tmp"
  ctl_init || harness_abort 'cannot build the controlled command directory'
}

# Build a directory of symlinks to the named real tools.
make_tool_dir() {  # make_tool_dir dir tool...
  local d="$1" t p; shift
  mkdir -p -- "$d"
  for t in "$@"; do
    p="$(command -v -- "$t")" || skip "host tool missing: $t"
    [[ "$p" == /* ]] || skip "host tool is not an executable file: $t"
    ln -s -- "$p" "$d/$t"
  done
}

# Write an executable file from stdin.
write_exe() { cat > "$1" && chmod +x -- "$1"; }

ctl_init() {
  CTL_BIN="$SB/.ctl/bin"
  FORBIDDEN_LOG="$SB/.ctl/forbidden.log"
  : > "$FORBIDDEN_LOG"
  make_tool_dir "$CTL_BIN" "${CTL_ALLOW[@]}"
  local t p
  for t in "${CTL_ALLOW_OPTIONAL[@]}"; do
    p="$(command -v -- "$t")" && [[ "$p" == /* ]] && ln -s -- "$p" "$CTL_BIN/$t"
  done
  # Pinned platform: MOCK_UNAME (default Linux) is what uname reports.
  printf '#!%s\nprintf "%%s\\n" "${MOCK_UNAME:-Linux}"\n' "$BASH_BIN" | write_exe "$SB/.ctl/uname"
  printf '#!%s\nexit 0\n' "$BASH_BIN" | write_exe "$SB/.ctl/pkg-config"
  cat > "$SB/.ctl/forbidden" <<SPY
#!$BASH_BIN
printf -v line 'FORBIDDEN|%q|argc=%d|' "\${0##*/}" "\$#"
(( \$# == 0 )) || printf -v args ' %q' "\$@"
printf '%s%s\n' "\$line" "\${args:-}" >> "\$FORBIDDEN_LOG"
exit 99
SPY
  chmod +x -- "$SB/.ctl/forbidden"
  ln -s ../uname "$CTL_BIN/uname"
  ln -s ../pkg-config "$CTL_BIN/pkg-config"
  for t in "${CTL_FORBID[@]}"; do
    [[ -e "$CTL_BIN/$t" ]] || ln -s ../forbidden "$CTL_BIN/$t"
  done
}

# Replace a controlled command with a different executable (spy or mock).
ctl_replace() {  # ctl_replace name target
  rm -f -- "$CTL_BIN/$1"
  ln -s -- "$2" "$CTL_BIN/$1"
}

# Wait until no member of process group $1 remains; escalate to KILL.
drain_group() {
  local g="$1" i
  for ((i = 0; i < 50; i++)); do
    kill -0 -- "-$g" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -TERM -- "-$g" 2>/dev/null
  for ((i = 0; i < 20; i++)); do kill -0 -- "-$g" 2>/dev/null || return 0; sleep 0.1; done
  kill -KILL -- "-$g" 2>/dev/null
  for ((i = 0; i < 20; i++)); do kill -0 -- "-$g" 2>/dev/null || return 0; sleep 0.1; done
  harness_abort "process group $g could not be reaped"
}

# Launch a command in the controlled environment, bounded by GNU timeout, in
# the background.  Shared by run_ctl and spawn_ctl.
#   _ctl_launch OUTFILE ERRFILE|"" [-t SECS] [-C DIR] [NAME=value | -NAME ...] -- cmd...
# ERRFILE "" merges stderr into OUTFILE.  Sets CTL_PID (= GNU timeout's
# process group id, registered for the runner's sweep).
_ctl_launch() {
  local outf="$1" errf="$2"; shift 2
  local secs=30 cwd="$SB" kv name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t) secs="$2"; shift 2 ;;
      -C) cwd="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local -A envmap=(
    [PATH]="$CTL_BIN" [HOME]="$SB/home" [TMPDIR]="$SB/tmp" [LC_ALL]=C [SB]="$SB"
    [PREF]="$SB/pref" [COMMON_SH]="$COMMON_SH" [DIAG_SH]="$DIAG_SH" [PKGS_SH]="$PKGS_SH"
    [BASH_BIN]="$BASH_BIN" [FORBIDDEN_LOG]="$FORBIDDEN_LOG"
  )
  while [[ $# -gt 0 && "$1" != -- ]]; do
    kv="$1"; shift
    if [[ "$kv" == -* ]]; then unset "envmap[${kv#-}]"; continue; fi
    [[ "$kv" == [A-Za-z_]*=* ]] || harness_abort "run_ctl: bad environment entry [$kv]"
    name="${kv%%=*}"
    envmap["$name"]="${kv#*=}"
  done
  [[ "${1:-}" == -- ]] || harness_abort 'run_ctl: missing --'
  shift
  [[ $# -gt 0 ]] || harness_abort 'run_ctl: missing command'
  local -a envs=()
  for name in "${!envmap[@]}"; do envs+=("$name=${envmap[$name]}"); done
  if [[ -n "$errf" ]]; then
    ( cd -- "$cwd" && exec "$TIMEOUT_BIN" -k 2 "$secs" "$ENV_BIN" -i "${envs[@]}" "$@" ) \
      < /dev/null > "$outf" 2> "$errf" &
  else
    ( cd -- "$cwd" && exec "$TIMEOUT_BIN" -k 2 "$secs" "$ENV_BIN" -i "${envs[@]}" "$@" ) \
      < /dev/null > "$outf" 2>&1 &
  fi
  CTL_PID=$!
  [[ -z "${INFRA_TEST_ROOT:-}" ]] || printf '%s\n' "$CTL_PID" >> "$INFRA_TEST_ROOT/.pgids"
}

# Wait for a launched command, then drain its process group.  Sets RC.
reap_ctl() {
  RC=0
  wait "$1" || RC=$?
  drain_group "$1"
}

_check_forbidden() {
  if [[ -z "${ALLOW_FORBIDDEN:-}" && -s "$FORBIDDEN_LOG" ]]; then
    fail "forbidden tool invoked: $(< "$FORBIDDEN_LOG")"
  fi
}

# Run a command in the controlled environment and wait for it.
#   run_ctl [-s] [-t SECS] [-C DIR] [NAME=value | -NAME ...] -- cmd [args...]
# -s keeps stdout (OUT; raw bytes in OUT_FILE) and stderr (ERR) apart;
# otherwise OUT holds both.  -NAME removes a default variable.  Sets RC.  An
# invocation of a forbidden tool fails the test unless ALLOW_FORBIDDEN is set.
run_ctl() {
  local errf=''
  OUT_FILE="$SB/.run/out"
  if [[ "${1:-}" == -s ]]; then shift; errf="$SB/.run/err"; : > "$errf"; fi
  : > "$OUT_FILE"
  _ctl_launch "$OUT_FILE" "$errf" "$@"
  reap_ctl "$CTL_PID"
  OUT="$(< "$OUT_FILE")"
  ERR=''
  [[ -z "$errf" ]] || ERR="$(< "$errf")"
  _check_forbidden
  return 0
}

# Start a controlled command in the background (output to OUTFILE).
#   spawn_ctl OUTFILE [options...] -- cmd...   -> SPAWN_PID; finish with reap_ctl
spawn_ctl() {
  local outf="$1"; shift
  _ctl_launch "$outf" '' "$@"
  SPAWN_PID="$CTL_PID"
}

# Convenience: run a Bash fragment in a FRESH controlled bash that sources
# common.sh first.  Paths are passed as positional arguments ($1...), never
# interpolated into the script text.
#   run_common [run_ctl options and NAME=value...] -- 'script' [args...]
run_common() {
  local -a opts=()
  while [[ $# -gt 0 && "$1" != -- ]]; do opts+=("$1"); shift; done
  shift
  local script="$1"; shift
  run_ctl "${opts[@]}" -- "$BASH_BIN" --noprofile --norc -c 'source "$COMMON_SH"; '"$script" _ "$@"
}

assert_eq() {  # assert_eq expected actual message
  [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"
}
assert_rc() {  # assert_rc expected actual message
  [[ "$1" == "$2" ]] || fail "$3: expected exit $1, got $2${OUT:+ (output: $OUT)}"
}
assert_contains() {  # assert_contains haystack needle message
  [[ "$1" == *"$2"* ]] || fail "${3:-missing text}: [$2] not in [$1]"
}
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "${3:-unexpected text}: [$2] found in [$1]"
}
assert_exists() { [[ -e "$1" || -L "$1" ]] || fail "${2:-missing path}: $1"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "${2:-unexpected path}: $1"; }

# Number of non-overlapping occurrences of $2 in $1 (byte-safe, no regex).
count_substr() {
  local hay="$1" needle="$2" n=0
  [[ -n "$needle" ]] || { echo 0; return; }
  while [[ "$hay" == *"$needle"* ]]; do hay="${hay#*"$needle"}"; n=$((n + 1)); done
  echo "$n"
}

# Number of lines of $1 that start with $2 (literal).
count_prefixed_lines() {
  local line n=0
  while IFS= read -r line; do [[ "$line" == "$2"* ]] && n=$((n + 1)); done <<< "$1"
  echo "$n"
}

# Replace every occurrence of the sandbox path in $1 with SB.
norm_sb() { local s="$1"; printf '%s' "${s//"$SB"/SB}"; }

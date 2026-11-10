# Shared helpers for the infrastructure characterization tests.
# Sourced by run-infrastructure-tests.sh and by each test process; never
# executed directly.  Tests only ever touch a disposable sandbox under TMPDIR.
#
#   CRS_ROOT   checkout holding etc/common.sh, etc/diagnostics.sh, make_pkgs.sh
#              (default: this repository).  Test discovery stays here.

INFRA_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CRS_ROOT="${CRS_ROOT:-$(cd -- "$INFRA_HERE/../.." && pwd)}"
CRS_ROOT="$(cd -- "$CRS_ROOT" && pwd)"
export CRS_ROOT
export LC_ALL=C
# Never leak caller configuration into the scripts under test.
unset PREF NCRS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR MOCK_FAIL_CC MOCK_SPY_LOG

COMMON_SH="$CRS_ROOT/etc/common.sh"
DIAG_SH="$CRS_ROOT/etc/diagnostics.sh"
PKGS_SH="$CRS_ROOT/make_pkgs.sh"
export COMMON_SH DIAG_SH PKGS_SH

TRG32=i686-w64-mingw32
TRG64=x86_64-w64-mingw32

# Create a fresh sandbox, remove it on exit, and make it the test's TMPDIR so
# stray mktemp files from the scripts under test are visible and contained.
sandbox_new() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/crs-infra.XXXXXX")" || return 1
  SB="$(cd -- "$SB" && pwd -P)"
  export SB
  mkdir -p "$SB/tmp"
  if [[ -z "${KEEP_SANDBOX:-}" ]]; then
    trap 'rm -rf -- "$SB"' EXIT
  fi
  export TMPDIR="$SB/tmp"
}

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }

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

# Build a directory of symlinks to the named real tools, for a controlled PATH.
make_tool_dir() {  # make_tool_dir dir tool...
  local d="$1" t p; shift
  mkdir -p "$d"
  for t in "$@"; do
    p="$(command -v "$t")" || skip "host tool missing: $t"
    ln -s "$p" "$d/$t"
  done
}

# Write an executable shell script.  Content comes from stdin.
write_exe() {
  cat > "$1"
  chmod +x "$1"
}

# Run a script fragment in a FRESH bash that sources common.sh first.
#   OUT = combined stdout+stderr, RC = exit status
# Extra environment can be passed as leading NAME=value arguments.  The shell
# is `bash -c`, so nothing leaks between invocations (common.sh must not be
# sourced twice in one shell: it declares readonly variables).
run_common() {  # run_common [NAME=value...] -- 'script'
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  RC=0
  OUT="$(env "PREF=$SB/pref" "${envs[@]}" bash -c 'source "$COMMON_SH"; '"$1" _ 2>&1)" || RC=$?
}

# Bash with a timeout, for anything that could wait on a lock.
#   run_bounded SECONDS env... bash -c ...
run_bounded() {
  local secs="$1"; shift
  RC=0
  OUT="$(timeout -k 2 "$secs" "$@" 2>&1)" || RC=$?
}

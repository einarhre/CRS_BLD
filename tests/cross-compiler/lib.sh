# shellcheck shell=bash
# Test support library for make_cross-compiler.sh regression tests.
#
# Safety model (see AGENTS.md):
#   * Every test runs in a fresh mktemp sandbox; PREF points inside it.
#   * make, zip, git, pkg-config are simulated by scripts placed first on PATH.
#     The source archives contain simulated configure scripts.
#   * Compilers, linkers and downloaders are replaced by "forbidden" shims that
#     log and fail, so an accidental real build is detected, not performed.
#   * Nothing outside the sandbox is ever deleted or modified.
#
# Expected behaviour comes only from the original script and
# docs/cross-compiler-resume-spec.md.

T32=i686-w64-mingw32
T64=x86_64-w64-mingw32
ORIG_PATH="$PATH"
REAL_MV="$(command -v mv)"
REAL_MKDIR="$(command -v mkdir)"

if [[ -z "${CRS_ROOT:-}" ]]
then
  CRS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# ---------------------------------------------------------------- failures

fail() {
  echo "ASSERTION FAILED: $*" >&2
  if [[ -n "${SB:-}" && -f "$SB/last.out" ]]
  then
    echo "--- last run (rc=${RC:-?}) output ---" >&2
    head -n 40 "$SB/last.out" >&2
    echo "--- end ---" >&2
  fi
  exit 1
}

# ---------------------------------------------------------------- sandbox

sandbox_cleanup() {
  [[ -n "${SB:-}" && -f "$SB/.crs-test-sandbox" ]] || return 0
  if [[ -n "${KEEP_SANDBOX:-}" ]]
  then
    echo "sandbox kept: $SB" >&2
    return 0
  fi
  rm -rf -- "$SB"
}

# new_sandbox [PREF-subpath]  (default "pref")
new_sandbox() {
  local sub="${1:-pref}"
  SB="$(mktemp -d "${TMPDIR:-/tmp}/crs-test.XXXXXX")" || exit 1
  SB="$(cd -- "$SB" && pwd -P)"
  : > "$SB/.crs-test-sandbox"
  trap sandbox_cleanup EXIT
  PREF="$SB/$sub"
  LOG="$SB/mock.log"
  : > "$LOG"
  SCRIPT_UNDER_TEST="$CRS_ROOT/make_cross-compiler.sh"
  RUNNO=0
  RC=0
  "$REAL_MKDIR" -p -- "$PREF/src/cpl" "$SB/bin" "$SB/mock" "$SB/stage" "$SB/home"
  install_mocks
}

# ---------------------------------------------------------------- mocks

install_mocks() {
  local f

  # ---- make: simulated, never compiles
  cat > "$SB/bin/make" <<'EOF'
#!/usr/bin/env bash
set -u
unset MOCK_MKDIR_FAIL_MATCH
cwd="$(pwd)"
rel="${cwd#"$PREF"/build/}"
kind="${rel%%/*}"; rest="${rel#*/}"; trg="${rest%%/*}"; comp="${rest#*/}"
jobs=""; targets=()
while [[ $# -gt 0 ]]
do
  case "$1" in
    -j) jobs="$2"; shift 2 ;;
    -j*) jobs="${1#-j}"; shift ;;
    *) targets+=("$1"); shift ;;
  esac
done
key="all"
[[ ${#targets[@]} -gt 0 ]] && key="${targets[*]}"
log() { printf 'make\t%s\t%s\t%s\t%s\n' "$rel" "$key" "$jobs" "$1" >> "$MOCK_LOG"; }
if [[ ! -f Makefile ]]
then
  log nomakefile
  echo "make: *** No targets specified and no makefile found.  Stop." >&2
  exit 2
fi
for spec in ${MOCK_FAIL:-}
do
  if [[ "$spec" == "make:$rel:$key" ]]
  then
    : > ".mock-partial-${key// /_}"
    log failed
    echo "make: *** simulated failure in $rel ($key)" >&2
    exit 2
  fi
done
case "$key" in
  install|install-*)
    status=ran
    ;;
  *)
    stamp=".mock-built-${key// /_}"
    if [[ -f "$stamp" ]]
    then
      status=uptodate
    else
      : > "$stamp"
      status=built
    fi
    ;;
esac
if [[ "$status" == ran ]]
then
  inst="$PREF/install/$kind/$trg"
  "$MOCK_REAL_MKDIR" -p -- "$inst/bin"
  : > "$inst/bin/.mock-installed-${comp//\//_}-${key// /_}"
  if [[ "$kind" == native && "$comp" == gcc && "$key" == install ]]
  then
    case "$trg" in
      i686-*) dll=libgcc_s_sjlj-1.dll ;;
      *) dll=libgcc_s_seh-1.dll ;;
    esac
    existing="$(find "$inst" -name "$dll" -type f | head -n 1)"
    case "${MOCK_DLL_MODE:-reinstall}" in
      reinstall)
        "$MOCK_REAL_MKDIR" -p -- "$inst/$trg/lib"
        echo "${MOCK_DLL_CONTENT:-$dll}" > "$inst/$trg/lib/$dll"
        ;;
      keep)
        if [[ -z "$existing" ]]
        then
          "$MOCK_REAL_MKDIR" -p -- "$inst/$trg/lib"
          echo "${MOCK_DLL_CONTENT:-$dll}" > "$inst/$trg/lib/$dll"
        fi
        ;;
      nodll) : ;;
    esac
  fi
fi
log "$status"
exit 0
EOF

  # ---- zip: simulated.  The archive operand may be a final name ("T" or
  # "T.zip") or a staged path ("<dir>/T.zip"); failure injection "zip:T" matches
  # on the archive's base name without ".zip", wherever it lives.  A failure
  # corrupts the archive *at the path it was given* (worst case), so an
  # implementation that zips straight over a valid archive is detected.
  cat > "$SB/bin/zip" <<'EOF'
#!/usr/bin/env bash
set -u
cwd="$(pwd)"
rel="${cwd#"$PREF"/}"
all="$*"
printf 'zip\t%s\t%s\n' "$rel" "${all//"$PREF"/@PREF@}" >> "$MOCK_LOG"
pos=()
for a in "$@"
do
  case "$a" in -*) ;; *) pos+=("$a") ;; esac
done
name="${pos[0]}"; input="${pos[1]:-}"
archive="$name"
[[ "$archive" == *.zip ]] || archive="${archive}.zip"
base="${name##*/}"; base="${base%.zip}"
for spec in ${MOCK_FAIL:-}
do
  if [[ "$spec" == "zip:$base" ]]
  then
    echo PARTIAL > "$archive"
    echo "zip error: simulated interruption" >&2
    exit 15
  fi
done
{ echo MOCKZIP; find "$input" -type f | LC_ALL=C sort; } > "$archive"
EOF

  # ---- git: simulated.  Upstream is $MOCK_UPSTREAM/{tree,commit}.  A checkout
  # is a plain directory with .git/FAKE_HEAD holding its commit id.
  #   clone [opts] URL [DEST]  copies the upstream tree to DEST (fresh mtimes);
  #                            DEST must not exist or be empty; MOCK_FAIL
  #                            git-clone / git-clone-partial make it fail (the
  #                            latter leaving a partial DEST behind)
  #   [-C DIR] rev-parse [--verify] HEAD   prints the commit id
  #   [-C DIR] pull|fetch      logged; fails with MOCK_FAIL=git-pull
  # Every call is logged ("git<TAB>args"); see git_mutations in lib.sh.
  cat > "$SB/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
a="$*"
printf 'git\t%s\n' "${a//"$PREF"/@PREF@}" >> "$MOCK_LOG"
dir=.
if [[ "${1:-}" == -C ]]
then
  dir="${2:-}"; shift 2
  if [[ ! -d "$dir" ]]
  then
    echo "fatal: cannot change to '$dir': No such file or directory" >&2
    exit 128
  fi
fi
sub="${1:-}"; [[ $# -gt 0 ]] && shift
case "$sub" in
  clone)
    pos=()
    while [[ $# -gt 0 ]]
    do
      case "$1" in
        --depth|-b|--branch|-c|--reference|-o|--origin|-j|--jobs) shift 2 ;;
        -*) shift ;;
        *) pos+=("$1"); shift ;;
      esac
    done
    url="${pos[0]:-}"; dest="${pos[1]:-}"
    [[ -n "$dest" ]] || dest="$(basename -- "${url%.git}")"
    case " ${MOCK_FAIL:-} " in
      *" git-clone "*) echo "fatal: unable to access '$url': simulated network failure" >&2; exit 128 ;;
      *" git-clone-partial "*)
        "$MOCK_REAL_MKDIR" -p -- "$dest"; echo partial > "$dest/PARTIAL_CLONE"
        echo "fatal: early EOF (simulated)" >&2; exit 128 ;;
    esac
    if [[ -e "$dest" ]] && [[ -n "$(ls -A -- "$dest" 2>/dev/null)" ]]
    then
      echo "fatal: destination path '$dest' already exists and is not an empty directory." >&2
      exit 128
    fi
    if [[ ! -d "${MOCK_UPSTREAM:-/nonexistent}/tree" ]]
    then
      echo "fatal: repository '$url' not found (no simulated upstream)" >&2
      exit 128
    fi
    "$MOCK_REAL_MKDIR" -p -- "$dest/.git"
    cp -R "$MOCK_UPSTREAM/tree/." "$dest/"
    cp "$MOCK_UPSTREAM/commit" "$dest/.git/FAKE_HEAD"
    ;;
  rev-parse)
    if [[ ! -f "$dir/.git/FAKE_HEAD" ]]
    then
      echo "fatal: not a git repository (or any of the parent directories): .git" >&2
      exit 128
    fi
    cat "$dir/.git/FAKE_HEAD"
    ;;
  pull|fetch)
    case " ${MOCK_FAIL:-} " in
      *" git-pull "*) echo "fatal: simulated pull failure" >&2; exit 1 ;;
    esac
    if [[ -d "${MOCK_UPSTREAM:-/nonexistent}/tree" && -d "$dir/.git" ]]
    then
      cp "$MOCK_UPSTREAM/commit" "$dir/.git/FAKE_HEAD"
      cp -R "$MOCK_UPSTREAM/tree/." "$dir/"
    fi
    ;;
esac
exit 0
EOF

  cat > "$SB/bin/pkg-config" <<'EOF'
#!/bin/sh
exit 0
EOF

  # ---- mv: optionally tolerant of "same file" moves, so that tests for other
  # requirements are not blocked by the DLL-relocation defect (see R6 tests,
  # which run with MOCK_MV_TOLERANT=0).
  cat > "$SB/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_MV_TOLERANT:-0}" == 1 ]]
then
  args=()
  for a in "$@"; do [[ "$a" == -- ]] || args+=("$a"); done
  if [[ ${#args[@]} -eq 2 ]]
  then
    src="${args[0]}"; dst="${args[1]}"
    [[ -d "$dst" ]] && dst="${dst%/}/$(basename -- "$src")"
    if [[ -f "$src" && -f "$dst" && "$src" -ef "$dst" ]]
    then
      exit 0
    fi
  fi
fi
exec "$MOCK_REAL_MV" "$@"
EOF

  # ---- mkdir: can simulate an interruption while creating directories
  cat > "$SB/bin/mkdir" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_MKDIR_FAIL_MATCH:-}" ]]
then
  for a in "$@"
  do
    if [[ "$a" == *"$MOCK_MKDIR_FAIL_MATCH"* ]]
    then
      echo "mkdir: simulated interruption creating '$a'" >&2
      exit 1
    fi
  done
fi
exec "$MOCK_REAL_MKDIR" "$@"
EOF

  # ---- tools that must never run during these tests
  for f in gcc cc c++ g++ ld ar ranlib curl wget
  do
    cat > "$SB/bin/$f" <<EOF
#!/bin/sh
printf 'FORBIDDEN\t$f\t%s\n' "\$*" >> "\$MOCK_LOG"
echo "forbidden tool invoked by test: $f" >&2
exit 99
EOF
  done

  # ---- simulated configure and download_prerequisites (placed in archives)
  cat > "$SB/mock/configure" <<'EOF'
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cwd="$(pwd)"
rel="${cwd#"$PREF"/build/}"
srcrel="${0#*src/cpl/}"; srcrel="${srcrel%/configure}"
id="$(cat "$here/IDENTITY")"
args="$*"; args="${args//"$PREF"/@PREF@}"
printf 'configure\t%s\t%s\t%s\t%s\n' "$rel" "$srcrel" "$id" "$args" >> "$MOCK_LOG"
# A real configure rewrites config.log from the very start.
printf 'config.log of attempt from %s\n' "$id" > config.log
for spec in ${MOCK_FAIL:-}
do
  case "$spec" in
    "configure:$rel")
      echo "FAILED-CONFIG-DIAG $rel" >> config.log
      echo partial > config.partial
      echo "configure: error: simulated failure in $rel" >&2
      exit 1
      ;;
    "configure-int:$rel")
      echo "INTERRUPTED-CONFIG-DIAG $rel" >> config.log
      exit 130
      ;;
  esac
done
rm -f config.partial
{ echo "configured-from $id"; echo "args $args"; } > Makefile
printf '#!/bin/sh\nexit 0\n' > config.status
chmod +x config.status
EOF



  cat > "$SB/mock/download_prerequisites" <<'EOF'
#!/usr/bin/env bash
dir="$(pwd -P)"
printf 'prereq\t%s\t%s\n' "$(basename -- "$dir")" "$*" >> "$MOCK_LOG"
case " ${MOCK_FAIL:-} " in
  *" prereq "*)
    echo "simulated prerequisite download failure" >&2
    : > .mock-prereqs-partial
    exit 1
    ;;
esac
: > .mock-prereqs-done
EOF
  chmod +x "$SB"/bin/* "$SB"/mock/*
}

# ---------------------------------------------------------------- fixtures

sb_rm() {
  local p
  for p in "$@"
  do
    [[ "$p" == "$SB"/* ]] || fail "refusing to remove outside sandbox: $p"
    rm -rf -- "$p"
  done
}

mk_configure_dir() { # dir identity
  "$REAL_MKDIR" -p -- "$1"
  echo "$2" > "$1/IDENTITY"
  cp "$SB/mock/configure" "$1/configure"
  chmod +x "$1/configure"
}

stage_gcc() { # version -> $SB/stage/gcc-VER
  local d="$SB/stage/gcc-$1"
  sb_rm "$d"
  mk_configure_dir "$d" "gcc-$1"
  "$REAL_MKDIR" -p -- "$d/contrib"
  cp "$SB/mock/download_prerequisites" "$d/contrib/download_prerequisites"
  chmod +x "$d/contrib/download_prerequisites"
}

stage_binutils() {
  local d="$SB/stage/binutils-$1"
  sb_rm "$d"
  mk_configure_dir "$d" "binutils-$1"
}

stage_mingw() {
  local d="$SB/stage/mingw-w64-v$1"
  sb_rm "$d"
  mk_configure_dir "$d" "mingw-w64-v$1"
  mk_configure_dir "$d/mingw-w64-headers" "mingw-w64-v$1"
  mk_configure_dir "$d/mingw-w64-libraries/winpthreads" "mingw-w64-v$1"
}

add_gcc_archive() {
  stage_gcc "$1"
  tar -czf "$PREF/src/cpl/gcc-$1.tar.gz" -C "$SB/stage" "gcc-$1"
}
add_binutils_archive() {
  stage_binutils "$1"
  tar -czf "$PREF/src/cpl/binutils-$1.tar.gz" -C "$SB/stage" "binutils-$1"
}
add_mingw_archive() {
  stage_mingw "$1"
  tar -czf "$PREF/src/cpl/mingw-w64-v$1.tar.gz" -C "$SB/stage" "mingw-w64-v$1"
}

# Two gcc releases, one binutils, one mingw-w64.
default_sources() {
  add_gcc_archive 13.2.0
  add_gcc_archive 14.1.0
  add_binutils_archive 2.42
  add_mingw_archive 11.0.0
}

# The simulated upstream gcc repository.  Content depends on the commit id, so
# that a fetch of a newer upstream is observable in the checkout.
add_git_upstream() { # commit-id
  stage_gcc git
  sb_rm "$SB/upstream"
  "$REAL_MKDIR" -p -- "$SB/upstream/tree"
  cp -R "$SB/stage/gcc-git/." "$SB/upstream/tree/"
  set_upstream_commit "$1"
}
set_upstream_commit() { # commit-id
  echo "$1" > "$SB/upstream/commit"
  echo "$1" > "$SB/upstream/tree/UPSTREAM_REV"
}

# A pre-existing git checkout (src/cpl/gcc-git) at the given commit, holding
# local work that only a user could have produced.
add_gcc_git_checkout() { # [commit-id]
  stage_gcc git
  "$REAL_MKDIR" -p -- "$PREF/src/cpl/gcc-git/.git"
  cp -R "$SB/stage/gcc-git/." "$PREF/src/cpl/gcc-git/"
  echo "${1:-old0000}" > "$PREF/src/cpl/gcc-git/.git/FAKE_HEAD"
  echo "valuable local commit" > "$PREF/src/cpl/gcc-git/LOCAL_WORK"
}

git_head() { cat "$PREF/src/cpl/gcc-git/.git/FAKE_HEAD"; }

# ---------------------------------------------------------------- running

# run_crs [VAR=value ...] -- [script arguments ...]
run_crs() {
  local -a envs=()
  while [[ $# -gt 0 && "$1" != -- ]]
  do
    envs+=("$1"); shift
  done
  [[ "${1:-}" == -- ]] && shift
  RUNNO=$((RUNNO + 1))
  printf 'run\t%s\t%s\n' "$RUNNO" "$*" >> "$LOG"
  set +e
  env "PREF=$PREF" "PATH=$SB/bin:$ORIG_PATH" "NCRS=2" "HOME=$SB/home" \
      "MOCK_LOG=$LOG" "MOCK_UPSTREAM=$SB/upstream" "MOCK_REAL_MV=$REAL_MV" "MOCK_REAL_MKDIR=$REAL_MKDIR" \
      "MOCK_MV_TOLERANT=1" "MOCK_DLL_MODE=reinstall" \
      ${envs[@]+"${envs[@]}"} \
      bash "$SCRIPT_UNDER_TEST" "$@" \
      > "$SB/out.$RUNNO" 2> "$SB/err.$RUNNO" < /dev/null
  RC=$?
  cat "$SB/out.$RUNNO" "$SB/err.$RUNNO" > "$SB/last.out"
  if grep -q '^FORBIDDEN' "$LOG"
  then
    fail "a forbidden (real build/download) tool was invoked: $(grep '^FORBIDDEN' "$LOG" | head -n 3)"
  fi
  return 0
}

build_ok() { # version [VAR=val ...]
  local v="$1"; shift
  run_crs "$@" -- "$v"
  assert_rc0 "build of $v"
}

# Make a variant copy of the script under test with sed-edited text.
make_script_variant() { # sed-expression
  local d="$SB/variant"
  "$REAL_MKDIR" -p -- "$d"
  cp "$CRS_ROOT/make_cross-compiler.sh" "$d/make_cross-compiler.sh"
  cp -R "$CRS_ROOT/etc" "$d/etc"
  sed -e "$1" "$CRS_ROOT/make_cross-compiler.sh" > "$d/make_cross-compiler.sh"
  if cmp -s "$CRS_ROOT/make_cross-compiler.sh" "$d/make_cross-compiler.sh"
  then
    fail "test bug: script variant expression changed nothing: $1"
  fi
  SCRIPT_UNDER_TEST="$d/make_cross-compiler.sh"
}

# ---------------------------------------------------------------- log access

# lines KIND [RUN]
lines() {
  awk -F'\t' -v k="$1" -v r="${2:-}" \
    '$1=="run"{cur=$2; next} $1==k && (r==""||cur==r)' "$LOG"
}
count() { lines "$@" | wc -l | tr -d ' '; }
configured_in_run() { # rel run -> count of configure invocations
  lines configure "$2" | awk -F'\t' -v r="$1" '$2==r' | wc -l | tr -d ' '
}

# Git calls of a run that can change or download anything.  Read-only queries
# (rev-parse, status, log ...) are harmless and ignored.
git_mutations() { # run
  lines git "$1" | awk -F'\t' '{
    n = split($2, w, " "); i = 1
    if (w[1] == "-C") i = 3
    sub_ = w[i]
    if (sub_ !~ /^(rev-parse|status|log|describe|diff|show|ls-files|symbolic-ref|cat-file|rev-list|config|remote)$/) print
  }'
}
git_mutation_count() { git_mutations "$1" | wc -l | tr -d ' '; }

rels_for() {
  local t="$1"
  printf '%s\n' "cross/$t/binutils" "cross/$t/mingw-w64-headers" "cross/$t/gcc" \
    "cross/$t/mingw-w64" "cross/$t/winpthreads" "native/$t/binutils" \
    "native/$t/gcc" "native/$t/mingw-w64"
}
all_rels() { rels_for "$T32"; rels_for "$T64"; }

dll_for() {
  case "$1" in i686-*) echo libgcc_s_sjlj-1.dll ;; *) echo libgcc_s_seh-1.dll ;; esac
}

# ---------------------------------------------------------------- snapshots

snapshot_dir() { # dir outfile
  (
    cd -- "$1" || exit 1
    {
      find . | LC_ALL=C sort
      find . -type f -exec cksum {} + | LC_ALL=C sort
      find . -type l | LC_ALL=C sort | while IFS= read -r l
      do
        printf '%s -> %s\n' "$l" "$(readlink "$l")"
      done
    }
  ) > "$2"
}
snapshot_pref() { snapshot_dir "$PREF" "$1"; }

assert_same_snapshot() { # a b message
  if ! diff -u "$1" "$2" > "$SB/snap.diff"
  then
    head -n 30 "$SB/snap.diff" >&2
    fail "${3:-tree changed unexpectedly}"
  fi
}

# Plant a marker file in every configured build directory (a stand-in for
# valuable compiled artifacts).  Records them for assert_sentinels_intact.
plant_sentinels() {
  local rel
  : > "$SB/sentinels.list"
  while IFS= read -r rel
  do
    if [[ -f "$PREF/build/$rel/Makefile" ]]
    then
      echo "compiled object for $rel" > "$PREF/build/$rel/artifact.o"
      echo "$rel" >> "$SB/sentinels.list"
    fi
  done < <(all_rels)
}
assert_sentinels_intact() { # message
  local rel n=0
  [[ -s "$SB/sentinels.list" ]] || fail "test bug: no sentinels planted"
  while IFS= read -r rel
  do
    n=$((n + 1))
    [[ -f "$PREF/build/$rel/artifact.o" ]] \
      || fail "${1:-artifact} lost: build/$rel/artifact.o"
    [[ "$(cat "$PREF/build/$rel/artifact.o")" == "compiled object for $rel" ]] \
      || fail "${1:-artifact} modified: build/$rel/artifact.o"
  done < "$SB/sentinels.list"
}

# Complete build of VER, then plant sentinels.
populate_state() { # [version]  (creates the sandbox)
  new_sandbox
  default_sources
  build_ok "${1:-14.1.0}"
  plant_sentinels
}

# Hand-craft a prepared source tree and build tree without running the script
# (used for states that earlier script versions could leave behind).
craft_sources() { # gcc-version [with-prereq-marker: yes|no]
  local v="$1" marker="${2:-yes}" c
  local cpl="$PREF/src/cpl"
  local m b
  m="$(ls "$cpl" | grep -E '^mingw-w64-v.*\.tar\.gz$' | sort -V | tail -n 1)"; m="${m%.tar.gz}"
  b="$(ls "$cpl" | grep -E '^binutils-.*\.tar\.gz$' | sort -V | tail -n 1)"; b="${b%.tar.gz}"
  for c in "$m" "$b" "gcc-$v"
  do
    "$REAL_MKDIR" -p -- "$cpl/$c"
    tar -xzf "$cpl/$c.tar.gz" --strip-components=1 -C "$cpl/$c"
  done
  ln -sfn "$m" "$cpl/mingw-w64"
  ln -sfn "$b" "$cpl/binutils"
  ln -sfn "gcc-$v" "$cpl/gcc"
  [[ "$marker" == yes ]] && : > "$cpl/gcc/.mock-prereqs-done"
  return 0
}
craft_build_tree() {
  local rel
  while IFS= read -r rel
  do
    "$REAL_MKDIR" -p -- "$PREF/build/$rel"
    echo "crafted" > "$PREF/build/$rel/config.log"
    echo "crafted Makefile" > "$PREF/build/$rel/Makefile"
  done < <(all_rels)
  "$REAL_MKDIR" -p -- "$PREF/install/cross/$T32" "$PREF/install/cross/$T64" \
    "$PREF/install/native/$T32" "$PREF/install/native/$T64"
}

# ---------------------------------------------------------------- assertions

assert_rc0() { [[ "$RC" -eq 0 ]] || fail "${1:-run} should succeed but exited $RC"; }
assert_rc_nonzero() { [[ "$RC" -ne 0 ]] || fail "${1:-run} should fail but exited 0"; }
assert_output_matches() { # regex [message]
  grep -Eiq -- "$1" "$SB/last.out" || fail "${2:-output} does not match /$1/"
}
assert_file() { [[ -e "$1" ]] || fail "${2:-missing file}: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "${2:-unexpected file}: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-values differ}: got '$1', expected '$2'"; }
assert_link() { # path expected-target-basename
  [[ -L "$1" ]] || fail "not a symlink: $1"
  assert_eq "$(basename -- "$(readlink "$1")")" "$2" "symlink $1"
  [[ -e "$1" ]] || fail "dangling symlink: $1"
}
assert_run_idle() { # run  -- no build/prep tool was executed in that run
  local k
  for k in make configure prereq zip
  do
    [[ "$(count "$k" "$1")" -eq 0 ]] \
      || fail "run $1 executed '$k' but should have been rejected first: $(lines "$k" "$1" | head -n 2)"
  done
  [[ "$(git_mutation_count "$1")" -eq 0 ]] \
    || fail "run $1 changed/fetched git state but should have been rejected first: $(git_mutations "$1" | head -n 2)"
}

# Sources fully prepared for gcc VER.
assert_sources_ready() { # version
  local cpl="$PREF/src/cpl" c
  assert_link "$cpl/gcc" "gcc-$1"
  [[ -x "$cpl/gcc/configure" ]] || fail "gcc sources incomplete"
  [[ -f "$cpl/gcc/.mock-prereqs-done" ]] || fail "gcc prerequisites were never downloaded successfully"
  for c in binutils mingw-w64
  do
    [[ -L "$cpl/$c" && -x "$cpl/$c/configure" ]] || fail "$c source link missing or broken"
  done
  [[ -x "$cpl/mingw-w64/mingw-w64-headers/configure" ]] || fail "mingw-w64-headers sources incomplete"
  [[ -x "$cpl/mingw-w64/mingw-w64-libraries/winpthreads/configure" ]] || fail "winpthreads sources incomplete"
}

# Both targets built and packaged.
assert_packaged() {
  local t
  for t in "$T32" "$T64"
  do
    assert_file "$PREF/install/native/$t.zip" "package"
    grep -q "^$t/bin/$(dll_for "$t")\$" "$PREF/install/native/$t.zip" \
      || fail "package for $t lacks bin/$(dll_for "$t")"
    [[ "$(head -n 1 "$PREF/install/native/$t.zip")" == MOCKZIP ]] \
      || fail "package for $t is partial/corrupt"
  done
}

# Shared by R2/R5 tests.  Accept either:
#   (a) rejection: non-zero exit, an explanation, build artifacts untouched; or
#   (b) success in which every directory that depends on the changed input was
#       configured again from the new source identity.
assert_safe_input_change() { # build-snapshot-before id-regex "rels..."
  local rel n
  if [[ "$RC" -ne 0 ]]
  then
    assert_output_matches 'compat|chang|differ|mismatch|stale|reus|inconsist|incomplete' \
      "rejection must explain itself"
    snapshot_dir "$PREF/build" "$SB/build.after"
    assert_same_snapshot "$1" "$SB/build.after" \
      "rejected reuse must not delete or modify build artifacts"
    return 0
  fi
  for rel in $3
  do
    n="$(configured_in_run "$rel" "$RUNNO")"
    [[ "$n" -ge 1 ]] || fail "build/$rel was silently reused although inputs changed"
    lines configure "$RUNNO" | awk -F'\t' -v r="$rel" '$2==r{print $4}' \
      | grep -Eq -- "$2" || fail "build/$rel not configured from $2"
  done
}

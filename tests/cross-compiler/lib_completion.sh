# shellcheck shell=bash
# Support library for the completion-cache regression tests
# (test_completion.sh, test_headers.sh).  Sourced by lib.sh.
#
# The completion cache is specified by behaviour only (see
# COMPLETION-CACHE-TESTS.md): where a record lives and how it is formatted is
# an implementation choice, so these helpers find the records by comparing the
# files a completed build leaves with the files the original implementation
# is known to leave.

CCV=13.2.0

# ---------------------------------------------------------------- prerequisites

_find_gnu_make() {
  local c
  for c in gmake make
  do
    c="$(command -v "$c" 2> /dev/null)" || continue
    if "$c" --version 2> /dev/null | grep -q 'GNU Make'
    then
      echo "$c"
      return 0
    fi
  done
  return 1
}
REAL_GNU_MAKE="$(_find_gnu_make || true)"

# Exit status 77 is reported as SKIP by the runner.
require_gnu_make() {
  [[ -n "$REAL_GNU_MAKE" ]] || { echo "SKIP: GNU make is required for this fixture"; exit 77; }
}
require_non_root() {
  [[ "$(id -u)" -ne 0 ]] || { echo "SKIP: permission checks are meaningless for root"; exit 77; }
}

# ---------------------------------------------------------------- record discovery

# Files the original implementation (and the simulated tools) leave behind.
# Everything else a completed build leaves under PREF (or HOME) is, by
# elimination, a completion record.
CC_KNOWN_RE='(^|/)(Makefile|config\.status|config\.log|config\.log\.previous\.[^/]*|config\.partial|\.cross-inputs|\.cross-prepared|\.cross-configured|\.mock-[^/]*|artifact\.o|[^/]*\.zip|[^/]*\.dll|IDENTITY|[^/]*\.[oh]|dllsrc|binutils-tool|cc1)$'

list_state_files() { # paths relative to $SB, sorted
  ( cd -- "$SB" && find "${PREF#"$SB"/}" home -path "${PREF#"$SB"/}/src" -prune -o -type f -print | LC_ALL=C sort )
}

# Remember which files are completion records, and their contents.
discover_records() {
  local f
  list_state_files | grep -Ev -- "$CC_KNOWN_RE" > "$SB/records.list" || true
  : > "$SB/records.sum"
  while IFS= read -r f
  do
    printf '%s\t%s\n' "$f" "$(cksum < "$SB/$f")" >> "$SB/records.sum"
  done < "$SB/records.list"
}

# Records belonging to one target: those whose path names the target; if no
# record path names any target, all of them.
records_for() { # target
  if grep -Eq 'i686-w64-mingw32|x86_64-w64-mingw32' "$SB/records.list"
  then
    grep -F -- "$1" "$SB/records.list" || true
  else
    cat "$SB/records.list"
  fi
}

assert_records_per_target() {
  local t
  [[ -s "$SB/records.list" ]] \
    || fail "a completed build left no completion record (no file besides the original implementation's state files)"
  for t in "$T32" "$T64"
  do
    [[ -n "$(records_for "$t")" ]] || fail "no completion record for $t (a record path must name its target)"
  done
  [[ "$(records_for "$T32")" != "$(records_for "$T64")" ]] \
    || fail "expected one completion record per target; both targets share the same file(s): $(cat "$SB/records.list" | tr '\n' ' ')"
}

# Apply a command to every record file of a target.
each_record() { # target command args...   (the record path is appended)
  local t="$1" f; shift
  while IFS= read -r f
  do
    [[ -n "$f" ]] || continue
    "$@" "$SB/$f"
  done < <(records_for "$t")
}

# ---------------------------------------------------------------- runs

# Like run_crs, but remembers when the run started (see assert_artifacts_untouched).
run_ref() {
  touch "$SB/ref"
  run_crs "$@"
}

# A completed build of both targets with its records identified.
cc_complete() {
  new_sandbox; default_sources
  build_ok "$CCV"
  discover_records
}

# A repeat without any change must be a pure cache hit.
cc_expect_hit() { # [VAR=val ...]
  run_ref "$@" -- "$CCV"
  assert_rc0 "unchanged repeat"
  assert_run_idle "$RUNNO"
  assert_packaged
  assert_artifacts_untouched
}

# ---------------------------------------------------------------- assertions

# The stage sequence of the original script, one "component make-target" per line
# (the same as expected_make_sequence in test_resume.sh, kept here so these tests
# do not depend on the order in which test files are loaded).
cc_stage_sequence() { # target
  local t="$1"
  printf '%s\n' \
    "cross/$t/binutils all" "cross/$t/binutils install" \
    "cross/$t/mingw-w64-headers install" \
    "cross/$t/gcc all-gcc" "cross/$t/gcc install-gcc" \
    "cross/$t/mingw-w64 all" "cross/$t/mingw-w64 install" \
    "cross/$t/gcc all" "cross/$t/gcc install" \
    "cross/$t/winpthreads all" "cross/$t/winpthreads install" \
    "native/$t/binutils all" "native/$t/binutils install" \
    "native/$t/gcc all" "native/$t/gcc install" \
    "native/$t/mingw-w64 all" "native/$t/mingw-w64 install"
}

target_make_seq() { # run target -> "rel key" lines
  lines make "$1" | awk -F'\t' -v t="$2" 'index($2, t) {print $2 " " $3}'
}
target_zip_count() { # run target
  lines zip "$1" | awk -F'\t' -v t="$2" 'index($3, t)' | wc -l | tr -d ' '
}
target_configure_count() { # run target
  lines configure "$1" | awk -F'\t' -v t="$2" 'index($2, t)' | wc -l | tr -d ' '
}

assert_target_idle() { # run target
  local seq
  seq="$(target_make_seq "$1" "$2")"
  [[ -z "$seq" ]] || fail "run $1 ran make for $2 although it was complete: $(printf '%s' "$seq" | head -n 2 | tr '\n' ';')"
  assert_eq "$(target_zip_count "$1" "$2")" 0 "run $1 repackaged $2 although it was complete"
  assert_eq "$(target_configure_count "$1" "$2")" 0 "run $1 configured $2 although it was complete"
}

# The existing recovery procedure (every stage, in order, then packaging) ran.
assert_target_replayed() { # run target
  local got want
  want="$(cc_stage_sequence "$2")"
  got="$(target_make_seq "$1" "$2")"
  if [[ "$got" != "$want" ]]
  then
    printf '%s\n' "$want" > "$SB/want.seq"; printf '%s\n' "$got" > "$SB/got.seq"
    diff -u "$SB/want.seq" "$SB/got.seq" | head -n 20 >&2
    fail "run $1 did not execute the full recovery procedure for $2"
  fi
  assert_eq "$(target_zip_count "$1" "$2")" 1 "run $1 must package $2 exactly once"
}

# Nothing under build/ or install/ was modified (mtime or ctime) since run_ref,
# except possibly the completion records themselves and their directories.
assert_artifacts_untouched() {
  local changed
  sed "s#^#$SB/#" "$SB/records.list" > "$SB/records.abs" 2> /dev/null || : > "$SB/records.abs"
  sed 's#/[^/]*$##' "$SB/records.abs" >> "$SB/records.abs"
  changed="$(find "$PREF/build" "$PREF/install" \( -newer "$SB/ref" -o -cnewer "$SB/ref" \) -print \
    | grep -Fvx -f "$SB/records.abs" | head -n 3 | tr '\n' ' ')"
  [[ -z "$changed" ]] || fail "a cache hit modified existing artifacts: $changed"
}

# The completion records of a target changed (or vanished) before the first
# tool that could modify the target ran.  Needs run_crs ... MOCK_SPY=1.
assert_records_invalidated_before_modification() { # target
  local f sum now
  [[ -f "$SB/spy.$1" ]] || fail "test bug: no modification of $1 was observed (MOCK_SPY=1 missing?)"
  while IFS= read -r f
  do
    [[ -n "$f" ]] || continue
    sum="$(awk -F'\t' -v p="./${f#"${PREF#"$SB"/}"/}" '$1 == p {print $2}' "$SB/spy.$1")"
    now="$(awk -F'\t' -v p="$f" '$1 == p {print $2}' "$SB/records.sum")"
    # A record still present and identical when the target was first modified
    # would let an interrupted run be taken for a completed one.
    if [[ -n "$sum" && "$sum" == "$now" ]]
    then
      fail "completion record $f was still valid when the first tool modified $1"
    fi
  done < <(records_for "$1")
}

# ---------------------------------------------------------------- mutations

# The file a mutation hits, per tree: build/cross, build/native, install/cross,
# install/native, zip.  All are regular, non-empty files that the build
# regenerates, so "repaired" can be asserted after deleting them.
cc_file_for() { # tree target
  case "$1" in
    bcross) echo "$PREF/build/cross/$2/binutils/.mock-built-all" ;;
    bnative) echo "$PREF/build/native/$2/gcc/.mock-built-all" ;;
    icross) echo "$PREF/install/cross/$2/bin/.mock-installed-binutils-install" ;;
    inative) echo "$PREF/install/native/$2/bin/.mock-installed-binutils-install" ;;
    zip) echo "$PREF/install/native/$2.zip" ;;
    *) fail "test bug: tree $1" ;;
  esac
}
cc_root_for() { # tree target
  case "$1" in
    bcross) echo "$PREF/build/cross/$2" ;;
    bnative) echo "$PREF/build/native/$2" ;;
    icross) echo "$PREF/install/cross/$2" ;;
    inative) echo "$PREF/install/native/$2" ;;
    *) fail "test bug: tree $1 has no root" ;;
  esac
}

# mutate KIND FILE [ROOT]
mutate() {
  local kind="$1" f="$2" root="${3:-}" ref="$SB/mt.ref"
  [[ -f "$f" && -s "$f" ]] || fail "test bug: mutation target missing or empty: $f"
  case "$kind" in
    delete) rm -f -- "$f" ;;
    add) printf 'extra\n' > "$(dirname -- "$f")/added-by-test.txt" ;;
    add_dir) mkdir -p -- "$root/added-dir-by-test" ;;
    grow) printf 'more\n' >> "$f" ;;
    # Same size, original mtime restored: only ctime (and content) can tell.
    samesize)
      touch -r "$f" "$ref"
      printf 'X' | dd of="$f" bs=1 count=1 conv=notrunc 2> /dev/null
      touch -r "$ref" "$f"
      [[ ! "$f" -nt "$ref" && ! "$ref" -nt "$f" ]] || fail "test bug: mtime not restored"
      ;;
    # New inode, same size/content/mode, original mtime restored.
    inode)
      touch -r "$f" "$ref"
      cp -p -- "$f" "$f.swap" && "$REAL_MV" -- "$f.swap" "$f"
      touch -r "$ref" "$f"
      ;;
    chmod) chmod 600 "$f" ;;
    # Permission flipped and restored: only ctime changes.
    chmod_restore) chmod u+x "$f"; chmod u-x "$f" ;;
    dirchmod) chmod 750 "$root" ;;
    mtime) touch -t 200001010000 "$f" ;;
    # Link count of the file changes through a link outside the trees: size,
    # mtime, mode and inode stay, ctime changes.
    hardlink) ln "$f" "$SB/outside-hardlink" ;;
    *) fail "test bug: mutation $kind" ;;
  esac
}

# ---------------------------------------------------------------- scan failure shims

# Pass-through shims for the tools a metadata scan could use.  With
# MOCK_SCAN_FAIL=<tool>, that tool fails (after emitting half or, with
# MOCK_SCAN_FAIL_MODE=full, all of its output) once a
# scan of a target tree was seen and before the first tool that modifies a target
# runs.  cksum is not shimmed: the original script uses it while configuring.
enable_scan_shims() {
  local t
  cat > "$SB/mock/scan-shim" <<'EOF'
#!/usr/bin/env bash
name="${0##*/}"
real="$(PATH="$MOCK_REAL_PATH" command -v "$name")" || exit 127
if [[ -n "${MOCK_SCAN_FAIL:-}" ]]
then
  case "$PWD $*" in
    *"$PREF/build/"*mingw32*|*"$PREF/install/"*mingw32*) : > "$MOCK_SB/scan.armed" ;;
  esac
  # Members of a pipeline start together: a consumer of a scan's output may run
  # before the producer was seen.  Wait a little for the flag when reading a pipe.
  if [[ "$MOCK_SCAN_FAIL" == "$name" && ! -t 0 && ! -e "$MOCK_SB/scan.armed" && ! -e "$MOCK_SB/scan.off" ]]
  then
    for _ in 1 2 3 4 5 6 7 8 9 10
    do
      [[ -e "$MOCK_SB/scan.armed" ]] && break
      sleep 0.02
    done
  fi
  if [[ "$MOCK_SCAN_FAIL" == "$name" && -e "$MOCK_SB/scan.armed" && ! -e "$MOCK_SB/scan.off" ]]
  then
    out="$("$real" "$@")"
    : > "$MOCK_SB/scan.hit"
    printf 'scanhit\t%s\n' "$name" >> "$MOCK_LOG"
    # half: truncated output; full: complete output but a failure status (e.g. a
    # late error), which an implementation ignoring exit statuses would accept.
    if [[ "${MOCK_SCAN_FAIL_MODE:-half}" == full ]]
    then
      printf '%s\n' "$out"
    else
      printf '%s\n' "${out:0:${#out}/2}"
    fi
    echo "simulated failure of $name" >&2
    exit 1
  fi
fi
exec "$real" "$@"
EOF
  for t in find stat sort xargs awk perl python3 sha256sum shasum sha512sum openssl ls readlink od uniq
  do
    PATH="$ORIG_PATH" command -v "$t" > /dev/null 2>&1 || continue
    cp "$SB/mock/scan-shim" "$SB/bin/$t"
    chmod +x "$SB/bin/$t"
  done
}

# ---------------------------------------------------------------- real-make fixture
#
# Replaces the simulated make/configure by a configure that writes real
# Makefiles and a make that runs GNU make on them.  Compilation is a fake
# compiler (fakecc: logs "cc<TAB>component<TAB>object" and writes the object).
# The model of the MinGW-w64 14.0.0 header problem:
#
#   stage 2   mingw-w64-headers install : placeholder pthread_{signal,time,unistd}.h
#             (84, 82 and 84 bytes) into the cross sysroot, with install -C
#   stage 6   winpthreads install       : the full headers (1304, 4768, 5012
#             bytes) into the same place
#   stage 9   native mingw-w64 install  : placeholders, then full headers
#
# Objects of the CRT, gcc (all), winpthreads and the native components depend on
# the cross sysroot headers, so replaying stages 2..6 rewrites the headers and
# invalidates (via make's own dependency evaluation) every dependent object.

HDR_FULL_SIZES="1304 4768 5012"
HDR_PLACEHOLDER_SIZES="84 82 84"
HDR_NAMES="pthread_signal.h pthread_time.h pthread_unistd.h"

use_real_make_fixture() { # call before default_sources
  require_gnu_make
  cat > "$SB/mock/configure" <<'EOF'
#!/usr/bin/env bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
cwd="$(pwd)"
rel="${cwd#"$PREF"/build/}"
srcrel="${0#*src/cpl/}"; srcrel="${srcrel%/configure}"
# shellcheck source=/dev/null
[[ -f "${MOCK_SB:-/nonexistent}/mock/spy.sh" ]] && . "$MOCK_SB/mock/spy.sh" && spy_mutation "$rel"
id="$(cat "$here/IDENTITY")"
args="$*"; args="${args//"$PREF"/@PREF@}"
printf 'configure\t%s\t%s\t%s\t%s\n' "$rel" "$srcrel" "$id" "$args" >> "$MOCK_LOG"
printf 'config.log of attempt from %s\n' "$id" > config.log
for spec in ${MOCK_FAIL:-}
do
  case "$spec" in
    "configure:$rel")
      echo "configure: error: simulated failure in $rel" >&2
      exit 1
      ;;
  esac
done
prefix=''; host=''; target=''; withlibs=''
for a in "$@"
do
  case "$a" in
    --prefix=*) prefix="${a#*=}" ;;
    --host=*) host="${a#*=}" ;;
    --target=*) target="${a#*=}" ;;
    --with-libraries=*) withlibs="${a#*=}" ;;
  esac
done
trg="${host:-$target}"
inst="${prefix%%/install/*}/install"
comp="${rel##*/}"; kind="${rel%%/*}"
case "$prefix" in
  */"$trg") hdr="$prefix/include" ;;
  *) hdr="$prefix/$trg/include" ;;
esac
xhdr="$inst/cross/$trg/$trg/include"
case "$trg" in i686-*) dll=libgcc_s_sjlj-1.dll ;; *) dll=libgcc_s_seh-1.dll ;; esac

mkh() { head -c "$2" /dev/zero | tr '\0' "$3" > "$1"; }
mkdir -p hdrsrc/placeholder hdrsrc/full
mkh hdrsrc/placeholder/pthread_signal.h 84 p
mkh hdrsrc/placeholder/pthread_time.h 82 p
mkh hdrsrc/placeholder/pthread_unistd.h 84 p
mkh hdrsrc/full/pthread_signal.h 1304 F
mkh hdrsrc/full/pthread_time.h 4768 F
mkh hdrsrc/full/pthread_unistd.h 5012 F
echo stdio > hdrsrc/placeholder/stdio.h
echo stdio > hdrsrc/full/stdio.h
echo "$dll" > dllsrc

objs="obj1.o obj2.o obj3.o"; objs1=''; hdeps=''
case "$comp" in
  gcc) objs1=cc1.o; objs="lib1.o lib2.o lib3.o"; hdeps=yes ;;
  mingw-w64-headers) objs='' ;;
  mingw-w64|winpthreads) hdeps=yes ;;
  binutils) [[ "$kind" == native ]] && hdeps=yes ;;
esac
hd=''
if [[ -n "$hdeps" ]]
then
  hd="$xhdr/pthread_signal.h $xhdr/pthread_time.h $xhdr/pthread_unistd.h"
fi

{
  echo '# CRS-REAL-MAKE'
  echo "REL = $rel"
  echo "PREFIX = $prefix"
  echo "HDR = $hdr"
  echo "TRG = $trg"
  echo "DLL = $dll"
  echo "OBJS = $objs"
  echo "OBJS1 = $objs1"
  echo ".PHONY: all all-gcc install install-gcc"
  echo 'all: $(OBJS) $(OBJS1)'
  echo 'all-gcc: $(OBJS1)'
  if [[ -n "$objs" ]]
  then
    echo "\$(OBJS): %.o: $hd"
    echo '@@fakecc "$(REL)" $@'
  fi
  if [[ -n "$objs1" ]]
  then
    echo '$(OBJS1): %.o:'
    echo '@@fakecc "$(REL)" $@'
  fi
  case "$comp" in
    binutils)
      echo 'install: all'
      echo '@@install -d $(PREFIX)/bin'
      echo '@@install -C -m 755 obj1.o $(PREFIX)/bin/binutils-tool'
      ;;
    mingw-w64-headers)
      echo 'install:'
      echo '@@install -d $(HDR)'
      echo '@@install -C -m 644 hdrsrc/placeholder/*.h $(HDR)/'
      ;;
    gcc)
      echo 'install-gcc: all-gcc'
      echo '@@install -d $(PREFIX)/bin'
      echo '@@install -C -m 755 cc1.o $(PREFIX)/bin/cc1'
      echo 'install: all'
      echo '@@install -d $(PREFIX)/bin $(PREFIX)/lib'
      echo '@@install -C -m 755 cc1.o $(PREFIX)/bin/cc1'
      echo '@@install -C -m 644 lib1.o lib2.o lib3.o $(PREFIX)/lib/'
      if [[ "$kind" == native ]]
      then
        echo '@@install -d $(PREFIX)/$(TRG)/lib'
        echo '@@install -C -m 755 dllsrc $(PREFIX)/$(TRG)/lib/$(DLL)'
      fi
      ;;
    mingw-w64)
      echo 'install: all'
      echo '@@install -d $(PREFIX)/lib'
      echo '@@install -C -m 644 obj1.o obj2.o obj3.o $(PREFIX)/lib/'
      if [[ -n "$withlibs" ]]
      then
        echo '@@install -d $(HDR)'
        echo '@@install -C -m 644 hdrsrc/placeholder/*.h $(HDR)/'
        echo '@@install -C -m 644 hdrsrc/full/*.h $(HDR)/'
      fi
      ;;
    winpthreads)
      echo 'install: all'
      echo '@@install -d $(HDR) $(PREFIX)/lib'
      echo '@@install -C -m 644 hdrsrc/full/*.h $(HDR)/'
      echo '@@install -C -m 644 obj1.o obj2.o obj3.o $(PREFIX)/lib/'
      ;;
  esac
} | awk '{ sub(/^@@/, "\t") } 1' > Makefile
printf '#!/bin/sh\nexit 0\n' > config.status
chmod +x config.status
EOF

  cat > "$SB/bin/fakecc" <<'EOF'
#!/usr/bin/env bash
rel="$1"; obj="$2"
printf 'cc\t%s\t%s\n' "$rel" "$obj" >> "$MOCK_LOG"
for spec in ${MOCK_FAIL:-}
do
  if [[ "$spec" == "cc:$rel:$obj" ]]
  then
    echo "fakecc: simulated compiler failure for $rel $obj" >&2
    exit 1
  fi
done
echo "object $obj of $rel" > "$obj.tmp.$$" && "$MOCK_REAL_MV" -- "$obj.tmp.$$" "$obj"
EOF

  # make: simulated failure injection and logging as in the simulated make,
  # but the work is done by GNU make on the generated Makefile.
  cat > "$SB/bin/make" <<'EOF'
#!/usr/bin/env bash
set -u
unset MOCK_MKDIR_FAIL_MATCH
cwd="$(pwd)"
rel="${cwd#"$PREF"/build/}"
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
# shellcheck source=/dev/null
[[ -f "${MOCK_SB:-/nonexistent}/mock/spy.sh" ]] && . "$MOCK_SB/mock/spy.sh" && spy_mutation "$rel"
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
    log failed
    echo "make: *** simulated failure in $rel ($key)" >&2
    exit 2
  fi
done
before="$(grep -c "^cc$(printf '\t')" "$MOCK_LOG")"
"$MOCK_GNU_MAKE" ${targets[@]+"${targets[@]}"}
rc=$?
after="$(grep -c "^cc$(printf '\t')" "$MOCK_LOG")"
if [[ $rc -ne 0 ]]
then
  log failed
elif [[ "$key" == install || "$key" == install-* ]]
then
  log ran
elif [[ "$after" -gt "$before" ]]
then
  log built
else
  log uptodate
fi
exit $rc
EOF
  chmod +x "$SB/bin/fakecc" "$SB/bin/make" "$SB/mock/configure"
}

# Run the fixture make by hand (outside the script under test).
fx_make() { # build-rel make-args...
  local rel="$1"; shift
  ( cd -- "$PREF/build/$rel" && env "PREF=$PREF" "PATH=$SB/bin:$ORIG_PATH" "MOCK_LOG=$LOG" \
      "MOCK_SB=$SB" "MOCK_GNU_MAKE=$REAL_GNU_MAKE" "MOCK_REAL_MV=$REAL_MV" \
      make "$@" > "$SB/fx.out" 2>&1 ) || { cat "$SB/fx.out" >&2; fail "fixture make $rel $* failed"; }
}

hdr_dir() { # cross|native target
  echo "$PREF/install/$1/$2/$2/include"
}
hdr_sizes() { # dir -> "1304 4768 5012"
  local h out=''
  for h in $HDR_NAMES
  do
    [[ -f "$1/$h" ]] || { echo "missing:$h"; return 0; }
    out="$out $(( $(wc -c < "$1/$h") ))"
  done
  echo "${out# }"
}
assert_full_headers() { # dir message
  assert_eq "$(hdr_sizes "$1")" "$HDR_FULL_SIZES" "${2:-pthread headers} in $1"
}
assert_placeholder_headers() { # dir
  assert_eq "$(hdr_sizes "$1")" "$HDR_PLACEHOLDER_SIZES" "placeholder pthread headers in $1"
}

# Objects compiled (rewritten) in a run.
objects_rewritten() { count cc "$1"; }

# Remember header mtimes (reference copies) of both targets' two sysroots.
hdr_remember() {
  local t k h
  for t in "$T32" "$T64"
  do
    for k in cross native
    do
      mkdir -p -- "$SB/hdrref/$k/$t"
      for h in $HDR_NAMES
      do
        [[ -f "$(hdr_dir "$k" "$t")/$h" ]] || continue
        touch -r "$(hdr_dir "$k" "$t")/$h" "$SB/hdrref/$k/$t/$h"
      done
    done
  done
}
assert_hdr_mtimes_unchanged() {
  local f k t h
  for f in "$SB"/hdrref/*/*/*
  do
    [[ -e "$f" ]] || fail "test bug: no header references"
    h="${f##*/}"; t="${f%/*}"; t="${t##*/}"; k="${f%/*/*}"; k="${k##*/}"
    [[ ! "$(hdr_dir "$k" "$t")/$h" -nt "$f" && ! "$f" -nt "$(hdr_dir "$k" "$t")/$h" ]] \
      || fail "header $h in the $k sysroot of $t was rewritten"
  done
}

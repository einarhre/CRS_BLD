"""Verified per-target completion cache: precision cases on the Python recovery fixtures.

Reuses the fixtures of test_cross_recovery.Recovery (tiny source archives and
simulated make/zip/configure; nothing is ever compiled).  The shell suite
(tests/cross-compiler/test_completion.sh, test_headers.sh) covers the broad
matrix; these tests add the cases that need nanosecond control of timestamps
(os.utime) and the existing Python mocks.  See
tests/cross-compiler/COMPLETION-CACHE-TESTS.md for the design under test.

Every test first requires a genuine cache hit, so none passes on an
implementation that always replays the stages.
"""
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_cross_recovery as base  # noqa: E402

T32 = "i686-w64-mingw32"
T64 = "x86_64-w64-mingw32"
VERSION = "12.2.0"
# Files the original implementation and the simulated tools leave behind.
KNOWN = {"Makefile", "config.status", "config.log", "object.keep",
         ".cross-inputs", ".cross-prepared", ".cross-configured"}


class Completion(unittest.TestCase):
    def setUp(self):
        self.fixture = base.Recovery("run_build")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.bin = self.fixture.bin

    # ---- helpers -----------------------------------------------------------

    def build(self, version=VERSION, ok=True, **env):
        return self.fixture.run_build(version, ok=ok, **env)

    def events(self):
        return self.fixture.events()

    def lines_for(self, target, kind=None):
        return [line for line in self.events().splitlines()
                if target in line and (kind is None or line.startswith(kind))]

    def zips(self):
        return [line for line in self.events().splitlines() if line.startswith("zip ")]

    def native(self, target):
        return self.root / "install/native" / target

    def archive(self, target):
        return self.root / "install/native" / (target + ".zip")

    def records(self):
        """Completion records, by elimination: files below build/ and install/
        (and dot files of PREF) that the original implementation never creates."""
        found = []
        for top in ("build", "install"):
            for dirpath, _dirs, files in os.walk(self.root / top):
                for name in files:
                    path = Path(dirpath) / name
                    if name in KNOWN or name.endswith(".zip") or name.endswith(".dll") \
                            or name.startswith(".cross-package"):
                        continue
                    found.append(path)
        for entry in self.root.iterdir():
            if entry.name.startswith(".") and entry.is_file():
                found.append(entry)
        return sorted(found)

    def records_for(self, target):
        named = [path for path in self.records() if target in str(path)]
        return named

    def tree_state(self):
        """High resolution metadata of everything the cache covers (and nothing else)."""
        state = {}
        skip = set(self.records())
        for top in ("build", "install"):
            for dirpath, dirs, files in os.walk(self.root / top):
                for name in dirs + files:
                    path = Path(dirpath) / name
                    if path in skip:
                        continue
                    info = path.lstat()
                    state[str(path)] = (info.st_ino, info.st_size, info.st_mode,
                                        info.st_mtime_ns, info.st_ctime_ns)
        return state

    def complete(self):
        self.build()
        self.assertTrue(self.records_for(T32) and self.records_for(T64),
                        "a completed build must leave one completion record per target")
        self.assertNotEqual(self.records_for(T32), self.records_for(T64))

    def assert_hit(self):
        events, state = self.events(), self.tree_state()
        self.build()
        self.assertEqual(events, self.events(), "an unchanged repeat must not run any tool")
        self.assertEqual(state, self.tree_state(), "an unchanged repeat must not modify artifacts")

    def assert_recovers(self, target, other, action):
        """Precondition: hit.  Apply the change; the target's stages and the
        packaging run again, the other target is left alone; then a hit again."""
        self.complete()
        self.assert_hit()
        action()
        before_target, before_other = len(self.lines_for(target)), len(self.lines_for(other))
        before_zips = len(self.zips())
        self.build()
        self.assertGreaterEqual(len(self.lines_for(target, "make")), 1)
        self.assertGreater(len(self.lines_for(target)), before_target, "target was not recovered")
        self.assertEqual(len(self.lines_for(other)), before_other, "the other target must not run")
        self.assertEqual(len(self.zips()) - before_zips, 1, "exactly the changed target is packaged")
        self.assert_hit()

    # ---- hits --------------------------------------------------------------

    def test_failed_invalidation_stops_before_target_mutation(self):
        self.complete()
        self.assert_hit()
        record = self.root / f"build/.cross-complete-{T32}"
        saved = record.read_bytes()
        (self.native(T32) / "changed").touch()
        real_rm = shlex.quote(shutil.which("rm"))
        before = self.events(), self.tree_state()
        for status in (1, 0):
            # Also reject a tool that claims success without removing the file.
            self.fixture.write_exec(self.bin / "rm", f'''#!/bin/bash
for arg in "$@"; do
  [[ $arg != "$PREF/build/.cross-complete-{T32}" ]] || exit {status}
done
exec {real_rm} "$@"
''')
            self.build(ok=False)
            self.assertEqual(record.read_bytes(), saved)
            self.assertEqual((self.events(), self.tree_state()), before)
        (self.bin / "rm").unlink()
        self.build()
        self.assert_hit()

    def test_failed_post_build_scan_never_publishes_record(self):
        real_stat = shlex.quote(shutil.which("stat"))
        self.fixture.write_exec(self.bin / "stat", f'''#!/bin/bash
{real_stat} "$@" || exit
case "$PWD" in "$PREF/build/"*|"$PREF/install/native") exit 1;; esac
''')
        self.build(ok=False)
        self.assertTrue(self.archive(T32).is_file())
        self.assertFalse((self.root / f"build/.cross-complete-{T32}").exists())
        (self.bin / "stat").unlink()
        before = len(self.lines_for(T32, "make"))
        self.complete()
        self.assertGreater(len(self.lines_for(T32, "make")), before)
        self.assert_hit()

    def test_unchanged_repeats_and_job_count_changes_do_nothing(self):
        self.complete()
        archives = {t: self.archive(t).read_bytes() for t in (T32, T64)}
        self.assert_hit()
        self.fixture.run_build(VERSION, NCRS="9")
        self.fixture.run_build(VERSION, NCRS="1")
        self.assert_hit()
        for target, content in archives.items():
            self.assertEqual(self.archive(target).read_bytes(), content)

    def test_invalid_job_count_is_still_rejected_with_a_cache(self):
        self.complete()
        events = self.events()
        for value in ("abc", "0", "-1", "1.5", ""):
            self.fixture.run_build(VERSION, NCRS=value, ok=False)
        self.assertEqual(events, self.events())

    # ---- timestamps, inodes, permissions, links, ownership ------------------

    def test_same_size_edit_with_restored_mtime_is_detected(self):
        def action():
            path = self.root / "build/cross" / T64 / "binutils/object.keep"
            info = path.stat()
            path.write_text("ORIGINAL\n")          # same 9 bytes as "original\n"
            self.assertEqual(path.stat().st_size, info.st_size)
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
            self.assertEqual(path.stat().st_mtime_ns, info.st_mtime_ns)
        self.assert_recovers(T64, T32, action)

    def test_same_size_edit_of_the_package_with_restored_mtime_is_detected(self):
        def action():
            path = self.archive(T32)
            info = path.stat()
            data = bytearray(path.read_bytes())
            data[0] ^= 0xFF
            path.write_bytes(bytes(data))
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
        self.assert_recovers(T32, T64, action)

    def test_replaced_inode_with_identical_content_size_and_mtime_is_detected(self):
        def action():
            path = self.root / "build/native" / T32 / "gcc/object.keep"
            if not path.exists():
                path = self.root / "build/cross" / T32 / "binutils/object.keep"
            info = path.stat()
            copy = path.with_name(path.name + ".swap")
            shutil.copy2(path, copy)
            os.replace(copy, path)
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
            self.assertNotEqual(path.stat().st_ino, info.st_ino)
        self.assert_recovers(T32, T64, action)

    def test_ctime_alone_invalidates(self):
        """A link outside the trees changes only the file's ctime (and link count)."""
        def action():
            path = self.root / "build/cross" / T64 / "binutils/object.keep"
            before = path.stat()
            os.link(path, self.root / "outside-link")
            after = path.stat()
            self.assertEqual((before.st_mtime_ns, before.st_size, before.st_ino, before.st_mode),
                             (after.st_mtime_ns, after.st_size, after.st_ino, after.st_mode))
            self.assertNotEqual(before.st_ctime_ns, after.st_ctime_ns)
        self.assert_recovers(T64, T32, action)

    def test_permission_flip_and_restore_invalidates_via_ctime(self):
        def action():
            path = self.root / "build/cross" / T32 / "binutils/object.keep"
            mode = stat.S_IMODE(path.stat().st_mode)
            path.chmod(0o600)
            path.chmod(mode)
        self.assert_recovers(T32, T64, action)

    def test_changed_directory_permissions_invalidate(self):
        def action():
            directory = self.native(T64) / "bin"
            mode = stat.S_IMODE(directory.stat().st_mode)
            directory.chmod(0o750)
            self.addCleanup(directory.chmod, mode)
        self.assert_recovers(T64, T32, action)

    def test_added_empty_directory_invalidates(self):
        self.assert_recovers(T32, T64, lambda: (self.root / "install/cross" / T32 / "added-dir").mkdir())

    def test_added_file_invalidates(self):
        self.assert_recovers(T32, T64, lambda: (self.root / "build/native" / T32 / "gcc/added.txt").write_text("x"))

    def test_altered_symlink_invalidates_even_with_restored_link_times(self):
        self.complete()
        link = self.root / "install/cross" / T64 / "link-by-test"
        os.symlink("alpha", link)                      # dangling is fine
        self.build()                                   # replayed: the tree changed
        self.assert_hit()
        info = os.lstat(link)
        os.unlink(link)
        os.symlink("bravo", link)                      # same length
        os.utime(link, ns=(info.st_atime_ns, info.st_mtime_ns), follow_symlinks=False)
        before = len(self.lines_for(T64))
        self.build()
        self.assertGreater(len(self.lines_for(T64)), before, "retargeted symlink went unnoticed")
        self.assertEqual(os.readlink(link), "bravo", "recovery must not touch the link")
        self.assert_hit()

    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0, "changing the owner needs root")
    def test_numeric_ownership_change_invalidates(self):
        def action():
            os.chown(self.root / "build/cross" / T32 / "binutils/object.keep", 12345, 12345)
        self.assert_recovers(T32, T64, action)

    def test_missing_artifacts_are_recovered_and_nothing_is_removed(self):
        self.complete()
        self.assert_hit()
        keep = self.root / "build/cross" / T32 / "binutils/object.keep"
        keep.write_text("preserve me")
        self.build()                                   # the edit is a change
        self.assert_hit()
        before = sorted(str(p) for p in (self.root / "build").rglob("*") if p.is_file())
        shutil.rmtree(self.native(T64) / "bin")
        self.build()
        self.assertTrue((self.native(T64) / "bin/libgcc_s_seh-1.dll").exists(), "install tree was not recovered")
        self.assertEqual(keep.read_text(), "preserve me")
        after = {str(p) for p in (self.root / "build").rglob("*") if p.is_file()}
        self.assertFalse(set(before) - after, "build artifacts were removed")
        self.assert_hit()

    # ---- records -----------------------------------------------------------

    def damaged_record_is_replayed(self, damage):
        def action():
            for record in self.records_for(T64):
                damage(record)
        self.assert_recovers(T64, T32, action)

    def test_missing_record(self):
        self.damaged_record_is_replayed(lambda p: p.unlink())

    def test_empty_record(self):
        self.damaged_record_is_replayed(lambda p: p.write_bytes(b""))

    def test_malformed_record(self):
        self.damaged_record_is_replayed(lambda p: p.write_text("not a completion record\n"))

    def test_truncated_record(self):
        self.damaged_record_is_replayed(lambda p: p.write_bytes(p.read_bytes()[: p.stat().st_size // 2]))

    def test_record_with_appended_data(self):
        self.damaged_record_is_replayed(lambda p: p.write_bytes(p.read_bytes() + b"surplus\n"))

    def test_record_with_appended_nul_is_rejected(self):
        self.damaged_record_is_replayed(lambda p: p.write_bytes(p.read_bytes() + b"\0"))

    def test_symlinked_record_is_never_trusted_or_written_through(self):
        copies = []

        def damage(path):
            copy = self.root / "record-copy"
            shutil.copy2(path, copy)
            copies.append((copy, copy.read_bytes()))
            path.unlink()
            path.symlink_to(copy)
        self.damaged_record_is_replayed(damage)
        for copy, content in copies:
            self.assertEqual(copy.read_bytes(), content, "the symlink target was overwritten")

    def test_record_of_the_other_target_is_rejected(self):
        self.complete()
        self.assert_hit()
        first, second = self.records_for(T32)[0], self.records_for(T64)[0]
        a, b = first.read_bytes(), second.read_bytes()
        first.write_bytes(b)
        second.write_bytes(a)
        before = len(self.lines_for(T32)), len(self.lines_for(T64))
        self.build()
        self.assertGreater(len(self.lines_for(T32)), before[0])
        self.assertGreater(len(self.lines_for(T64)), before[1])
        self.assert_hit()

    # ---- interruptions -----------------------------------------------------

    def test_first_target_complete_second_interrupted(self):
        self.build(FAIL_MAKE=f"cross/{T64}/gcc:-j 2 all-gcc", ok=False)
        archive = self.archive(T32).read_bytes()
        before = len(self.lines_for(T32))
        self.build()
        self.assertEqual(len(self.lines_for(T32)), before, "the finished target must not run again")
        self.assertEqual(self.archive(T32).read_bytes(), archive)
        self.assertTrue(self.records_for(T32) and self.records_for(T64))
        self.assert_hit()

    def test_interrupted_installation_and_compilation_are_not_completion(self):
        for stage, command in [(f"cross/{T32}/gcc", "-j 2 all-gcc"),
                               (f"native/{T64}/gcc", "install"),
                               (f"native/{T64}/mingw-w64", "install")]:
            with self.subTest(stage=stage):
                (self.root / "make-failed").unlink(missing_ok=True)
                shutil.rmtree(self.root / "build", ignore_errors=True)
                shutil.rmtree(self.root / "install", ignore_errors=True)
                self.build(FAIL_MAKE=stage + ":" + command, ok=False)
                self.build()
                self.assertTrue(self.records_for(T32) and self.records_for(T64))
                self.assert_hit()

    def test_interrupted_packaging_and_publication_are_not_completion(self):
        self.build(FAIL_ZIP="yes", ok=False)
        self.build()
        self.assertTrue(self.records_for(T32) and self.records_for(T64))
        self.assert_hit()

    def test_interrupted_dll_relocation_and_zip_publication(self):
        real_mv = shlex.quote(shutil.which("mv"))
        self.fixture.write_exec(self.bin / "mv", f'''#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    *"$FAIL_MV"*) if [[ -n ${{FAIL_MV:-}} ]]; then echo "simulated mv interruption" >&2; exit 1; fi ;;
  esac
done
exec {real_mv} "$@"
''')
        for marker in (f"{T64}/lib/libgcc", f"{T32}.zip"):
            with self.subTest(marker=marker):
                shutil.rmtree(self.root / "build", ignore_errors=True)
                shutil.rmtree(self.root / "install", ignore_errors=True)
                self.build(FAIL_MV=marker, ok=False)
                self.build()
                self.assertTrue(self.records_for(T32) and self.records_for(T64))
                self.assert_hit()

    # ---- failed or incomplete scans ------------------------------------------

    def test_failing_metadata_scan_is_never_accepted(self):
        real_find = shlex.quote(shutil.which("find"))
        make_text = base.MAKE.replace("set -eu\n", 'set -eu\ntouch "$MOCK_STATE/scan-off"\n', 1)
        self.fixture.write_exec(self.bin / "make", make_text)
        self.fixture.write_exec(self.bin / "find", f'''#!/bin/bash
if [[ -n ${{SCAN_FAIL:-}} && ! -e "$MOCK_STATE/scan-off" && "$PWD $*" == *mingw32* ]]; then
  touch "$MOCK_STATE/scan-hit"
  {real_find} "$@" | head -n 3
  exit 1
fi
exec {real_find} "$@"
''')
        self.complete()
        self.assert_hit()
        (self.root / "scan-off").unlink(missing_ok=True)
        before = len(self.lines_for(T32))
        self.build(SCAN_FAIL="1")
        if not (self.root / "scan-hit").exists():
            self.skipTest("find is not used by the metadata scan")
        self.assertGreater(len(self.lines_for(T32)), before, "a failed scan must trigger recovery")
        (self.root / "scan-off").unlink(missing_ok=True)
        self.assert_hit()

    # ---- compatibility checks still come first ---------------------------------

    def test_changed_inputs_are_refused_despite_a_complete_cache(self):
        self.complete()
        self.assert_hit()
        events = self.events()
        self.fixture.run_build(VERSION, CFLAGS="-O0", ok=False)
        with (self.root / "src/cpl" / ("gcc-" + VERSION) / "configure").open("a") as source:
            source.write("# local edit\n")
        self.fixture.run_build(VERSION, ok=False)
        self.assertEqual(events, self.events())
        for target in (T32, T64):
            for record in self.records_for(target):
                self.assertTrue(record.exists())

    def test_changed_build_logic_is_never_a_silent_hit(self):
        self.complete()
        self.assert_hit()
        script = self.root / "make_cross-compiler.sh"
        text = script.read_text()
        self.assertIn("--enable-languages=c,c++,fortran", text)
        script.write_text(text.replace("--enable-languages=c,c++,fortran", "--enable-languages=c,c++"))
        before = self.events()
        result = subprocess.run(["bash", str(script), VERSION], env=dict(self.fixture.env),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        if self.events() == before:
            self.assertNotEqual(result.returncode, 0, "changed configure options were taken for a completed build")
            self.assertRegex(result.stdout, r"(?i)chang|compat|differ|mismatch")

    # ---- git sources ---------------------------------------------------------------

    def test_git_repeat_is_a_hit_and_the_second_target_resumes(self):
        self.fixture.mock_git()
        self.build("git", FAIL_MAKE=f"cross/{T64}/gcc:-j 2 all-gcc", ok=False)
        (self.root / "git-head").write_text("new upstream\n")
        before = len(self.lines_for(T32))
        self.build("git")
        self.assertEqual(len(self.lines_for(T32)), before)
        self.assertEqual(self.events().count("clone"), 1)
        self.assertEqual((self.root / "src/cpl/gcc-git/.git/head").read_text(), "original\n")
        events, state = self.events(), self.tree_state()
        self.build("git")
        self.assertEqual(events, self.events())
        self.assertEqual(state, self.tree_state())

    def test_git_changed_checkout_is_refused_despite_a_cache(self):
        self.fixture.mock_git()
        self.build("git")
        self.assertTrue(self.records_for(T32) and self.records_for(T64))
        events = self.events()
        (self.root / "src/cpl/gcc-git/.git/head").write_text("changed locally\n")
        self.build("git", ok=False)
        self.assertEqual(events, self.events())


if __name__ == "__main__":
    unittest.main()

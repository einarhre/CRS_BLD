"""Isolated recovery tests: tiny source archives and simulated build/install tools."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tarfile
import tempfile
import unittest

# CRS_ROOT selects another checkout to test (same convention as run-cross-compiler-tests.sh).
ROOT = Path(os.environ.get("CRS_ROOT") or Path(__file__).resolve().parents[1]).resolve()

CONFIGURE = r'''#!/usr/bin/env bash
set -eu
stage=${PWD#"$PREF/build/"}
echo "configure $stage" >> "$MOCK_LOG"
echo diagnostic > config.log
if [[ ${FAIL_CONFIG:-} == "$stage" && ! -f "$MOCK_STATE/config-failed" ]]; then
  touch "$MOCK_STATE/config-failed"
  if [[ ${INTERRUPT:-} == yes ]]; then kill -TERM "$PPID"; fi
  exit 1
fi
touch Makefile config.status
'''
MAKE = r'''#!/usr/bin/env bash
set -eu
stage=${PWD#"$PREF/build/"}
echo "make $stage $*" >> "$MOCK_LOG"
[[ -f Makefile ]] || exit 91
if [[ ${FAIL_MAKE:-} == "$stage:$*" && ! -f "$MOCK_STATE/make-failed" ]]; then
  touch "$MOCK_STATE/make-failed"
  if [[ ${INTERRUPT:-} == yes ]]; then kill -TERM "$PPID"; fi
  exit 1
fi
[[ -f object.keep ]] || echo original > object.keep
if [[ $stage == native/*/gcc && $* == install ]]; then
  target=${stage#native/}; target=${target%/gcc}
  dll=libgcc_s_sjlj-1.dll
  [[ $target == i686* ]] || dll=libgcc_s_seh-1.dll
  mkdir -p "$PREF/install/native/$target/bin" "$PREF/install/native/$target/lib"
  if [[ ! -f $PREF/install/native/$target/bin/$dll ]]; then
    touch "$PREF/install/native/$target/lib/$dll"
  fi
fi
'''


class Recovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cross-recovery-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "etc").mkdir()
        shutil.copy(ROOT / "make_cross-compiler.sh", self.root)
        shutil.copy(ROOT / "etc/common.sh", self.root / "etc")
        self.cpl = self.root / "src/cpl"
        self.cpl.mkdir(parents=True)
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        self.write_exec(self.bin / "make", MAKE)
        self.write_exec(self.bin / "zip", '''#!/bin/bash
set -eu
echo "zip $*" >> "$MOCK_LOG"
archive=$3
[[ $archive == *.zip ]] || archive=$archive.zip
if [[ ${FAIL_ZIP:-} == yes ]]; then echo partial > "$archive"; exit 1; fi
echo complete > "$archive"
''')
        self.write_exec(self.bin / "pkg-config", '#!/bin/bash\nexit 0\n')
        self.env = dict(os.environ, PREF=str(self.root), NCRS="2", MOCK_LOG=str(self.root / "events"),
                        MOCK_STATE=str(self.root), PATH=str(self.bin) + ":" + os.environ["PATH"])
        for name in ("gcc-12.2.0", "binutils-2.40", "mingw-w64-v10.0.0"):
            self.archive(name)

    def write_exec(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    def archive(self, name, extension="gz"):
        source = self.root / "fixtures" / name
        self.write_exec(source / "configure", CONFIGURE)
        self.write_exec(source / "mingw-w64-headers/configure", CONFIGURE)
        self.write_exec(source / "mingw-w64-libraries/winpthreads/configure", CONFIGURE)
        self.write_exec(source / "contrib/download_prerequisites", '''#!/bin/bash
set -eu
echo prerequisites >> "$MOCK_LOG"
if [[ ${FAIL_PREP:-} == yes && ! -f "$MOCK_STATE/prep-failed" ]]; then
 touch "$MOCK_STATE/prep-failed"
 if [[ ${INTERRUPT:-} == yes ]]; then kill -KILL "$PPID"; fi
 exit 1
fi
''')
        with tarfile.open(self.cpl / f"{name}.tar.{extension}", "w:" + extension) as archive:
            archive.add(source, arcname=name)

    def run_build(self, *args, ok=True, **env):
        result = subprocess.run(["bash", str(self.root / "make_cross-compiler.sh"), *args],
                                env=dict(self.env, **env), text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def events(self):
        path = self.root / "events"
        return path.read_text() if path.exists() else ""

    def test_dll_new_install_precedes_bin_copy(self):
        self.run_build("12.2.0")
        for target, dll in (("i686-w64-mingw32", "libgcc_s_sjlj-1.dll"),
                            ("x86_64-w64-mingw32", "libgcc_s_seh-1.dll")):
            native = self.root / "install/native" / target
            (native / "bin" / dll).write_text("old")
            (native / "lib" / dll).write_text("new")
        # Deliberately return bin first regardless of filesystem traversal order.
        real_find = shlex.quote(shutil.which("find"))
        self.write_exec(self.bin / "find", '#!/bin/bash\n' +
                        f'if [[ $* == *libgcc_s_* ]]; then {real_find} "$@" | sort; else exec {real_find} "$@"; fi\n')
        self.run_build("12.2.0")
        for target in ("i686-w64-mingw32", "x86_64-w64-mingw32"):
            dll = "libgcc_s_sjlj-1.dll" if target.startswith("i686") else "libgcc_s_seh-1.dll"
            self.assertEqual((self.root / "install/native" / target / "bin" / dll).read_text(), "new")

    def test_compatibility_reports_changes_and_preserves_record(self):
        self.run_build("12.2.0")
        record = self.root / "build/.cross-inputs"
        original = record.read_bytes()
        output = self.run_build("12.2.0", CFLAGS="-O0", ok=False)
        self.assertIn("CFLAGS", output)
        self.assertIn("-O0", output)
        self.assertEqual(record.read_bytes(), original)
        self.archive("binutils-2.41")
        output = self.run_build("12.2.0", ok=False)
        self.assertIn("binutils-2.41", output)
        self.assertEqual(record.read_bytes(), original)

    def test_incidental_environment_and_script_edits_allow_resume(self):
        self.run_build("12.2.0")
        for path in (self.root / "make_cross-compiler.sh", self.root / "etc/common.sh"):
            with path.open("a") as script:
                script.write("# harmless comment\n")
        configurations = self.events().count("configure ")
        self.run_build("12.2.0", PATH=self.env["PATH"] + ":/unused", LANG="C",
                       LC_ALL="C", LC_CTYPE="C", MAKEFLAGS="-j8", MFLAGS="-j8")
        self.assertEqual(self.events().count("configure "), configurations)

    def test_unsupported_version_lists_available_choices(self):
        output = self.run_build("99.0.0", ok=False)
        self.assertIn("99.0.0", output)
        self.assertIn("12.2.0", output)
        self.assertIn("git", output)
        self.assertEqual(self.events(), "")

    def test_missing_link_with_damaged_sources_is_not_recreated(self):
        self.run_build("12.2.0")
        (self.cpl / "gcc").unlink()
        (self.cpl / "gcc-12.2.0/configure").write_text("damaged")
        before = self.events()
        self.run_build("12.2.0", ok=False)
        self.assertFalse((self.cpl / "gcc").is_symlink())
        self.assertEqual(before, self.events())

    def test_arguments_and_jobs(self):
        for args in [(), ("12.2.0", "extra"), ("2.2.0",), ("12.2",), ("bogus",)]:
            self.run_build(*args, ok=False)
            self.assertEqual(self.events(), "")
        for jobs in ("abc", "0", "-1", "1.5", "", "4097", "2147483648", "9" * 30):
            self.run_build("12.2.0", NCRS=jobs, ok=False)
            self.assertEqual(self.events(), "")

    def test_ncrs_canonical_and_default_jobs(self):
        for value, expected in (("007", "7"), ("08", "8"), ("010", "10"), ("4096", "4096")):
            with self.subTest(value=value):
                # Isolated fresh fixture so completion hits cannot mask job arguments.
                fixture = Recovery("run_build")
                fixture.setUp()
                try:
                    fixture.run_build("12.2.0", NCRS=value)
                    self.assertRegex(fixture.events(), r"make [^\n]+ -j " + expected + r"(?:\n| )")
                finally:
                    fixture.doCleanups()

    def test_ncrs_nproc_output_and_failure(self):
        self.env.pop("NCRS", None)
        for value, status in (("", 0), ("abc", 0), ("0", 0), ("7", 3)):
            self.write_exec(self.bin / "nproc", "#!/bin/sh\nprintf '%s' " + shlex.quote(value) + "\nexit " + str(status) + "\n")
            self.run_build("12.2.0", ok=False)
            self.assertEqual(self.events(), "")
        self.write_exec(self.bin / "nproc", "#!/bin/sh\necho 5000\n")
        output = self.run_build("12.2.0")
        self.assertIn("clamping to 4096", output)
        self.assertRegex(self.events(), r"make [^\n]+ -j 4096(?:\n| )")

    def test_archive_formats_and_ambiguity(self):
        (self.cpl / "gcc-12.2.0.tar.gz").unlink()
        self.archive("gcc-12.2.0", "xz")
        self.run_build("12.2.0")
        self.archive("gcc-12.2.0")
        before = self.events()
        self.run_build("12.2.0", ok=False)
        self.assertEqual(before, self.events())

    def test_preparation_failure_retries(self):
        self.run_build("12.2.0", FAIL_PREP="yes", ok=False)
        self.run_build("12.2.0")
        self.assertEqual(self.events().count("prerequisites"), 2)

    def test_configure_failure_and_interruption_retry(self):
        stage = "cross/i686-w64-mingw32/binutils"
        self.run_build("12.2.0", FAIL_CONFIG=stage, INTERRUPT="yes", ok=False)
        self.run_build("12.2.0")
        self.assertEqual(self.events().count("configure " + stage), 2)
        self.assertTrue(list((self.root / "build" / stage).glob("config.log.previous.*")))

    def test_failed_configure_retries(self):
        stage = "cross/i686-w64-mingw32/gcc"
        self.run_build("12.2.0", FAIL_CONFIG=stage, ok=False)
        self.run_build("12.2.0")
        self.assertEqual(self.events().count("configure " + stage), 2)

    def test_compilation_installation_and_second_target_recovery(self):
        for stage, command in [("cross/i686-w64-mingw32/gcc", "-j 2 all-gcc"),
                               ("native/x86_64-w64-mingw32/gcc", "install")]:
            target = stage.split("/")[1]
            record = self.root / f"build/.cross-complete-{target}"
            record.unlink(missing_ok=True)  # Exercise recovery, even after a complete run.
            self.run_build("12.2.0", FAIL_MAKE=stage + ":" + command, ok=False)
            artifact = self.root / "build/cross/i686-w64-mingw32/binutils/object.keep"
            artifact.write_text("preserve me")
            self.run_build("12.2.0")
            self.assertEqual(artifact.read_text(), "preserve me")
            (self.root / "make-failed").unlink()

    def test_repeat_completion_jobs_and_packaging(self):
        self.run_build("12.2.0", FAIL_ZIP="yes", ok=False)
        self.run_build("12.2.0")
        before = self.events()
        configurations = self.events().count("configure ")
        self.run_build("12.2.0", NCRS="3")
        self.assertEqual(configurations, self.events().count("configure "))
        self.assertEqual(before, self.events(), "completed repeat must run no tools")

    def test_changed_inputs_preserve_artifacts(self):
        self.run_build("12.2.0")
        before = self.events()
        self.run_build("12.2.0", CFLAGS="-O0", ok=False)
        self.assertEqual(before, self.events())
        with (self.cpl / "binutils-2.40.tar.gz").open("ab") as archive:
            archive.write(b"changed")
        self.run_build("12.2.0", ok=False)
        self.assertEqual(before, self.events())
        self.assertTrue((self.root / "build/cross/i686-w64-mingw32/binutils/object.keep").exists())

    def test_source_edits_rejected(self):
        self.run_build("12.2.0")
        before = self.events()
        with (self.cpl / "gcc-12.2.0/configure").open("a") as source:
            source.write("# local edit\n")
        self.run_build("12.2.0", ok=False)
        self.assertEqual(before, self.events())

    def test_legacy_artifacts_preserved(self):
        artifact = self.root / "build/cross/valuable.o"
        artifact.parent.mkdir(parents=True)
        artifact.write_text("valuable")
        self.run_build("12.2.0", ok=False)
        self.assertEqual(artifact.read_text(), "valuable")
        self.assertEqual(self.events(), "")

    def test_extraction_interruption_retries(self):
        real_tar = shlex.quote(shutil.which("tar"))
        self.write_exec(self.bin / "tar", f'''#!/bin/bash
if [[ ! -f "$MOCK_STATE/tar-failed" ]]; then
 touch "$MOCK_STATE/tar-failed"
 for arg in "$@"; do
  case "$arg" in --directory=*) touch "${{arg#--directory=}}/partial";; esac
 done
 exit 1
fi
exec {real_tar} "$@"
''')
        self.run_build("12.2.0", ok=False)
        partials = list(self.cpl.glob(".cross-extract.*/partial"))
        self.assertEqual(len(partials), 1)
        self.run_build("12.2.0")
        self.assertTrue(partials[0].exists())

    def test_killed_preparation_retries(self):
        self.run_build("12.2.0", FAIL_PREP="yes", INTERRUPT="yes", ok=False)
        self.run_build("12.2.0")
        self.assertEqual(self.events().count("prerequisites"), 2)

    def test_missing_configuration_outputs_retries(self):
        self.run_build("12.2.0")
        stage = "cross/i686-w64-mingw32/gcc"
        (self.root / "build" / stage / "Makefile").unlink()
        self.run_build("12.2.0")
        self.assertEqual(self.events().count("configure " + stage), 2)

    def test_missing_source_links_are_repaired(self):
        self.run_build("12.2.0")
        before = self.events()
        for name in ("mingw-w64", "binutils", "gcc"):
            (self.cpl / name).unlink()
        self.run_build("12.2.0")
        self.assertEqual(before.count("configure "), self.events().count("configure "))
        for name in ("mingw-w64", "binutils", "gcc"):
            self.assertTrue((self.cpl / name).is_symlink())

    def test_changed_version_and_newer_dependency_rejected(self):
        self.run_build("12.2.0")
        before = self.events()
        self.archive("gcc-13.1.0")
        self.run_build("13.1.0", ok=False)
        self.archive("binutils-2.41")
        self.run_build("12.2.0", ok=False)
        self.assertEqual(before, self.events())

    def test_changed_host_tool_rejected(self):
        self.run_build("12.2.0")
        before = self.events()
        with (self.bin / "make").open("a") as tool:
            tool.write("# updated tool\n")
        self.run_build("12.2.0", ok=False)
        self.assertEqual(before, self.events())

    def test_config_site_content_rejected(self):
        site = self.root / "config.site"
        site.write_text("# original\n")
        self.run_build("12.2.0", CONFIG_SITE=str(site))
        before = self.events()
        site.write_text("# changed\n")
        self.run_build("12.2.0", CONFIG_SITE=str(site), ok=False)
        self.assertEqual(before, self.events())

    def mock_git(self):
        self.write_exec(self.bin / "git", r'''#!/bin/bash
set -eu
if [[ $1 == clone ]]; then
 echo clone >> "$MOCK_LOG"
 [[ ${FAIL_CLONE:-} != yes ]] || { mkdir -p "${@: -1}"; exit 1; }
 cp -R "$MOCK_STATE/fixtures/gcc-12.2.0" "${@: -1}"
 mkdir "${@: -1}/.git"
 cp "$MOCK_STATE/git-head" "${@: -1}/.git/head"
elif [[ $1 == -C && $3 == rev-parse ]]; then
 cat "$2/.git/head"
else
 exit 99
fi
''')
        (self.root / "git-head").write_text("original\n")

    def test_git_continuation_pins_checkout_without_downloads(self):
        self.mock_git()
        self.run_build("git", FAIL_MAKE="cross/i686-w64-mingw32/gcc:-j 2 all-gcc", ok=False)
        checkout = self.cpl / "gcc-git"
        timestamp = (checkout / "configure").stat().st_mtime_ns
        (self.root / "git-head").write_text("new upstream\n")
        (self.cpl / "gcc").unlink()
        self.run_build("git")
        self.run_build("git")
        self.assertEqual(self.events().count("clone"), 1)
        self.assertEqual(self.events().count("prerequisites"), 1)
        self.assertEqual((checkout / ".git/head").read_text(), "original\n")
        self.assertEqual((checkout / "configure").stat().st_mtime_ns, timestamp)

    def test_git_changed_checkout_stops_without_downloads_or_record_changes(self):
        self.mock_git()
        self.run_build("git")
        record = self.root / "build/.cross-inputs"
        original = record.read_bytes()
        before = self.events()
        (self.cpl / "gcc-git/.git/head").write_text("changed locally\n")
        self.run_build("git", ok=False)
        self.assertEqual(self.events(), before)
        self.assertEqual(record.read_bytes(), original)

    def test_git_unverifiable_artifacts_do_not_clone(self):
        self.mock_git()
        artifact = self.root / "install/native/valuable"
        artifact.parent.mkdir(parents=True)
        artifact.write_text("preserve")
        self.run_build("git", ok=False)
        self.assertEqual(self.events(), "")
        self.assertEqual(artifact.read_text(), "preserve")

    def test_git_without_artifacts_downloads_replacement(self):
        self.mock_git()
        self.run_build("git", FAIL_PREP="yes", ok=False)
        self.run_build("git", FAIL_CONFIG="cross/i686-w64-mingw32/binutils", ok=False)
        shutil.rmtree(self.root / "build/cross")
        shutil.rmtree(self.root / "build/native")
        (self.root / "git-head").write_text("new upstream\n")
        self.run_build("git")
        self.assertEqual(self.events().count("clone"), 3)
        self.assertEqual((self.cpl / "gcc-git/.git/head").read_text(), "new upstream\n")
        self.assertFalse(list(self.cpl.glob(".cross-git.*")))

    def test_git_local_source_edits_stop_without_downloads(self):
        self.mock_git()
        self.run_build("git")
        source = self.cpl / "gcc-git/configure"
        source.write_text(source.read_text() + "# local work\n")
        before = self.events()
        output = self.run_build("git", ok=False)
        self.assertIn("prepared sources changed", output)
        self.assertEqual(self.events(), before)
        self.assertTrue(source.read_text().endswith("# local work\n"))

    def test_git_install_only_continuation_reuses_checkout(self):
        self.mock_git()
        self.run_build("git")
        shutil.rmtree(self.root / "build/cross")
        shutil.rmtree(self.root / "build/native")
        self.run_build("git")
        self.assertEqual(self.events().count("clone"), 1)
        self.assertEqual(self.events().count("prerequisites"), 1)

    def test_git_missing_checkout_stops_without_downloads(self):
        self.mock_git()
        self.run_build("git")
        # Move the test fixture aside to simulate a missing checkout.
        (self.cpl / "gcc-git").rename(self.cpl / "saved-checkout")
        before = self.events()
        self.run_build("git", ok=False)
        self.assertEqual(self.events(), before)

    def test_git_link_publication_failure_keeps_previous_sources(self):
        self.mock_git()
        checkout = self.cpl / "gcc-git"
        checkout.mkdir()
        (checkout / "local-work").write_text("preserve")
        real_ln = shlex.quote(shutil.which("ln"))
        self.write_exec(self.bin / "ln", f'''#!/bin/bash
if [[ $* == *gcc-git* ]]; then exit 1; fi
exec {real_ln} "$@"
''')
        self.run_build("git", ok=False)
        saved = list(self.cpl.glob(".cross-git.*/previous/local-work"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_text(), "preserve")

    def test_failed_clone_preserves_old_checkout(self):
        self.mock_git()
        checkout = self.cpl / "gcc-git"
        checkout.mkdir()
        (checkout / "valuable").write_text("old")
        self.run_build("git", FAIL_CLONE="yes", ok=False)
        self.assertEqual((checkout / "valuable").read_text(), "old")
        self.assertFalse(list(self.cpl.glob(".cross-git.*")))

    def test_input_change_without_artifacts_recovers(self):
        self.run_build("12.2.0", FAIL_PREP="yes", ok=False)
        self.archive("gcc-13.1.0")
        self.run_build("13.1.0")
        self.assertEqual(os.readlink(self.cpl / "gcc"), "gcc-13.1.0")

    def test_unverified_source_without_artifacts_is_saved(self):
        old = self.cpl / "gcc-12.2.0"
        old.mkdir()
        (old / "local-work").write_text("preserve")
        self.run_build("12.2.0")
        saved = list(self.cpl.glob(".cross-source-saved.*/source/local-work"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_text(), "preserve")

    def test_incomplete_preparation_with_install_artifacts_rejected(self):
        self.run_build("12.2.0", FAIL_PREP="yes", ok=False)
        artifact = self.root / "install/native/valuable"
        artifact.parent.mkdir(parents=True)
        artifact.write_text("preserve")
        before = self.events()
        self.run_build("12.2.0", ok=False)
        self.assertEqual(before, self.events())
        self.assertEqual(artifact.read_text(), "preserve")

    def test_missing_prepared_sources_without_artifacts_recover(self):
        self.run_build("12.2.0", FAIL_CONFIG="cross/i686-w64-mingw32/binutils", ok=False)
        # Simulate preparation completed but no build/configure ever started.
        shutil.rmtree(self.root / "build/cross")
        shutil.rmtree(self.root / "build/native")
        (self.cpl / "gcc").unlink()
        self.run_build("12.2.0")

    def test_damaged_prepared_tree_without_artifacts_is_reextracted(self):
        self.run_build("12.2.0", FAIL_CONFIG="cross/i686-w64-mingw32/binutils", ok=False)
        shutil.rmtree(self.root / "build/cross")
        shutil.rmtree(self.root / "build/native")
        (self.cpl / "gcc-12.2.0/configure").unlink()
        self.run_build("12.2.0")
        self.assertTrue((self.cpl / "gcc-12.2.0/configure").is_file())
        self.assertTrue(list(self.cpl.glob(".cross-source-saved.*/source")))

    def test_packaging_cleans_staging_on_failure(self):
        self.run_build("12.2.0", FAIL_ZIP="yes", ok=False)
        self.assertFalse(list((self.root / "install/native").glob(".cross-package.*")))

    def test_artifact_scan_failure_stops_before_preparation(self):
        real_find = shlex.quote(shutil.which("find"))
        (self.root / "install/native").mkdir(parents=True)
        self.write_exec(self.bin / "find", f'''#!/bin/bash
if [[ $1 == "$PREF/install/native" ]]; then exit 1; fi
exec {real_find} "$@"
''')
        self.run_build("12.2.0", ok=False)
        self.assertEqual(self.events(), "")

    def test_git_preparation_failure_preserves_old_checkout(self):
        self.mock_git()
        checkout = self.cpl / "gcc-git"
        checkout.mkdir()
        (checkout / "local-work").write_text("old")
        self.run_build("git", FAIL_PREP="yes", ok=False)
        self.assertEqual((checkout / "local-work").read_text(), "old")
        self.assertFalse(list(self.cpl.glob(".cross-git.*")))
        self.run_build("git")
        self.assertEqual(self.events().count("clone"), 2)

    def test_failed_git_publication_restores_checkout(self):
        self.mock_git()
        checkout = self.cpl / "gcc-git"
        checkout.mkdir()
        (checkout / "local-work").write_text("old")
        real_mv = shlex.quote(shutil.which("mv"))
        self.write_exec(self.bin / "mv", f'''#!/bin/bash
if [[ $2 == */.cross-git.*/source ]]; then exit 1; fi
exec {real_mv} "$@"
''')
        self.run_build("git", ok=False)
        self.assertEqual((checkout / "local-work").read_text(), "old")
        self.assertFalse(list(self.cpl.glob(".cross-git.*")))

    def test_install_only_changed_inputs_rejected(self):
        self.run_build("12.2.0")
        shutil.rmtree(self.root / "build/cross")
        shutil.rmtree(self.root / "build/native")
        self.archive("gcc-13.1.0")
        before = self.events()
        self.run_build("13.1.0", ok=False)
        self.assertEqual(self.events(), before)

    @unittest.skipUnless(shutil.which("zip") and shutil.which("unzip"), "requires Info-ZIP")
    def test_real_zip_repeatability_and_removal(self):
        self.write_exec(self.bin / "zip", "#!/bin/bash\nexec " + shlex.quote(shutil.which("zip")) + ' "$@"\n')
        target = "i686-w64-mingw32"
        native = self.root / "install/native"
        payload = native / target / "obsolete"
        payload.parent.mkdir(parents=True)
        payload.write_text("old")
        # Existing install files require records, so first create a compatible build.
        payload.unlink()
        self.run_build("12.2.0")
        payload.write_text("old")
        self.run_build("12.2.0")
        archive = native / (target + ".zip")
        original = archive.read_bytes()
        self.run_build("12.2.0")
        self.assertEqual(original, archive.read_bytes())
        payload.unlink()
        self.run_build("12.2.0")
        listing = subprocess.check_output(["unzip", "-Z1", str(archive)], text=True)
        self.assertNotIn("obsolete", listing)
        self.assertIn(target + "/bin/libgcc_s_sjlj-1.dll", listing)
        self.assertFalse(list(native.glob(".cross-package.*")))

    def test_packaging_term_preserves_archive_and_cleans_staging(self):
        self.run_build("12.2.0")
        archive = self.root / "install/native/i686-w64-mingw32.zip"
        (self.root / "install/native/i686-w64-mingw32/recovery-trigger").touch()
        self.write_exec(self.bin / "zip", '''#!/bin/bash
echo partial > "$3"
kill -TERM "$PPID"
exit 1
''')
        self.run_build("12.2.0", ok=False)
        self.assertEqual(archive.read_text(), "complete\n")
        self.assertFalse(list(archive.parent.glob(".cross-package.*")))

    def test_interrupted_packaging_does_not_publish_partial_archive(self):
        self.run_build("12.2.0", FAIL_ZIP="yes", ok=False)
        archive = self.root / "install/native/i686-w64-mingw32.zip"
        self.assertFalse(archive.exists())
        self.run_build("12.2.0")
        self.assertEqual(archive.read_text(), "complete\n")
        (self.root / "install/native/i686-w64-mingw32/recovery-trigger").touch()
        self.run_build("12.2.0", FAIL_ZIP="yes", ok=False)
        self.assertEqual(archive.read_text(), "complete\n")
        self.run_build("12.2.0")

    def test_simulated_macos_tool_setup(self):
        self.write_exec(self.bin / "uname", '''#!/bin/bash
if [[ $1 == -s ]]; then echo Darwin; else echo "Darwin arm64"; fi
''')
        self.write_exec(self.bin / "brew", '#!/bin/bash\necho "$MOCK_STATE/homebrew"\n')
        self.run_build("12.2.0")
        self.run_build("12.2.0")


if __name__ == "__main__":
    unittest.main()

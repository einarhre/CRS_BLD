"""Field-level checks of the production serializer, without running a build."""
import datetime
import os
from pathlib import Path
import subprocess
import shutil
import shlex
import tempfile
import unittest


ROOT = Path(os.environ.get("CRS_ROOT") or Path(__file__).resolve().parents[1])
SCRIPT = (ROOT / "make_cross-compiler.sh").read_text()
FUNCTIONS = SCRIPT[SCRIPT.index("function completion_capabilities()"):
                   SCRIPT.index("completion_enabled=no")]


class Metadata(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="completion-metadata-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def shell(self, code, *args, ok=True):
        result = subprocess.run(["bash", "-euo", "pipefail", "-c",
                                 'completion_script="$1"; shift; ' + FUNCTIONS + code, "metadata-test",
                                 str(ROOT / "make_cross-compiler.sh"), *map(str, args)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout

    def test_all_serialized_fields_and_hostile_names(self):
        self.shell("completion_capabilities")
        names = ["ordinary", "line\nbreak", "tab\tquote'", "-option", "back\\slash"]
        for name in names:
            (self.root / name).write_bytes(b"abc")
        (self.root / "empty").mkdir()
        (self.root / "link").symlink_to("line\nbreak")
        (self.root / "ordinary").chmod(0o6751)
        os.utime(self.root / "ordinary", ns=(1700000000123456789,
                                             1700000000987654321))
        data = self.shell('completion_tree_metadata "$1"', self.root)
        fields = data.split(b"\0")
        self.assertEqual(fields.pop(), b"")
        paths = ["."] + sorted("./" + name for name in os.listdir(self.root))
        self.assertEqual(len(fields), 11 * len(paths))
        for i, path in enumerate(paths):
            values = fields[i * 11:(i + 1) * 11]
            st = os.lstat(self.root / path)
            self.assertEqual([int(values[0], 16)] + [int(value, 8 if j == 4 else 10)
                                                 for j, value in enumerate(values[1:8], 1)],
                             [st.st_mode, st.st_dev, st.st_ino, st.st_size,
                              st.st_mode & 0o7777, st.st_uid, st.st_gid, st.st_nlink])
            for value, ns in zip(values[8:10], [st.st_mtime_ns, st.st_ctime_ns]):
                seconds, fraction = divmod(ns, 10**9)
                stamp = datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc)
                expected = stamp.strftime("%Y-%m-%d %H:%M:%S") + f".{fraction:09d} +0000"
                self.assertEqual(value.decode(), expected)
            # Verify quoting round trips both the relative name and link target.
            quoted = values[10].decode()
            words = self.shell("printf '%s\\0' " + quoted.replace(" -> ", " "))
            expected = [path.encode()]
            if os.path.islink(self.root / path):
                expected.append(os.readlink(self.root / path).encode())
            self.assertEqual(words.split(b"\0")[:-1], expected)
        self.assertEqual(data, self.shell('completion_tree_metadata "$1"', self.root))

    def test_late_scan_failure_is_propagated(self):
        # Emit complete valid metadata, then fail: output alone cannot bless it.
        shim = self.root / "stat"
        shim.write_text("#!/bin/bash\n" + shlex.quote(shutil.which("stat")) +
                        ' "$@"\nexit 1\n')
        shim.chmod(0o755)
        self.shell('PATH="$1:$PATH"; completion_tree_metadata "$1"',
                   self.root, ok=False)

    def test_record_creation_rejects_failed_scan_and_digest(self):
        for failure in [
                'completion_snapshot() { printf plausible; return 1; };',
                'completion_snapshot() { printf plausible; }; '
                'sha256sum() { command sha256sum; return 1; };',
                'completion_snapshot() { printf plausible; }; '
                'sha256sum() { printf garbage; };']:
            self.assertEqual(self.shell('completion_policy=test; ' + failure +
                                        ' completion_record_contents target', ok=False), b"")

    def test_non_gnu_tool_disables_caching(self):
        self.shell('stat() { echo "BSD stat"; }; completion_capabilities', ok=False)

    def test_unsupported_quoting_style_disables_caching(self):
        self.shell('stat() { '
                   'if [[ ${QUOTING_STYLE-} == shell-escape-always ]]; then '
                   'echo "unsupported quoting style" >&2; fi; '
                   'command stat "$@"; }; completion_capabilities', ok=False)


if __name__ == "__main__":
    unittest.main()

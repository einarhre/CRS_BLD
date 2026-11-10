"""Lock lifecycle probes: isolated paths, bounded process groups, no build tools."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(os.environ.get("CRS_ROOT", Path(__file__).resolve().parents[1]))


class LockSignals(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="crs-lock-signals-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("bash", "sh", "mkdir", "rmdir", "sleep", "sed"):
            real = shutil.which(tool)
            if not real:
                self.skipTest("requires " + tool)
            (self.bin / tool).symlink_to(real)
        self.env = dict(PATH=str(self.bin), SB=str(self.root), LC_ALL="C")
        self.processes = []
        self.addCleanup(self.stop)

    def stop(self):
        for proc in self.processes:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate(timeout=5)

    def start(self, body, int_default=True):
        # A background launcher can inherit ignored SIGINT. Establish it explicitly
        # in the child before exec; trap -p alone would not establish disposition.
        def disposition():
            signal.signal(signal.SIGINT, signal.SIG_DFL if int_default else signal.SIG_IGN)
        script = '''set -euo pipefail
source "$1"
eval "$(declare -f lock_acquire | sed '1s/lock_acquire/_probe_lock_acquire/')"
lock_acquire() { _probe_lock_acquire "$1" || return 1; printf '%s' "$BASHPID" > "$SB/holder"; }
''' + body
        proc = subprocess.Popen([str(self.bin / "bash"), "--noprofile", "--norc", "-c",
                                 script, "lock-probe", str(ROOT / "etc/pkgs-support.sh")],
                                env=self.env, start_new_session=True, preexec_fn=disposition,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(proc)
        return proc

    def ready(self, name):
        path = self.root / name
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and path.read_text():
                return path.read_text()
            time.sleep(.01)
        self.fail("timed out waiting for " + name)

    def test_holder_term_hup_wait_for_protected_foreground_child(self):
        for sig, expected in ((signal.SIGTERM, 143), (signal.SIGHUP, 129)):
            with self.subTest(signal=sig):
                for name in ("holder", "ready", "done"):
                    (self.root / name).unlink(missing_ok=True)
                proc = self.start('''f() { sh -c 'echo ready > "$SB/ready"; sleep 1; echo done > "$SB/done"'; }
lock_run "$SB/own" f
''')
                self.ready("ready")
                os.kill(int(self.ready("holder")), sig)
                time.sleep(.15)
                self.assertTrue((self.root / "own").is_dir(), "released while foreground child still running")
                self.assertFalse((self.root / "done").exists())
                out, err = proc.communicate(timeout=6)
                self.assertEqual(proc.returncode, expected, out + err)
                self.assertTrue((self.root / "done").exists())
                self.assertFalse((self.root / "own").exists())

    def test_foreground_group_int_with_default_disposition(self):
        proc = self.start('''f() { echo ready > "$SB/ready"; sleep 20; }
lock_run "$SB/own" f
''')
        self.ready("ready")
        os.killpg(proc.pid, signal.SIGINT)
        out, err = proc.communicate(timeout=6)
        self.assertEqual(proc.returncode, 130, out + err)
        self.assertFalse((self.root / "own").exists())

    def test_async_worker_inherits_ignored_int(self):
        proc = self.start('''f() { echo ready > "$SB/ready"; sleep 1; echo done > "$SB/done"; }
( lock_run "$SB/own" f ) &
wait
''', int_default=False)
        self.ready("ready")
        os.killpg(proc.pid, signal.SIGINT)
        out, err = proc.communicate(timeout=6)
        # The async worker inherits startup-ignored INT; installing a trap cannot reset it.
        self.assertTrue((self.root / "done").exists(), out + err)
        self.assertFalse((self.root / "own").exists())

    def test_foreign_wait_and_shadowed_path_on_term(self):
        (self.root / "foreign").mkdir()
        proc = self.start('''f() {
  local LOCKDIR="$SB/foreign"
  echo ready > "$SB/ready"
  lock_acquire "$LOCKDIR"
}
lock_run "$SB/own" f
''')
        self.ready("ready")
        holder = int(self.ready("holder"))
        # Signal callback as well as holder so the foreign wait can end. Holder
        # must retain its lock until that child stops; no path can redirect EXIT.
        os.killpg(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=6)
        self.assertTrue((self.root / "foreign").is_dir())
        self.assertFalse((self.root / "own").exists())

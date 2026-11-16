"""Cancellation must unwind owned process groups without touching other sessions."""

import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CancellationTests(unittest.TestCase):
    def test_sigterm_unwinds_once_and_restores_handlers(self):
        lifecycle = load("process_lifecycle_test", "process_lifecycle.py")
        old_int, old_term = signal.getsignal(signal.SIGINT), signal.getsignal(signal.SIGTERM)
        with self.assertRaises(lifecycle.Cancelled) as caught:
            with lifecycle.cancellation_guard():
                os.kill(os.getpid(), signal.SIGTERM)
        self.assertEqual(caught.exception.signum, signal.SIGTERM)
        self.assertIs(signal.getsignal(signal.SIGINT), old_int)
        self.assertIs(signal.getsignal(signal.SIGTERM), old_term)

    def test_repeated_signal_is_deferred_through_cleanup(self):
        lifecycle = load("process_lifecycle_repeated", "process_lifecycle.py")
        with lifecycle.cancellation_guard():
            try:
                os.kill(os.getpid(), signal.SIGINT)
            except lifecycle.Cancelled:
                os.kill(os.getpid(), signal.SIGINT)
                os.kill(os.getpid(), signal.SIGTERM)

    def test_owned_runners_reap_after_interrupt_and_leave_unrelated_session_alive(self):
        for filename in ("verify-shared-state.py", "verify-connected-native.py"):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(filename=filename, signum=signum), tempfile.TemporaryDirectory() as directory:
                    self._assert_owned_runner_interrupt(filename, signum, Path(directory))

    def _assert_owned_runner_interrupt(self, filename, signum, directory):
        runner = load(filename.replace("-", "_"), filename)
        ready, beat, leader = (directory / name for name in ("ready", "beat", "leader"))
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                     start_new_session=True)
        child = ("import pathlib,signal,sys,time; "
                 "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                 "pathlib.Path(sys.argv[1]).write_text('ready'); "
                 "p=pathlib.Path(sys.argv[2]); "
                 "\nwhile True: p.write_text(str(time.monotonic())); time.sleep(.03)\n")
        parent = ("import os,pathlib,subprocess,sys,time; "
                  "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                  "subprocess.Popen([sys.executable,'-c',sys.argv[4],sys.argv[2],sys.argv[3]]); "
                  "\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.01)\n"
                  "time.sleep(30)")
        command = [sys.executable, "-c", parent, str(leader), str(ready), str(beat), child]
        timer = threading.Timer(.4, lambda: os.kill(os.getpid(), signum))
        try:
            timer.start()
            with runner.cancellation_guard():
                with self.assertRaises(runner.Cancelled) as caught:
                    if filename == "verify-shared-state.py":
                        runner.run_owned(command, timeout=10, phase="integration", grace=.2)
                    else:
                        runner.run_owned(command, timeout=10, failure="test", timed_out="test_timeout", grace=.2)
            self.assertEqual(caught.exception.signum, signum)
            self.assertTrue(ready.exists())
            before = beat.read_text()
            time.sleep(.15)
            self.assertEqual(beat.read_text(), before)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(leader.read_text()), 0)
            self.assertIsNone(unrelated.poll())
        finally:
            timer.cancel()
            timer.join()
            if leader.exists():
                try:
                    os.killpg(int(leader.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            unrelated.terminate()
            unrelated.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()

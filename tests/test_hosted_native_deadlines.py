"""Hosted native deadlines stop the runner's owned process group."""

import importlib.util
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-hosted-native.py"


def load_runner():
    spec = importlib.util.spec_from_file_location("hosted_native_deadlines", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HostedNativeDeadlineTests(unittest.TestCase):
    def test_descendant_ignoring_term_stops_after_leader_exits(self):
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            ready = directory / "child-ready"
            heartbeat = directory / "heartbeat"
            leader_pid = directory / "leader-pid"
            child_code = (
                "import pathlib,signal,time,sys; "
                "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "ready=pathlib.Path(sys.argv[1]); beat=pathlib.Path(sys.argv[2]); "
                "ready.write_text('ready'); "
                "\nwhile True: beat.write_text(str(time.monotonic())); time.sleep(0.03)\n"
            )
            leader_code = (
                "import pathlib,subprocess,sys,time,os; "
                "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                "subprocess.Popen([sys.executable,'-c',sys.argv[4],sys.argv[2],sys.argv[3]]); "
                "ready=pathlib.Path(sys.argv[2]); deadline=time.monotonic()+5; "
                "\nwhile not ready.exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
                "time.sleep(60)"
            )
            command = [sys.executable, "-c", leader_code, str(leader_pid),
                       str(ready), str(heartbeat), child_code]
            try:
                with (directory / "private.log").open("w") as output:
                    with self.assertRaises(runner.HostedFailure) as caught:
                        runner.run_owned(command, timeout=0.6, environment=runner.child_environment(),
                                         output=output, failure="test", timed_out="test_timeout")
                self.assertEqual(caught.exception.code, "test_timeout")
                self.assertTrue(ready.exists())
                before = heartbeat.read_text()
                time.sleep(0.18)
                self.assertEqual(heartbeat.read_text(), before)
            finally:
                if leader_pid.exists():
                    try:
                        os.killpg(int(leader_pid.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_unreaped_leader_reports_fixed_cleanup_failure(self):
        runner = load_runner()

        class UnreapedProcess:
            pid = 12345

            def communicate(self, timeout):
                raise runner.subprocess.TimeoutExpired("private-command", timeout)

            def wait(self, timeout):
                raise runner.subprocess.TimeoutExpired("private-command", timeout)

        with patch.object(runner.subprocess, "Popen", return_value=UnreapedProcess()), \
                patch.object(runner.os, "killpg"):
            with self.assertRaises(runner.HostedFailure) as caught:
                runner.run_owned(["private-command"], timeout=0.01, environment={},
                                 failure="test", timed_out="test_timeout")
        self.assertEqual(caught.exception.code, "cleanup")
        self.assertNotIn("private-command", str(caught.exception))


if __name__ == "__main__":
    unittest.main()

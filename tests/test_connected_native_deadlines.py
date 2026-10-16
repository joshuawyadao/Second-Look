"""Native wrapper deadlines stop only owned children and keep private diagnostics."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-connected-native.py"
CONFIG_NAME = "SecondLook_iphonesimulator28.0-arm64.xctestrun"
RUN_CONFIG = {"TestConfigurations": [{"TestTargets": [
    {"BlueprintName": "SecondLookUITests", "EnvironmentVariables": {}}
]}]}


def load_runner():
    spec = importlib.util.spec_from_file_location("connected_native_deadlines", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ConnectedNativeDeadlineTests(unittest.TestCase):
    def test_descendant_ignoring_term_stops_when_leader_exits_first(self):
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
                    with self.assertRaises(runner.NativeFailure) as caught:
                        runner.run_owned(command, timeout=0.6, output=output, failure="test",
                                         timed_out="test_timeout", grace=0.2)
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

    def test_owned_hanging_process_group_terminates_descendant_and_reaps_leader(self):
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            child_ready = directory / "child-ready"
            child_terminated = directory / "child-terminated"
            leader_pid = directory / "leader-pid"
            child_code = (
                "import pathlib,signal,time,sys; "
                "ready=pathlib.Path(sys.argv[1]); ended=pathlib.Path(sys.argv[2]); "
                "signal.signal(signal.SIGTERM,lambda *_: (ended.write_text('terminated'),sys.exit(0))); "
                "ready.write_text('ready'); "
                "time.sleep(60)"
            )
            leader_code = (
                "import pathlib,signal,subprocess,sys,time,os; "
                "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                "subprocess.Popen([sys.executable,'-c',sys.argv[4],sys.argv[2],sys.argv[3]]); "
                "ready=pathlib.Path(sys.argv[2]); "
                "deadline=time.monotonic()+5; "
                "\nwhile not ready.exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
                "time.sleep(60)"
            )
            command = [sys.executable, "-c", leader_code, str(leader_pid),
                       str(child_ready), str(child_terminated), child_code]
            start = time.monotonic()
            with self.assertRaises(runner.NativeFailure) as caught:
                runner.run_owned(command, timeout=0.6, failure="build", timed_out="build_timeout",
                                 grace=0.2)
            self.assertEqual(caught.exception.code, "build_timeout")
            self.assertLess(time.monotonic() - start, 3)
            self.assertTrue(child_ready.exists())
            self.assertEqual(child_terminated.read_text(), "terminated")
            with self.assertRaises(ProcessLookupError):
                os.kill(int(leader_pid.read_text()), 0)

    def test_build_and_test_deadlines_close_private_log_and_remove_only_temporary_runner(self):
        runner = load_runner()
        for phase in ("build", "test"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                directory = Path(directory)
                derived = directory / "derived"
                products = derived / "Build" / "Products"
                products.mkdir(parents=True)
                fixture = directory / "fixture.json"
                fixture.write_text(json.dumps({"authURL": "http://127.0.0.1:56321",
                                               "serverURL": "http://127.0.0.1:58080"}))
                outputs = []
                commands = []

                def fake_owned(command, timeout, **kwargs):
                    commands.append((command, timeout))
                    if command[0] == "xcrun":
                        return b'{"devices":{}}'
                    output = kwargs["output"]
                    outputs.append(output)
                    output.write("synthetic private build log\n")
                    if "build-for-testing" in command:
                        (products / CONFIG_NAME).write_bytes(plistlib.dumps(RUN_CONFIG))
                        if phase == "build":
                            raise runner.NativeFailure("build_timeout")
                    elif "test-without-building" in command:
                        temporary = Path(command[command.index("-xctestrun") + 1])
                        self.assertTrue(temporary.exists())
                        raise runner.NativeFailure("test_timeout")
                    return b""

                with patch.object(sys, "argv", ["verify-connected-native.py", "--fixture", str(fixture)]), \
                        patch.dict(os.environ, {"SECONDLOOK_SIMULATOR_ID": "SYNTHETIC-SIMULATOR",
                                                "SECONDLOOK_DERIVED_DATA": str(derived)}), \
                        patch.object(runner, "run_owned", side_effect=fake_owned):
                    with self.assertRaises(runner.NativeFailure) as caught:
                        runner.main()
                self.assertEqual(caught.exception.code, phase + "_timeout")
                self.assertEqual(len(outputs), 1 if phase == "build" else 2)
                self.assertTrue(all(output.closed for output in outputs))
                self.assertTrue((products / CONFIG_NAME).exists())
                self.assertFalse((products / "SecondLook.connected.private.xctestrun").exists())
                private_log = directory / "native-paired.private.log"
                self.assertIn("synthetic private build log", private_log.read_text())
                self.assertEqual(stat.S_IMODE(private_log.stat().st_mode), 0o600)
                self.assertEqual(commands[0][1], runner.INVENTORY_TIMEOUT_SECONDS)
                self.assertEqual(commands[1][1], runner.BUILD_TIMEOUT_SECONDS)
                if phase == "test":
                    self.assertEqual(commands[2][1], runner.TEST_TIMEOUT_SECONDS)

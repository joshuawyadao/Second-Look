"""Local shared-state verification bounds owned tools and always stops its server."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("verify_shared_state_deadlines",
                                              SCRIPTS / "verify-shared-state.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class SharedVerifierDeadlineTests(unittest.TestCase):
    def test_failure_messages_never_include_command_or_provider_details(self):
        self.assertEqual(verifier.safe_failure_message(verifier.VerifierFailure("schema_timeout")),
                         "local schema checks timed out; owned process group stopped; inspect private logs.")
        self.assertEqual(verifier.safe_failure_message(verifier.VerifierFailure("native_failed")),
                         "native acceptance wrapper failed; inspect private logs.")
        secret = "invented-private-command-argument"
        self.assertNotIn(secret, verifier.safe_failure_message(RuntimeError(secret)))
        self.assertNotIn(secret, verifier.safe_failure_message(
            subprocess.CalledProcessError(1, ["docker", "exec", secret])))

    def test_every_external_phase_has_a_finite_named_deadline(self):
        cases = [
            (["docker", "network", "inspect", verifier.NETWORK], "inventory"),
            (["docker", "network", "create", verifier.NETWORK], "docker"),
            (["docker", "inspect", "supabase_db_secondlook-m2-local"], "inventory"),
            (["python3", "scripts/local-docker-binding.py", *verifier.CLI, "start"], "stack_start"),
            ([*verifier.CLI, "status", "-o", "json"], "cli_status"),
            ([*verifier.CLI, "stop"], "stack_stop"),
            (["docker", "exec", "-i", "supabase_db_secondlook-m2-local", "psql"], "schema"),
            (["swift", "build", "--package-path", "Backend"], "build"),
            (["swift", "build", "--show-bin-path"], "bin_path"),
            (["swift", "test", "--filter", "LocalIntegrationTests"], "integration"),
            (["python3", "scripts/verify-connected-native.py", "--fixture", "synthetic.json"], "native"),
        ]
        for command, expected in cases:
            with self.subTest(phase=expected, command=command[0]):
                phase, seconds = verifier.deadline_for(command)
                self.assertEqual(phase, expected)
                self.assertGreater(seconds, 0)
                self.assertLessEqual(seconds, 900)
        with self.assertRaises(verifier.VerifierFailure):
            verifier.deadline_for(["python3", "unrelated-command.py"])

    def test_timeout_kills_owned_descendant_after_leader_exits_and_reaps_leader(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            ready = directory / "ready"
            beat = directory / "heartbeat"
            pid = directory / "leader-pid"
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
            command = [sys.executable, "-c", leader_code, str(pid), str(ready), str(beat), child_code]
            try:
                with (directory / "private.log").open("w") as log:
                    with self.assertRaises(verifier.VerifierFailure) as caught:
                        verifier.run_owned(command, timeout=0.6, phase="integration",
                                           stdout=log, stderr=subprocess.STDOUT, grace=0.2)
                self.assertEqual(caught.exception.code, "integration_timeout")
                self.assertTrue(ready.exists())
                before = beat.read_text()
                time.sleep(0.18)
                self.assertEqual(beat.read_text(), before)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid.read_text()), 0)
            finally:
                if pid.exists():
                    try:
                        os.killpg(int(pid.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_integration_timeout_reaches_server_finally(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            owned = root / "owned"
            owned.mkdir()
            fake_server = object()
            stopped = []

            def fake_run(command, **_kwargs):
                if command[:3] == ["docker", "network", "inspect"]:
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps([{"Options": {
                        "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"}}]).encode())
                if command[:2] == ["docker", "inspect"]:
                    if "supabase_auth_secondlook-m2-local" in command:
                        return subprocess.CompletedProcess(command, 0, stdout=json.dumps([{"Config": {
                            "Env": ["GOTRUE_JWT_SECRET=invented-local-secret"]}}]).encode())
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps([{"NetworkSettings": {
                        "Ports": {"5432/tcp": [{"HostIp": "127.0.0.1"}]}}}]).encode())
                if command[:len(verifier.CLI) + 1] == [*verifier.CLI, "status"]:
                    return subprocess.CompletedProcess(command, 0, stdout=json.dumps({
                        "API_URL": "http://127.0.0.1:56321", "ANON_KEY": "invented-anon",
                        "SERVICE_ROLE_KEY": "invented-service"}).encode())
                if command[:2] == ["swift", "build"] and "--show-bin-path" in command:
                    return subprocess.CompletedProcess(command, 0, stdout=str(root).encode())
                if command[:2] == ["swift", "test"]:
                    raise verifier.VerifierFailure("integration_timeout")
                return subprocess.CompletedProcess(command, 0, stdout=b"")

            def fake_request(_url, *_args):
                return {"id": str(uuid.uuid4())}

            with patch.object(sys, "argv", ["verify-shared-state.py"]), \
                    patch.object(verifier.tempfile, "mkdtemp", return_value=str(owned)), \
                    patch.object(verifier.tempfile, "gettempdir", return_value=str(root)), \
                    patch.object(verifier, "run", side_effect=fake_run), \
                    patch.object(verifier, "start_stack"), \
                    patch.object(verifier, "apply_pending_local_migrations"), \
                    patch.object(verifier, "request", side_effect=fake_request), \
                    patch.object(verifier, "wait_server"), \
                    patch.object(verifier.subprocess, "Popen", return_value=fake_server), \
                    patch.object(verifier, "stop_owned_server", side_effect=stopped.append), \
                    patch.object(verifier.os, "umask"):
                with self.assertRaises(verifier.VerifierFailure) as caught:
                    verifier.main()
            self.assertEqual(caught.exception.code, "integration_timeout")
            self.assertEqual(stopped, [fake_server])

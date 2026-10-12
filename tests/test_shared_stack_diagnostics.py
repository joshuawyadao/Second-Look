"""Startup failures reveal a fixed hint without publishing private stack output."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from shared_stack_diagnostics import (  # noqa: E402
    MAX_DIAGNOSTIC_BYTES, classify_startup_log, startup_failure_message,
)

spec = importlib.util.spec_from_file_location("verify_shared_state", SCRIPTS / "verify-shared-state.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class SharedStackDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / "stack.private.log"

    def classify(self, content: bytes) -> str:
        self.log.write_bytes(content)
        return classify_startup_log(self.log)

    def test_known_failure_families(self):
        cases = {
            "docker": b"Cannot connect to the Docker daemon at unix:///private/socket",
            "image": b"failed to resolve reference docker.io/library/postgres:15",
            "port": b"Ports are not available: bind 127.0.0.1:56321",
            "health": b"database is not healthy: supabase_db_secondlook-m2-local",
            "migration": b"Error applying migration 202610050001_private_space.sql",
        }
        for expected, content in cases.items():
            with self.subTest(expected=expected):
                self.assertEqual(self.classify(content), expected)
        self.assertEqual(self.classify(b"client version 1.24 is too old; minimum supported API version is 1.44"),
                         "docker")

    def test_unknown_and_ambiguous_logs_do_not_guess(self):
        self.assertEqual(self.classify(b"startup failed with secret sb_secret_NOT_FOR_OUTPUT"), "unknown")
        self.assertEqual(self.classify(b"port is already allocated\nfailed to pull image"), "unknown")
        self.log.unlink()
        self.assertEqual(classify_startup_log(self.log), "unknown")

    def test_only_bounded_tail_is_read(self):
        prefix = b"port is already allocated" + b"x" * MAX_DIAGNOSTIC_BYTES
        self.assertEqual(self.classify(prefix + b"database is not healthy"), "health")

    def test_messages_are_fixed_and_never_include_secret_or_log_path(self):
        secret = b"sb_secret_PRIVATE_TEST_ONLY"
        self.classify(b"failed to pull image " + secret)
        message = startup_failure_message(self.log)
        self.assertIn("image pull", message)
        self.assertNotIn(secret.decode(), message)
        self.assertNotIn(str(self.log), message)

    def test_verifier_reports_only_fixed_hint_after_startup_failure(self):
        secret = "sb_secret_PRIVATE_TEST_ONLY"

        def failed_start(command, **kwargs):
            kwargs["stdout"].write(f"Cannot connect to the Docker daemon {secret}\n")
            raise subprocess.CalledProcessError(1, command)

        with patch.object(verifier, "run", side_effect=failed_start):
            with self.assertRaisesRegex(RuntimeError, "Docker availability") as failure:
                verifier.start_stack(Path(self.directory.name), {})
        self.assertNotIn(secret, str(failure.exception))
        self.assertIn(secret, self.log.read_text())

    def test_successful_startup_keeps_existing_path(self):
        with patch.object(verifier, "run", return_value=None) as launch:
            verifier.start_stack(Path(self.directory.name), {})
        self.assertEqual(launch.call_count, 1)
        self.assertEqual(launch.call_args.args[0][-1], verifier.EXCLUDED)


if __name__ == "__main__":
    unittest.main()

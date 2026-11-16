"""Source matching and required-case proof for the bounded local native smoke."""
import importlib.util
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone, timedelta
import io
import json
from pathlib import Path
import subprocess
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/check-connected-native-evidence.py"
NATIVE_SCRIPT = ROOT / "scripts/verify-connected-native.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("connected_evidence", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_git(root, *args):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout.decode().strip()


class ConnectedEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.checker = load_checker()

    def receipt(self, fingerprint="a" * 64, **updates):
        value = {
            "schema": 1,
            "fingerprint": fingerprint,
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "toolchain": {"xcode": "Xcode 27.2", "swift": "Apple Swift version 6.2"},
            "cases": {scenario: {case: "passed" for case in cases}
                      for scenario, cases in self.checker.CASES.items()},
        }
        value.update(updates)
        return value

    def test_missing_stale_failed_skipped_and_tampered_receipts_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            with self.assertRaises(self.checker.EvidenceError):
                self.checker.validate_receipt(path, "a" * 64)
            variants = [
                self.receipt(fingerprint="b" * 64),
                self.receipt(cases={"paired": {"ignored": "passed"}}),
                self.receipt(cases={scenario: {case: "skipped" for case in cases}
                                    for scenario, cases in self.checker.CASES.items()}),
                self.receipt(generated_at=(datetime.now(timezone.utc) + timedelta(days=1)).isoformat()),
                self.receipt(extra="tampered"),
            ]
            for index, variant in enumerate(variants):
                with self.subTest(index=index):
                    path.write_text(json.dumps(variant))
                    with self.assertRaises(self.checker.EvidenceError):
                        self.checker.validate_receipt(path, "a" * 64)
            path.write_text(json.dumps(self.receipt()))
            self.checker.validate_receipt(path, "a" * 64)

    def test_multi_commit_runtime_change_remains_relevant_after_docs_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_git(root, "init", "-q", "-b", "main")
            source = root / "SecondLookCore" / "State.swift"
            source.parent.mkdir()
            source.write_text("initial")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
            base = run_git(root, "rev-parse", "HEAD")
            run_git(root, "update-ref", "refs/remotes/origin/main", base)
            run_git(root, "checkout", "-qb", "feature")
            (root / "docs").mkdir()
            (root / "docs" / "notes.md").write_text("docs only")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "docs")
            with patch.object(self.checker, "ROOT", root):
                self.assertFalse(self.checker.changed_inputs("pull_request", "main", None))
                initial = self.checker.source_fingerprint()
                generated = root / "build" / "generated.swift"
                generated.parent.mkdir()
                generated.write_text("generated")
                (root / "fixture.private.json").write_text('{"private":"synthetic"}')
                self.assertEqual(initial, self.checker.source_fingerprint())
            source.write_text("changed runtime")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "runtime")
            (root / "docs" / "notes.md").write_text("later docs")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "later docs")
            with patch.object(self.checker, "ROOT", root):
                self.assertTrue(self.checker.changed_inputs("pull_request", "main", None))
                self.assertTrue(self.checker.changed_inputs("push", None, base))
                self.assertTrue(self.checker.changed_inputs("workflow_dispatch", "main", None))
                before = self.checker.source_fingerprint()
                source.write_text("changed again")
                self.assertNotEqual(before, self.checker.source_fingerprint())
                with self.assertRaises(self.checker.EvidenceError):
                    self.checker.changed_inputs("push", None, "0" * 40)

    def test_generation_rejects_source_change_after_local_runner(self):
        with patch.object(self.checker, "source_fingerprint", side_effect=["a" * 64, "b" * 64]), \
                patch.object(self.checker, "tool_version", return_value="Test toolchain"), \
                patch.object(self.checker.subprocess, "run") as runner:
            runner.return_value.returncode = 0

            def produce_cases(_command, **kwargs):
                directory = Path(kwargs["env"]["SECONDLOOK_NATIVE_EVIDENCE_DIR"])
                for scenario, cases in self.checker.CASES.items():
                    (directory / f"{scenario}.json").write_text(json.dumps({
                        "scenario": scenario, "cases": {case: "passed" for case in cases}}))
                return runner.return_value

            runner.side_effect = produce_cases
            with self.assertRaisesRegex(self.checker.EvidenceError, "Source changed") as caught:
                self.checker.generate()
            Path(str(caught.exception).split("private verifier log: ", 1)[1]).unlink()

    def test_failed_generator_retains_private_outer_log_without_receipt_or_console_output(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "docs" / "connected-native-evidence.json"
            receipt.parent.mkdir()
            output = io.StringIO()

            def fail_runner(_command, **kwargs):
                kwargs["stdout"].write("Synthetic verifier phase: Docker inventory unavailable; secret sentinel\n")
                return subprocess.CompletedProcess(_command, 1)

            with patch.object(self.checker, "RECEIPT", receipt), \
                    patch.object(self.checker, "source_fingerprint", return_value="a" * 64), \
                    patch.object(self.checker.subprocess, "run", side_effect=fail_runner), \
                    redirect_stdout(output), redirect_stderr(output):
                with self.assertRaisesRegex(self.checker.EvidenceError, "Local connected native smoke failed") as caught:
                    self.checker.generate()

            self.assertFalse(receipt.exists())
            self.assertNotIn("secret sentinel", str(caught.exception) + output.getvalue())
            private_log = Path(str(caught.exception).split("private verifier log: ", 1)[1])
            try:
                self.assertTrue(private_log.is_file())
                self.assertNotIn(self.checker.ROOT, private_log.parents)
                self.assertEqual(stat.S_IMODE(private_log.stat().st_mode), 0o600)
                self.assertIn("Docker inventory unavailable; secret sentinel", private_log.read_text())
            finally:
                private_log.unlink(missing_ok=True)

    def test_pr_merge_tree_rejects_receipt_after_base_source_advances(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_git(root, "init", "-q", "-b", "main")
            core = root / "SecondLookCore"
            core.mkdir()
            (core / "A.swift").write_text("base A")
            (core / "B.swift").write_text("base B")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
            run_git(root, "checkout", "-qb", "feature")
            (core / "A.swift").write_text("feature A")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "feature")
            with patch.object(self.checker, "ROOT", root):
                head_fingerprint = self.checker.source_fingerprint()
            run_git(root, "checkout", "-q", "main")
            (core / "B.swift").write_text("new base B")
            run_git(root, "add", ".")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base advance")
            run_git(root, "update-ref", "refs/remotes/origin/main", run_git(root, "rev-parse", "HEAD"))
            run_git(root, "checkout", "-q", "feature")
            run_git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "merge", "-q", "--no-edit", "main")
            with patch.object(self.checker, "ROOT", root):
                self.assertTrue(self.checker.changed_inputs("pull_request", "main", None))
                merge_fingerprint = self.checker.source_fingerprint()
            self.assertNotEqual(head_fingerprint, merge_fingerprint)

    def test_required_named_xctest_passes_reject_all_skipped_and_allow_unrelated_skip(self):
        spec = importlib.util.spec_from_file_location("native_smoke_runner", NATIVE_SCRIPT)
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        with self.assertRaises(native.NativeFailure):
            native.required_smoke_passes("paired", "Test Case '-[SecondLookUITests.ConnectedSharedStateUITests testAuthenticatedOwnerPeerAndOutsiderIsolation]' skipped\n")
        passed = "\n".join(
            "Test Case '-[SecondLookUITests." + case.replace(".", " ") + "]' passed (4.2 seconds)"
            for case in native.SMOKE_CASES["paired"]
        )
        passed += "\nTest Case '-[SecondLookUITests.ConnectedSharedStateUITests testFreshOwnerInvitationPeerJoinAndOwnerReopen]' skipped"
        self.assertEqual(native.required_smoke_passes("paired", passed),
                         {case: "passed" for case in native.SMOKE_CASES["paired"]})
        with self.assertRaises(native.NativeFailure):
            native.required_smoke_passes("paired", passed + "\nTest Case '-[SecondLookUITests.ConnectedSharedStateUITests testAuthenticatedOwnerPeerAndOutsiderIsolation]' failed")

    def test_workflow_gates_source_evidence_and_fetches_comparison_history(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  connected_evidence:\n", 1)[1].split("\n  verify:\n", 1)[0]
        self.assertIn("fetch-depth: 0", job)
        self.assertNotIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", job)
        self.assertIn("github.event.before", job)
        self.assertIn("github.base_ref", job)
        self.assertIn("check-connected-native-evidence.py check", job)
        aggregate = workflow.split("\n  verify:\n", 1)[1]
        self.assertIn("needs: [repository, native, backend, connected_evidence]", aggregate)
        self.assertIn("needs.connected_evidence.result", aggregate)
        self.assertIn('test "$EVIDENCE_RESULT" = success', aggregate)


if __name__ == "__main__":
    unittest.main()

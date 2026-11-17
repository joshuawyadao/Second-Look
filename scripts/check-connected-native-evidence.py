#!/usr/bin/env python3
"""Bind a local connected simulator smoke to the exact reviewed repository inputs."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
from process_lifecycle import Cancelled, cancellation_guard


ROOT = Path(__file__).resolve().parents[1]
RECEIPT = ROOT / "docs/connected-native-evidence.json"
CASES = {
    "paired": (
        "ConnectedSharedStateUITests.testAuthenticatedOwnerPeerAndOutsiderIsolation",
        "SharedCommandAcceptanceUITests.testPairedOwnerSharedCommandAcceptance",
    ),
    "fresh": ("ConnectedSharedStateUITests.testFreshOwnerInvitationPeerJoinAndOwnerReopen",),
    "access-loss": ("SharedInvitationAccessLossUITests.testInvitationActionClearsProtectedStateAfterAccessLoss",),
}


class EvidenceError(Exception):
    pass


def stop_owned_verifier(process: subprocess.Popen) -> None:
    """Give nested native, server, and scoped Docker teardown time to unwind."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        pass
    # Descendants can remain after the wrapper exits; only this owned group is targeted.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            raise EvidenceError("Local connected native smoke cleanup did not complete") from None


def git(*args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True)
    if result.returncode:
        raise EvidenceError("Git source comparison unavailable")
    return result.stdout


def is_input(path: str) -> bool:
    parts = Path(path).parts
    if not parts or parts[0] in ("docs", ".git") or path.endswith(".md"):
        return False
    if any(part in ("node_modules", ".build", "build", "DerivedData", "dist", "__pycache__") for part in parts):
        return False
    if any(".private." in part or part.endswith((".log", ".sqlite", ".env")) for part in parts):
        return False
    return True


def source_fingerprint() -> str:
    paths = sorted(set(git("ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0")) - {""})
    digest = hashlib.sha256(b"secondlook-connected-native-v1\0")
    selected = [path for path in paths if is_input(path)]
    if not selected:
        raise EvidenceError("No source inputs discovered")
    for relative in selected:
        path = ROOT / relative
        if path.is_symlink() or not path.is_file():
            raise EvidenceError("Source input unavailable")
        digest.update(relative.encode() + b"\0")
        # Git's executable flag affects whether the smoke wrapper can run.
        digest.update(b"x\0" if path.stat().st_mode & 0o100 else b"-\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def changed_inputs(event: str, base_ref: str | None, before: str | None) -> bool:
    if event == "pull_request" or event == "workflow_dispatch":
        target = base_ref or "main"
        if not re.fullmatch(r"[A-Za-z0-9._/-]+", target) or ".." in target:
            raise EvidenceError("Invalid base branch")
        base = git("rev-parse", "--verify", f"refs/remotes/origin/{target}^{{commit}}").strip().decode()
        head = git("rev-parse", "HEAD").strip().decode()
        if event == "workflow_dispatch" and base == head:
            return True  # A manual main run explicitly verifies the current receipt.
        start = git("merge-base", base, head).strip().decode()
    elif event == "push":
        if not before or not re.fullmatch(r"[0-9a-f]{40}", before) or before == "0" * 40:
            raise EvidenceError("Push base unavailable")
        git("cat-file", "-e", f"{before}^{{commit}}")
        start = before
    else:
        raise EvidenceError("Unsupported workflow event")
    changed = git("diff", "--name-only", "-z", start, "HEAD").decode().split("\0")
    # CI is clean, but a local check must not silently ignore worktree edits.
    changed += git("diff", "--name-only", "-z", "HEAD").decode().split("\0")
    changed += git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")
    return any(is_input(path) for path in changed if path)


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("Duplicate receipt field")
        result[key] = value
    return result


def validate_receipt(path: Path, fingerprint: str, *, now: datetime | None = None) -> None:
    try:
        record = json.loads(path.read_text(), object_pairs_hook=no_duplicate_keys)
        if set(record) != {"schema", "fingerprint", "generated_at", "toolchain", "cases"}:
            raise EvidenceError("Receipt schema mismatch")
        if type(record["schema"]) is not int or record["schema"] != 1:
            raise EvidenceError("Receipt schema mismatch")
        if record["fingerprint"] != fingerprint:
            raise EvidenceError("Receipt source fingerprint is stale")
        stamp = datetime.fromisoformat(record["generated_at"].replace("Z", "+00:00"))
        current = now or datetime.now(timezone.utc)
        if stamp.tzinfo is None or stamp > current + timedelta(minutes=5):
            raise EvidenceError("Receipt time is invalid")
        toolchain = record["toolchain"]
        if set(toolchain) != {"xcode", "swift"} or any(
                not isinstance(value, str) or not re.fullmatch(r"[\w .,:()+-]{1,150}", value)
                for value in toolchain.values()):
            raise EvidenceError("Receipt toolchain is invalid")
        expected = {scenario: {case: "passed" for case in cases} for scenario, cases in CASES.items()}
        if record["cases"] != expected:
            raise EvidenceError("Required connected native cases did not all pass")
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        raise EvidenceError("Receipt missing or malformed") from error


def tool_version(command: list[str]) -> str:
    try:
        completed = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EvidenceError("Native toolchain unavailable") from error
    if completed.returncode:
        raise EvidenceError("Native toolchain unavailable")
    lines = completed.stdout.splitlines()
    if not lines:
        raise EvidenceError("Native toolchain version unavailable")
    version = lines[0].strip()
    if not re.fullmatch(r"[\w .,:()+-]{1,150}", version):
        raise EvidenceError("Native toolchain version unavailable")
    return version


def generate() -> None:
    before = source_fingerprint()
    temp_root = Path(tempfile.gettempdir()).resolve()
    if temp_root == ROOT or ROOT in temp_root.parents:
        raise EvidenceError("Task temporary directory must be outside the repository")
    log_fd, log_name = tempfile.mkstemp(prefix="secondlook-native-evidence-", suffix=".private.log",
                                        dir=temp_root)
    log_path = Path(log_name)
    os.fchmod(log_fd, 0o600)
    try:
        with os.fdopen(log_fd, "w") as outer_log, \
                tempfile.TemporaryDirectory(prefix="secondlook-native-evidence-", dir=temp_root) as directory:
            environment = dict(os.environ, SECONDLOOK_NATIVE_EVIDENCE_DIR=directory)
            try:
                process = subprocess.Popen([str(ROOT / "scripts/verify-shared-state.sh"), "--modern-keys", "--native-smoke", "--ephemeral"],
                                           cwd=ROOT, env=environment, stdout=outer_log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as error:
                raise EvidenceError("Local connected native smoke unavailable") from error
            try:
                process.communicate()
            except BaseException:
                stop_owned_verifier(process)
                raise
            if process.returncode:
                raise EvidenceError("Local connected native smoke failed")
            observed = {}
            for scenario, cases in CASES.items():
                try:
                    record = json.loads((Path(directory) / f"{scenario}.json").read_text(),
                                        object_pairs_hook=no_duplicate_keys)
                except (OSError, ValueError) as error:
                    raise EvidenceError("Required native scenario evidence missing") from error
                if record != {"scenario": scenario, "cases": {case: "passed" for case in cases}}:
                    raise EvidenceError("Required native scenario evidence invalid")
                observed[scenario] = record["cases"]
        versions = {"xcode": tool_version(["xcodebuild", "-version"]),
                    "swift": tool_version(["swift", "--version"])}
        after = source_fingerprint()
        if before != after:
            raise EvidenceError("Source changed during connected native smoke")
        receipt = {
            "schema": 1, "fingerprint": after,
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "toolchain": versions,
            "cases": observed,
        }
        temporary = RECEIPT.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        validate_receipt(temporary, after)
        temporary.replace(RECEIPT)
    except (EvidenceError, Cancelled, KeyboardInterrupt) as error:
        if isinstance(error, (Cancelled, KeyboardInterrupt)):
            error = EvidenceError("Local connected native smoke cancelled")
        raise EvidenceError(f"{error}; private verifier log: {log_path}") from None
    log_path.unlink()
    print("Connected native operator evidence generated for current source.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("generate", help="Run bounded localhost smoke and publish a source-matched receipt.")
    check = sub.add_parser("check", help="Require a current receipt when connected inputs changed.")
    check.add_argument("--event", required=True, choices=("pull_request", "push", "workflow_dispatch"))
    check.add_argument("--base-ref")
    check.add_argument("--before")
    args = parser.parse_args()
    if args.command == "generate":
        generate()
    elif changed_inputs(args.event, args.base_ref, args.before):
        validate_receipt(RECEIPT, source_fingerprint())
        print("Connected native evidence matches current source and required cases.")
    else:
        print("Connected native evidence not applicable: no connected source or test inputs changed.")


if __name__ == "__main__":
    try:
        with cancellation_guard():
            main()
    except Cancelled:
        print("Connected native evidence check cancelled; inspect private verifier log if created.", file=sys.stderr)
        raise SystemExit(1)
    except EvidenceError as error:
        print("Connected native evidence check failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)

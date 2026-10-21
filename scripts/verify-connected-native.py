#!/usr/bin/env python3
"""Run authenticated native acceptance using a private synthetic localhost fixture."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
INVENTORY_TIMEOUT_SECONDS = 20
BUILD_TIMEOUT_SECONDS = 300
TEST_TIMEOUT_SECONDS = 420
GENERATED_TEST_RUN = re.compile(
    r"SecondLook_iphonesimulator\d+(?:\.\d+)*-(?:arm64|x86_64)\.xctestrun"
)


class NativeFailure(Exception):
    def __init__(self, code: str):
        self.code = code


class QuietParser(argparse.ArgumentParser):
    def error(self, _message):
        raise NativeFailure("arguments")


def run_owned(command: list[str], timeout: float, *, output=None,
              failure: str, timed_out: str, grace: float = 5) -> bytes:
    """Bound a child and its process group; never include command details in errors."""
    try:
        process = subprocess.Popen(command, cwd=ROOT, start_new_session=True,
                                   stdout=subprocess.PIPE if output is None else output,
                                   stderr=subprocess.DEVNULL if output is None else subprocess.STDOUT)
    except OSError:
        raise NativeFailure(failure) from None
    try:
        result, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        # A child can outlive a leader that exits on TERM, especially with file output.
        # KILL the owned group even if communicate already reaped that leader.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=grace)
        except subprocess.TimeoutExpired:
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                raise NativeFailure("cleanup") from None
        raise NativeFailure(timed_out) from None
    if process.returncode != 0:
        raise NativeFailure(failure)
    return result or b""


def generated_test_runs(products: Path) -> list[Path]:
    """Select only Xcode's generated Second Look simulator configurations."""
    return sorted(path for path in products.glob("SecondLook_iphonesimulator*.xctestrun")
                  if GENERATED_TEST_RUN.fullmatch(path.name))


def clear_generated_test_runs(products: Path) -> None:
    """Prevent an earlier SDK build in this derived data from masking the new run."""
    for path in generated_test_runs(products):
        path.unlink()


def main():
    parser = QuietParser()
    parser.add_argument("--fixture", required=True)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--only-shared-commands", action="store_true",
                           help="Run command checks against an already-paired synthetic localhost fixture.")
    selection.add_argument("--only-invitation-access-loss", action="store_true",
                           help="Run invitation access-loss checks against a fresh synthetic localhost fixture.")
    selection.add_argument("--only-pairing-recovery", action="store_true",
                           help="Run one pairing recovery check against a dedicated synthetic localhost fixture.")
    parser.add_argument("--recovery-case", choices=("invitation", "join", "restore", "busy", "draft", "identity", "receipt", "create", "lifecycle", "alert", "revision-floor", "revision-consistency", "forbidden", "creation", "cleanup", "draft-lifecycle"),
                        help="Select one pairing recovery case; requires --only-pairing-recovery.")
    args = parser.parse_args()
    if args.only_pairing_recovery != (args.recovery_case is not None):
        parser.error("--only-pairing-recovery requires exactly one --recovery-case, and vice versa")
    fixture_path = Path(args.fixture).resolve()
    fixture = json.loads(fixture_path.read_text())
    if args.only_invitation_access_loss and fixture.get("invitationAccessLoss") is not True:
        raise NativeFailure("fixture")
    if args.only_pairing_recovery and (fixture.get("pairingRecovery") is not True or
                                      fixture.get("recoveryCase") != args.recovery_case):
        raise NativeFailure("fixture")
    for key in ("authURL", "serverURL"):
        url = urlsplit(fixture[key])
        if url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise NativeFailure("fixture")
    inventory = json.loads(run_owned(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                     INVENTORY_TIMEOUT_SECONDS, failure="simulator",
                                     timed_out="simulator_timeout"))
    selected = os.environ.get("SECONDLOOK_SIMULATOR_ID")
    if not selected:
        for runtime in sorted(inventory["devices"],
                              key=lambda value: tuple(map(int, re.findall(r"\d+", value))),
                              reverse=True):
            if ".iOS-" in runtime:
                selected = next((item["udid"] for item in inventory["devices"][runtime]
                                 if item.get("isAvailable") and item["name"].startswith("iPhone")), None)
                if selected:
                    break
    if not selected:
        raise NativeFailure("simulator")
    derived = Path(os.environ.get("SECONDLOOK_DERIVED_DATA", str(fixture_path.parent / "native-build"))).resolve()
    common = ["-destination", "platform=iOS Simulator,id=" + selected,
              "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
    mode = ("recovery-" + args.recovery_case if args.only_pairing_recovery else
            "access-loss" if args.only_invitation_access_loss else
            "fresh" if fixture.get("freshPairing") else "paired")
    log_path = fixture_path.parent / ("native-" + mode + ".private.log")
    products = derived / "Build" / "Products"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    with os.fdopen(os.open(log_path, flags, 0o600), "w") as log:
        os.fchmod(log.fileno(), 0o600)
        clear_generated_test_runs(products)
        run_owned(["xcodebuild", "-project", "SecondLook.xcodeproj", "-scheme", "SecondLook",
                   "-configuration", "Debug", *common, "build-for-testing"], BUILD_TIMEOUT_SECONDS,
                  output=log, failure="build", timed_out="build_timeout")
        runs = generated_test_runs(products)
        if len(runs) != 1:
            raise NativeFailure("test_configuration")
        run = plistlib.loads(runs[0].read_bytes())
        targets = [target for config in run.get("TestConfigurations", [])
                   for target in config.get("TestTargets", [])]
        if not targets:
            targets = [value for key, value in run.items() if isinstance(value, dict)
                       and key != "__xctestrun_metadata__"]
        matched = [target for target in targets if target.get("BlueprintName") == "SecondLookUITests"]
        if len(matched) != 1:
            raise NativeFailure("test_configuration")
        target = matched[0]
        target.setdefault("EnvironmentVariables", {})["SECONDLOOK_SHARED_UI_FIXTURE"] = str(fixture_path)
        # Only the path enters the runner config; credentials never enter app launch config.
        temporary = products / "SecondLook.connected.private.xctestrun"
        temporary.write_bytes(plistlib.dumps(run))
        try:
            if args.only_pairing_recovery:
                suite = ("ConnectedDraftLifecycleUITests" if args.recovery_case == "draft-lifecycle" else
                         "ConnectedCleanupStatusUITests" if args.recovery_case == "cleanup" else
                         "SharedCreationReceiptRecoveryUITests" if args.recovery_case == "creation" else
                         "SharedForbiddenRestoreUITests" if args.recovery_case == "forbidden" else
                         "SharedInvitationReceiptRecoveryUITests" if args.recovery_case in ("receipt", "lifecycle", "alert") else
                         "SharedMutationRecoveryUITests" if args.recovery_case in ("busy", "draft", "identity", "revision-floor", "revision-consistency")
                         else "SharedPairingRecoveryUITests")
                selected_tests = ["-only-testing:SecondLookUITests/" + suite + "/" + {
                    "invitation": "testRenewalReplyLossInvalidatesOldInvitation",
                    "join": "testJoinReplyLossKeepsPairingDisabledUntilMembershipCheck",
                    "restore": "testRacingRestoreAttemptsOneCandidate",
                    "busy": "testBusyRefreshDisablesMutationUntilRefreshCompletes",
                    "draft": "testRejectedOneOffPreservesEditorDraft",
                    "identity": "testRefreshAccountMismatchClearsProtectedState",
                    "revision-floor": "testInitialMembershipRevisionSurvivesLaggingExplicitFetch",
                    "revision-consistency": "testInitialMembershipRejectsEqualRevisionContentMismatch",
                    "receipt": "testRenewalPreservesOriginalCommandReceipt",
                    "create": "testInitialCreateReplyLossRequiresMembershipCheckBeforeRenewal",
                    "lifecycle": "testForegroundSuspensionRestoresOriginalReceiptAfterVerifiedMembership",
                    "alert": "testUnknownOutcomeAlertStaysPrivateUntilMembershipRevalidation",
                    "forbidden": "testForbiddenRestoreClearsSavedCredentialsBeforeRelaunch",
                    "draft-lifecycle": "testEditorDraftSurvivesVerifiedForegroundReturn",
                    "cleanup": "testConnectedArchivesShowDistinctSyntheticCleanupStates",
                    "creation": "testOneOffRetryOpensOriginalCreatedChecklist"
                }[args.recovery_case]]
                if args.recovery_case == "draft-lifecycle":
                    selected_tests = ["-only-testing:SecondLookUITests/ConnectedDraftLifecycleUITests"]
                if args.recovery_case == "creation":
                    selected_tests = ["-only-testing:SecondLookUITests/SharedCreationReceiptRecoveryUITests"]
            elif args.only_invitation_access_loss:
                selected_tests = ["-only-testing:SecondLookUITests/SharedInvitationAccessLossUITests"]
            else:
                selected_tests = ["-only-testing:SecondLookUITests/SharedCommandAcceptanceUITests"]
                if not args.only_shared_commands:
                    selected_tests.insert(0, "-only-testing:SecondLookUITests/ConnectedSharedStateUITests")
            run_owned(["xcodebuild", "-xctestrun", str(temporary), *common, *selected_tests,
                       "test-without-building"], TEST_TIMEOUT_SECONDS,
                      output=log, failure="test", timed_out="test_timeout")
        finally:
            temporary.unlink(missing_ok=True)
    scenario = ("pairing recovery " + args.recovery_case if args.only_pairing_recovery else
                "invitation access loss" if args.only_invitation_access_loss else
                "shared commands" if args.only_shared_commands else
                "fresh pairing" if fixture.get("freshPairing") else "owner write, peer convergence and outsider denial")
    print("Authenticated native " + scenario + " acceptance passed on " + selected + ".")
    print("Private simulator log retained outside Git; this is localhost evidence, not hosted/device acceptance.")


if __name__ == "__main__":
    os.umask(0o077)
    messages = {
        "arguments": "invalid arguments",
        "fixture": "invalid synthetic localhost fixture",
        "simulator": "no available iPhone simulator",
        "simulator_timeout": "simulator discovery timed out; owned process group stopped",
        "build": "build failed; inspect the private native log",
        "build_timeout": "build timed out; owned process group stopped; remote runner cleanup may be needed",
        "test_configuration": "native UI test configuration was unavailable",
        "test": "acceptance failed; inspect the private native log",
        "test_timeout": "test timed out; owned process group stopped; remote runner cleanup may be needed",
        "cleanup": "owned process cleanup did not complete",
    }
    try:
        main()
    except NativeFailure as error:
        print("Native connected acceptance failed: " + messages.get(error.code, "unavailable"))
        raise SystemExit(1)
    except Exception:
        print("Native connected acceptance failed: unavailable; inspect private native log if created")
        raise SystemExit(1)

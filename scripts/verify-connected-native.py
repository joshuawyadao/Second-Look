#!/usr/bin/env python3
"""Run authenticated native acceptance using a private synthetic localhost fixture."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
GENERATED_TEST_RUN = re.compile(
    r"SecondLook_iphonesimulator\d+(?:\.\d+)*-(?:arm64|x86_64)\.xctestrun"
)


def generated_test_runs(products: Path) -> list[Path]:
    """Select only Xcode's generated Second Look simulator configurations."""
    return sorted(path for path in products.glob("SecondLook_iphonesimulator*.xctestrun")
                  if GENERATED_TEST_RUN.fullmatch(path.name))


def clear_generated_test_runs(products: Path) -> None:
    """Prevent an earlier SDK build in this derived data from masking the new run."""
    for path in generated_test_runs(products):
        path.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--only-shared-commands", action="store_true",
                           help="Run command checks against an already-paired synthetic localhost fixture.")
    selection.add_argument("--only-invitation-access-loss", action="store_true",
                           help="Run invitation access-loss checks against a fresh synthetic localhost fixture.")
    selection.add_argument("--only-pairing-recovery", action="store_true",
                           help="Run one pairing recovery check against a dedicated synthetic localhost fixture.")
    parser.add_argument("--recovery-case", choices=("invitation", "join", "restore", "busy", "draft", "identity", "receipt", "create"),
                        help="Select one pairing recovery case; requires --only-pairing-recovery.")
    args = parser.parse_args()
    if args.only_pairing_recovery != (args.recovery_case is not None):
        parser.error("--only-pairing-recovery requires exactly one --recovery-case, and vice versa")
    fixture_path = Path(args.fixture).resolve()
    fixture = json.loads(fixture_path.read_text())
    if args.only_invitation_access_loss and fixture.get("invitationAccessLoss") is not True:
        raise RuntimeError("Invitation access-loss acceptance requires its dedicated synthetic fixture.")
    if args.only_pairing_recovery and (fixture.get("pairingRecovery") is not True or
                                      fixture.get("recoveryCase") != args.recovery_case):
        raise RuntimeError("Pairing recovery acceptance requires its matching dedicated synthetic fixture.")
    for key in ("authURL", "serverURL"):
        url = urlsplit(fixture[key])
        if url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise RuntimeError("Native acceptance requires a synthetic localhost fixture.")
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
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
        raise RuntimeError("No available iPhone simulator.")
    derived = Path(os.environ.get("SECONDLOOK_DERIVED_DATA", str(fixture_path.parent / "native-build"))).resolve()
    common = ["-destination", "platform=iOS Simulator,id=" + selected,
              "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
    mode = ("recovery-" + args.recovery_case if args.only_pairing_recovery else
            "access-loss" if args.only_invitation_access_loss else
            "fresh" if fixture.get("freshPairing") else "paired")
    log_path = fixture_path.parent / ("native-" + mode + ".private.log")
    products = derived / "Build" / "Products"
    with log_path.open("w") as log:
        clear_generated_test_runs(products)
        subprocess.run(["xcodebuild", "-project", "SecondLook.xcodeproj", "-scheme", "SecondLook",
                        "-configuration", "Debug", *common, "build-for-testing"], cwd=ROOT,
                       check=True, stdout=log, stderr=subprocess.STDOUT)
        runs = generated_test_runs(products)
        if len(runs) != 1:
            raise RuntimeError("Expected one native test-run configuration.")
        run = plistlib.loads(runs[0].read_bytes())
        targets = [target for config in run.get("TestConfigurations", [])
                   for target in config.get("TestTargets", [])]
        if not targets:
            targets = [value for key, value in run.items() if isinstance(value, dict)
                       and key != "__xctestrun_metadata__"]
        matched = [target for target in targets if target.get("BlueprintName") == "SecondLookUITests"]
        if len(matched) != 1:
            raise RuntimeError("Native UI test target was not found.")
        target = matched[0]
        target.setdefault("EnvironmentVariables", {})["SECONDLOOK_SHARED_UI_FIXTURE"] = str(fixture_path)
        # Only the path enters the runner config; credentials never enter app launch config.
        temporary = products / "SecondLook.connected.private.xctestrun"
        temporary.write_bytes(plistlib.dumps(run))
        try:
            if args.only_pairing_recovery:
                suite = ("SharedInvitationReceiptRecoveryUITests" if args.recovery_case == "receipt" else
                         "SharedMutationRecoveryUITests" if args.recovery_case in ("busy", "draft", "identity")
                         else "SharedPairingRecoveryUITests")
                selected_tests = ["-only-testing:SecondLookUITests/" + suite + "/" + {
                    "invitation": "testRenewalReplyLossInvalidatesOldInvitation",
                    "join": "testJoinReplyLossKeepsPairingDisabledUntilMembershipCheck",
                    "restore": "testRacingRestoreAttemptsOneCandidate",
                    "busy": "testBusyRefreshDisablesMutationUntilRefreshCompletes",
                    "draft": "testRejectedOneOffPreservesEditorDraft",
                    "identity": "testRefreshAccountMismatchClearsProtectedState",
                    "receipt": "testRenewalPreservesOriginalCommandReceipt",
                    "create": "testInitialCreateReplyLossRequiresMembershipCheckBeforeRenewal"
                }[args.recovery_case]]
            elif args.only_invitation_access_loss:
                selected_tests = ["-only-testing:SecondLookUITests/SharedInvitationAccessLossUITests"]
            else:
                selected_tests = ["-only-testing:SecondLookUITests/SharedCommandAcceptanceUITests"]
                if not args.only_shared_commands:
                    selected_tests.insert(0, "-only-testing:SecondLookUITests/ConnectedSharedStateUITests")
            subprocess.run(["xcodebuild", "-xctestrun", str(temporary), *common, *selected_tests,
                            "test-without-building"], cwd=ROOT, check=True,
                           stdout=log, stderr=subprocess.STDOUT)
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
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("Native connected acceptance failed: " + str(error))
        raise SystemExit(1)

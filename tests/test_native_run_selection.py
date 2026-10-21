"""Retained Xcode test-run files must not block a fresh native invocation."""

import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
SIMULATOR = "SYNTHETIC-SIMULATOR"
CURRENT_NAME = "SecondLook_iphonesimulator28.0-arm64.xctestrun"
OLD_NAME = "SecondLook_iphonesimulator27.0-arm64.xctestrun"
RUN_CONFIG = {"TestConfigurations": [{"TestTargets": [
    {"BlueprintName": "SecondLookUITests", "EnvironmentVariables": {}}
]}]}
STALE_CONFIG = {**RUN_CONFIG, "SelectionMarker": "stale"}
CURRENT_CONFIG = {**RUN_CONFIG, "SelectionMarker": "current"}


def load_runner(filename: str):
    spec = importlib.util.spec_from_file_location(filename.removesuffix(".py"), SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NativeRunSelectionTests(unittest.TestCase):
    def make_products(self, directory: str) -> tuple[Path, Path, list[Path]]:
        derived = Path(directory) / "derived"
        products = derived / "Build" / "Products"
        products.mkdir(parents=True)
        stale = products / OLD_NAME
        stale.write_bytes(plistlib.dumps(STALE_CONFIG))
        unrelated = [products / "SecondLook_private-review.xctestrun",
                     products / "OtherScheme_iphonesimulator27.0-arm64.xctestrun"]
        for path in unrelated:
            path.write_bytes(b"unrelated synthetic configuration")
        return derived, products, unrelated

    def assert_unrelated_preserved(self, unrelated: list[Path]) -> None:
        for path in unrelated:
            self.assertEqual(path.read_bytes(), b"unrelated synthetic configuration")

    def test_connected_main_uses_current_build_configuration(self):
        runner = load_runner("verify-connected-native.py")
        with tempfile.TemporaryDirectory() as directory:
            derived, products, unrelated = self.make_products(directory)
            fixture = Path(directory) / "fixture.json"
            fixture.write_text(json.dumps({"authURL": "http://127.0.0.1:56321",
                                           "serverURL": "http://127.0.0.1:58080"}))
            used_configuration = []

            def fake_xcodebuild(command, _timeout, **_kwargs):
                if command[0] == "xcrun":
                    return b'{"devices":{}}'
                if "build-for-testing" in command:
                    (products / CURRENT_NAME).write_bytes(plistlib.dumps(CURRENT_CONFIG))
                elif "test-without-building" in command:
                    config = Path(command[command.index("-xctestrun") + 1])
                    used_configuration.append(plistlib.loads(config.read_bytes()))
                else:
                    self.fail("Unexpected native command")
                return b""

            with patch.object(sys, "argv", ["verify-connected-native.py", "--fixture", str(fixture)]), \
                    patch.dict(os.environ, {"SECONDLOOK_SIMULATOR_ID": SIMULATOR,
                                            "SECONDLOOK_DERIVED_DATA": str(derived)}), \
                    patch.object(runner, "run_owned", side_effect=fake_xcodebuild):
                with redirect_stdout(io.StringIO()):
                    runner.main()

            self.assertEqual(len(used_configuration), 1)
            self.assertEqual(used_configuration[0]["SelectionMarker"], "current")
            target = used_configuration[0]["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["EnvironmentVariables"]["SECONDLOOK_SHARED_UI_FIXTURE"],
                             str(fixture.resolve()))
            self.assertFalse((products / OLD_NAME).exists())
            self.assert_unrelated_preserved(unrelated)

    def test_recovery_probes_select_their_own_method_and_fixture(self):
        runner = load_runner("verify-connected-native.py")
        methods = {
            "lifecycle": ("SharedInvitationReceiptRecoveryUITests",
                          "testForegroundSuspensionRestoresOriginalReceiptAfterVerifiedMembership"),
            "alert": ("SharedInvitationReceiptRecoveryUITests",
                      "testUnknownOutcomeAlertStaysPrivateUntilMembershipRevalidation"),
            "revision-consistency": ("SharedMutationRecoveryUITests",
                                     "testInitialMembershipRejectsEqualRevisionContentMismatch"),
            "revision-floor": ("SharedMutationRecoveryUITests",
                               "testInitialMembershipRevisionSurvivesLaggingExplicitFetch"),
        }
        for scenario, (suite, method) in methods.items():
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                derived, products, _ = self.make_products(directory)
                fixture = Path(directory) / "fixture.json"
                fixture.write_text(json.dumps({"authURL": "http://127.0.0.1:56321",
                    "serverURL": "http://127.0.0.1:58080", "pairingRecovery": True,
                    "recoveryCase": scenario}))
                selected = []

                def fake_native(command, _timeout, **_kwargs):
                    if command[0] == "xcrun":
                        return b'{"devices":{}}'
                    if "build-for-testing" in command:
                        (products / CURRENT_NAME).write_bytes(plistlib.dumps(CURRENT_CONFIG))
                    elif "test-without-building" in command:
                        selected.extend(value for value in command if value.startswith("-only-testing:"))
                    else:
                        self.fail("Unexpected native command")
                    return b""

                with patch.object(sys, "argv", ["verify-connected-native.py", "--fixture", str(fixture),
                        "--only-pairing-recovery", "--recovery-case", scenario]), \
                        patch.dict(os.environ, {"SECONDLOOK_SIMULATOR_ID": SIMULATOR,
                                                "SECONDLOOK_DERIVED_DATA": str(derived)}), \
                        patch.object(runner, "run_owned", side_effect=fake_native), redirect_stdout(io.StringIO()):
                    runner.main()
                prefix = "-only-testing:SecondLookUITests/" + suite + "/"
                self.assertEqual(selected, [prefix + method])

    def test_hosted_main_uses_current_build_configuration(self):
        runner = load_runner("verify-hosted-native.py")
        with tempfile.TemporaryDirectory() as directory:
            derived, products, unrelated = self.make_products(directory)
            used_configuration = []

            def fake_run_owned(command, _timeout, **_kwargs):
                if "build-for-testing" in command:
                    (products / CURRENT_NAME).write_bytes(plistlib.dumps(CURRENT_CONFIG))
                elif "test-without-building" in command:
                    config = Path(command[command.index("-xctestrun") + 1])
                    used_configuration.append(plistlib.loads(config.read_bytes()))
                else:
                    self.fail("Unexpected hosted command")
                return b""

            with patch.object(sys, "argv", ["verify-hosted-native.py", "--simulator", SIMULATOR,
                                            "--public-configuration", str(Path(directory) / "public.json"),
                                            "--derived-data", str(derived)]), \
                    patch.object(runner, "public_configuration", return_value={}), \
                    patch.object(runner, "preflight"), \
                    patch.object(runner, "private_derived_data", return_value=derived), \
                    patch.object(runner, "run_owned", side_effect=fake_run_owned):
                with redirect_stdout(io.StringIO()):
                    runner.main()

            self.assertEqual(len(used_configuration), 1)
            self.assertEqual(used_configuration[0]["SelectionMarker"], "current")
            target = used_configuration[0]["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(target["EnvironmentVariables"],
                             {"SECONDLOOK_RUN_HOSTED_ACCEPTANCE": "1"})
            self.assertFalse((products / OLD_NAME).exists())
            self.assert_unrelated_preserved(unrelated)

    def test_connected_main_selects_numeric_newest_runtime_and_respects_override(self):
        inventory = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-9": [
                {"isAvailable": True, "name": "iPhone synthetic", "udid": "OLDER"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-10": [
                {"isAvailable": True, "name": "iPhone synthetic", "udid": "NEWEST"}],
        }}
        for override, expected in ((None, "NEWEST"), (SIMULATOR, SIMULATOR)):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as directory:
                runner = load_runner("verify-connected-native.py")
                derived, products, _ = self.make_products(directory)
                fixture = Path(directory) / "fixture.json"
                fixture.write_text(json.dumps({"authURL": "http://127.0.0.1:56321",
                                               "serverURL": "http://127.0.0.1:58080"}))
                destinations = []

                def fake_xcodebuild(command, _timeout, **_kwargs):
                    if command[0] == "xcrun":
                        return json.dumps(inventory).encode()
                    destinations.append(command[command.index("-destination") + 1])
                    if "build-for-testing" in command:
                        (products / CURRENT_NAME).write_bytes(plistlib.dumps(CURRENT_CONFIG))
                    return b""

                environment = {"SECONDLOOK_DERIVED_DATA": str(derived)}
                if override:
                    environment["SECONDLOOK_SIMULATOR_ID"] = override
                with patch.object(sys, "argv", ["verify-connected-native.py", "--fixture", str(fixture)]), \
                        patch.dict(os.environ, environment, clear=True), \
                        patch.object(runner, "run_owned", side_effect=fake_xcodebuild), \
                        redirect_stdout(io.StringIO()):
                    runner.main()
                self.assertEqual(destinations, ["platform=iOS Simulator,id=" + expected] * 2)

    def test_each_runner_replaces_only_generated_second_look_simulator_configurations(self):
        for filename in ("verify-connected-native.py", "verify-hosted-native.py"):
            with self.subTest(runner=filename), tempfile.TemporaryDirectory() as directory:
                products = Path(directory) / "Build" / "Products"
                products.mkdir(parents=True)
                stale = [products / "SecondLook_iphonesimulator26.5-arm64.xctestrun",
                         products / "SecondLook_iphonesimulator27.0-x86_64.xctestrun"]
                unrelated = [products / "SecondLook_private-review.xctestrun",
                             products / "SecondLook.hosted.private.xctestrun",
                             products / "OtherScheme_iphonesimulator27.0-arm64.xctestrun",
                             products / "SecondLook_iphoneos27.0-arm64.xctestrun"]
                for path in stale + unrelated:
                    path.write_bytes(b"synthetic test-run contents")

                runner = load_runner(filename)
                runner.clear_generated_test_runs(products)

                self.assertTrue(all(not path.exists() for path in stale))
                self.assertTrue(all(path.read_bytes() == b"synthetic test-run contents"
                                    for path in unrelated))
                current = products / "SecondLook_iphonesimulator28.0-arm64.xctestrun"
                current.write_bytes(b"current synthetic test-run")
                self.assertEqual(runner.generated_test_runs(products), [current])

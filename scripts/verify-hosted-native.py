#!/usr/bin/env python3
"""Opt-in hosted UI acceptance on an already signed-in, booted iPhone simulator.

The public configuration file contains only authURL, publishableKey, and serverURL.
The wrapper checks public app preferences before building; it never reads Keychain,
private snapshots, or credentials, and it never resets the installed app session.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.joshuawyadao.SecondLook.demo"
SELECTED_KEY = "secondlook.connected.selected.v1.shared-ui-test"
CONFIG_KEY = "secondlook.connected.config.v1.shared-ui-test"
PUBLIC_FIELDS = frozenset(("authURL", "publishableKey", "serverURL"))
HOSTED_TEST = ("-only-testing:SecondLookUITests/SharedCommandAcceptanceUITests/"
               "testHostedExistingSessionSharedCommandsAndForeground")
MEMBERSHIP_TEST = ("-only-testing:SecondLookUITests/SharedCommandAcceptanceUITests/"
                   "testHostedMembershipFailureKeepsPairingDisabled")


class HostedFailure(Exception):
    def __init__(self, code: str):
        self.code = code


class QuietParser(argparse.ArgumentParser):
    def error(self, _message):
        raise HostedFailure("arguments")


def public_configuration(path: Path) -> dict[str, str]:
    try:
        if path.stat().st_size > 8192:
            raise HostedFailure("public_configuration")
        value = json.loads(path.read_bytes())
    except (OSError, ValueError, TypeError):
        raise HostedFailure("public_configuration") from None
    if not isinstance(value, dict) or value.keys() != PUBLIC_FIELDS or \
            not all(isinstance(item, str) for item in value.values()):
        raise HostedFailure("public_configuration")
    for key in ("authURL", "serverURL"):
        try:
            url = urlsplit(value[key])
            host = url.hostname
            port = url.port  # Reject malformed ports before opening an external endpoint.
        except ValueError:
            raise HostedFailure("public_configuration") from None
        if (url.scheme != "https" or not host or not host.strip(".") or
                host.lower().rstrip(".") == "localhost" or
                host.lower().endswith((".localhost", ".local")) or
                url.username is not None or url.password is not None or
                url.query or url.fragment or url.path not in ("", "/") or
                (port is not None and port <= 0)):
            raise HostedFailure("public_configuration")
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            if not address.is_global:
                raise HostedFailure("public_configuration")
    key = value["publishableKey"]
    if (not key.startswith("sb_publishable_") or len(key) <= len("sb_publishable_") or
            len(key) > 512 or any(character.isspace() or ord(character) < 32 for character in key)):
        raise HostedFailure("public_configuration")
    return value


def child_environment() -> dict[str, str]:
    # Neither a test fixture nor ambient backend credentials are passed to xcodebuild.
    allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM")
    return {key: os.environ[key] for key in allowed if key in os.environ}


def run_owned(command: list[str], timeout: int, *, environment: dict[str, str],
              output=None, failure: str, timed_out: str) -> bytes:
    process = subprocess.Popen(command, cwd=ROOT, env=environment, start_new_session=True,
                               stdout=subprocess.PIPE if output is None else output,
                               stderr=subprocess.DEVNULL if output is None else subprocess.STDOUT)
    try:
        result, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        raise HostedFailure(timed_out) from None
    if process.returncode != 0:
        raise HostedFailure(failure)
    return result or b""


def preflight(simulator: str, expected: dict[str, str], environment: dict[str, str]) -> None:
    try:
        inventory = json.loads(run_owned(
            ["xcrun", "simctl", "list", "devices", "available", "-j"], 20,
            environment=environment, failure="simulator", timed_out="simulator"))
        devices = [device for group in inventory["devices"].values() for device in group]
    except (ValueError, KeyError, TypeError):
        raise HostedFailure("simulator") from None
    if not any(device.get("udid") == simulator and device.get("state") == "Booted" and
               device.get("name", "").startswith("iPhone") and
               device.get("isAvailable", True) for device in devices):
        raise HostedFailure("simulator")

    container = run_owned(["xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data"], 20,
                          environment=environment, failure="installed_app", timed_out="installed_app")
    try:
        data_path = Path(os.fsdecode(container.strip()))
        if not data_path.is_absolute() or not data_path.is_dir():
            raise HostedFailure("installed_app")
        preferences = data_path / "Library" / "Preferences" / (BUNDLE + ".plist")
        if preferences.stat().st_size > 1024 * 1024:
            raise HostedFailure("saved_configuration")
        saved = plistlib.loads(preferences.read_bytes())
        if not isinstance(saved, dict) or saved.get(SELECTED_KEY) is not True:
            raise HostedFailure("saved_configuration")
        encoded = saved.get(CONFIG_KEY)
        if not isinstance(encoded, bytes) or len(encoded) > 8192:
            raise HostedFailure("saved_configuration")
        decoded = json.loads(encoded)
        if decoded != expected:
            raise HostedFailure("saved_configuration")
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        raise HostedFailure("saved_configuration") from None


def private_derived_data(requested: str | None) -> Path:
    if requested is None:
        return Path(tempfile.mkdtemp(prefix="secondlook-hosted-native-"))
    path = Path(requested).expanduser().resolve()
    if path == ROOT or ROOT in path.parents:
        raise HostedFailure("derived_data")
    try:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        if not path.is_dir() or stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise HostedFailure("derived_data")
    except OSError:
        raise HostedFailure("derived_data") from None
    return path


def test_target(run: dict) -> dict:
    targets = [target for config in run.get("TestConfigurations", [])
               for target in config.get("TestTargets", [])]
    if not targets:
        targets = [value for key, value in run.items() if isinstance(value, dict)
                   and key != "__xctestrun_metadata__"]
    matched = [target for target in targets if target.get("BlueprintName") == "SecondLookUITests"]
    if len(matched) != 1:
        raise HostedFailure("test_configuration")
    return matched[0]


def main() -> None:
    parser = QuietParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="UDID of an already booted iPhone simulator")
    parser.add_argument("--public-configuration", required=True,
                        help="JSON file with only authURL, publishableKey, and serverURL")
    parser.add_argument("--derived-data", help="existing or new private build directory outside the repository")
    parser.add_argument("--only-membership-recovery", action="store_true",
                        help="run only the Debug membership-failure and real-lookup recovery test")
    args = parser.parse_args()
    expected = public_configuration(Path(args.public_configuration))
    environment = child_environment()
    preflight(args.simulator, expected, environment)
    derived = private_derived_data(args.derived_data)
    products = derived / "Build" / "Products"
    common = ["-destination", "platform=iOS Simulator,id=" + args.simulator,
              "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO",
              "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"]
    log_path = derived / "hosted-native.private.log"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    with os.fdopen(os.open(log_path, flags, 0o600), "w") as log:
        os.fchmod(log.fileno(), 0o600)
        run_owned(["xcodebuild", "-project", "SecondLook.xcodeproj", "-scheme", "SecondLook",
                   "-configuration", "Debug", *common, "build-for-testing"], 180,
                  environment=environment, output=log, failure="build", timed_out="build_timeout")
        runs = list(products.glob("SecondLook_*.xctestrun"))
        if len(runs) != 1:
            raise HostedFailure("test_configuration")
        try:
            run = plistlib.loads(runs[0].read_bytes())
        except (OSError, ValueError, plistlib.InvalidFileException):
            raise HostedFailure("test_configuration") from None
        target = test_target(run)
        # The UI target receives only this opt-in flag, never a credential fixture.
        target["EnvironmentVariables"] = {"SECONDLOOK_RUN_HOSTED_ACCEPTANCE": "1"}
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(prefix="SecondLook.hosted.", suffix=".xctestrun",
                                             dir=products, delete=False) as file:
                temporary = Path(file.name)
                file.write(plistlib.dumps(run))
            selected_test = MEMBERSHIP_TEST if args.only_membership_recovery else HOSTED_TEST
            run_owned(["xcodebuild", "-xctestrun", str(temporary), *common, selected_test,
                       "test-without-building"], 420, environment=environment, output=log,
                      failure="test", timed_out="test_timeout")
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    if args.only_membership_recovery:
        print("Hosted native membership-recovery acceptance passed. Private log remains in derived data.")
    else:
        print("Hosted native existing-session acceptance passed. Private log remains in derived data.")


if __name__ == "__main__":
    os.umask(0o077)
    fixed = {
        "arguments": "invalid arguments",
        "public_configuration": "invalid public configuration",
        "simulator": "selected simulator is not booted and available",
        "installed_app": "Second Look Demo is not installed on the selected simulator",
        "saved_configuration": "saved public configuration is absent or does not match",
        "derived_data": "derived data directory is not private and outside the repository",
        "build": "build failed; inspect the private derived-data log",
        "test_configuration": "native UI test configuration was unavailable",
        "test": "acceptance failed; inspect the private derived-data log",
        "build_timeout": "build timed out; owned process group stopped; remote runner cleanup may be needed",
        "test_timeout": "test timed out; owned process group stopped; remote runner cleanup may be needed",
    }
    try:
        main()
    except HostedFailure as error:
        print("Hosted native acceptance failed: " + fixed.get(error.code, "unavailable"))
        raise SystemExit(1)
    except Exception:
        print("Hosted native acceptance failed: unavailable; inspect private derived data if created")
        raise SystemExit(1)

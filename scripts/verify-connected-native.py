#!/usr/bin/env python3
"""Run authenticated native acceptance using a private synthetic localhost fixture."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    args = parser.parse_args()
    fixture_path = Path(args.fixture).resolve()
    fixture = json.loads(fixture_path.read_text())
    for key in ("authURL", "serverURL"):
        url = urlsplit(fixture[key])
        if url.scheme != "http" or url.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise RuntimeError("Native acceptance requires a synthetic localhost fixture.")
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    selected = os.environ.get("SECONDLOOK_SIMULATOR_ID")
    if not selected:
        for runtime in sorted(inventory["devices"], reverse=True):
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
    mode = "fresh" if fixture.get("freshPairing") else "paired"
    log_path = fixture_path.parent / ("native-" + mode + ".private.log")
    with log_path.open("w") as log:
        subprocess.run(["xcodebuild", "-project", "SecondLook.xcodeproj", "-scheme", "SecondLook",
                        "-configuration", "Debug", *common, "build-for-testing"], cwd=ROOT,
                       check=True, stdout=log, stderr=subprocess.STDOUT)
        runs = list((derived / "Build/Products").glob("SecondLook_*.xctestrun"))
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
        temporary = derived / "Build/Products/SecondLook.connected.private.xctestrun"
        temporary.write_bytes(plistlib.dumps(run))
        try:
            subprocess.run(["xcodebuild", "-xctestrun", str(temporary), *common,
                            "-only-testing:SecondLookUITests/ConnectedSharedStateUITests",
                            "test-without-building"], cwd=ROOT, check=True,
                           stdout=log, stderr=subprocess.STDOUT)
        finally:
            temporary.unlink(missing_ok=True)
    scenario = "fresh pairing" if fixture.get("freshPairing") else "owner write, peer convergence and outsider denial"
    print("Authenticated native " + scenario + " acceptance passed on " + selected + ".")
    print("Private simulator log retained outside Git; this is localhost evidence, not hosted/device acceptance.")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("Native connected acceptance failed: " + str(error))
        raise SystemExit(1)

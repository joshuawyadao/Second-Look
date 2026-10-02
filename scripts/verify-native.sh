#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

# Override when intentionally choosing another installed iPhone simulator.
SECONDLOOK_SIMULATOR_ID=${SECONDLOOK_SIMULATOR_ID:-$(python3 - <<'PY'
import json
import re
import subprocess

inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
runtimes = sorted(inventory['devices'], key=lambda value: tuple(map(int, re.findall(r'\d+', value))), reverse=True)
for runtime in runtimes:
    if '.iOS-' not in runtime:
        continue
    for device in inventory['devices'][runtime]:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components.')
PY
)}
SECONDLOOK_DERIVED_DATA=${SECONDLOOK_DERIVED_DATA:-"$REPO_ROOT/DerivedData"}

swift test
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Debug \
    -destination "platform=iOS Simulator,id=$SECONDLOOK_SIMULATOR_ID" \
    -derivedDataPath "$SECONDLOOK_DERIVED_DATA" -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO test
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$SECONDLOOK_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build

# Release must contain neither the Debug role picker nor the fixture adapter.
python3 scripts/verify-release-boundary.py "$SECONDLOOK_DERIVED_DATA/Build/Products/Release-iphonesimulator/SecondLook.app"

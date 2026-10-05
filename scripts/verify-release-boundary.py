#!/usr/bin/env python3
"""Check a built Release app's identity and absence of the development adapter."""
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
with (app / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.joshuawyadao.SecondLook.local', 'Unexpected Release identity'
strings = subprocess.check_output(['strings', str(app / info['CFBundleExecutable'])], text=True)
for forbidden in ('DemoFixtures', 'DemoRole', 'SampleReviewView', 'SamplePreviewView', 'SecondLookUITests', 'Preview role', 'Simulate delivery', 'testShowPrivacyShield', 'testRestoreApp', 'Show privacy shield', 'Restore app for test', '-privacy-testing', 'com.secondlook.ui-tests.privacy.show', 'com.secondlook.ui-tests.privacy.hide', '-shared-testing', 'SECONDLOOK_TEST_AUTH_URL', 'SECONDLOOK_TEST_PUBLISHABLE_KEY', 'SECONDLOOK_TEST_SERVER_URL', '.isolated-ui-tests', '.shared-ui-test', '.local-ui-test', 'Second Look local test Keychain status'):
    assert forbidden not in strings, f'Development feature in Release binary: {forbidden}'
print('Release boundary verified: separate identity, no development adapter, role picker, privacy or connection test controls.')

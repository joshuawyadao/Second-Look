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
for forbidden in ('-shared-test-delayed-refresh', '-shared-test-refresh-account-mismatch',
                  'testDelaySharedRefresh', 'testResumeSharedRefresh', 'testSharedRefreshMismatch',
                  'sharedSimulatedRefreshDelay', 'sharedSimulatedRefreshIdentityMismatch',
                  'testDelaySharedRefreshInEditor', 'testResumeSharedRefreshInEditor',
                  'sharedSimulatedRefreshDelayInEditor',
                  'testOverlapSharedRefresh', 'testOverlapSharedRefreshInEditor',
                  'sharedOverlapRefreshResult', 'sharedOverlapRefreshResultInEditor',
                  'Overlapping refresh admitted (simulated trigger)',
                  'Overlapping refresh rejected (simulated trigger)',
                  'Shared refresh delay (simulated for acceptance)',
                  'Refresh account mismatch (simulated for acceptance)'):
    assert forbidden not in strings, f'Development feature in Release binary: {forbidden}'
for forbidden in ('-shared-test-renewal-reply-loss', '-shared-test-join-reply-loss',
                  '-shared-test-restore-race', 'sharedSimulatedPairingReplyLoss',
                  'sharedRestoreCandidateCount', 'Pairing reply loss (simulated for acceptance)',
                  'Concurrent reconnect triggers (simulated for acceptance)'):
    assert forbidden not in strings, f'Development feature in Release binary: {forbidden}'
for forbidden in ('-shared-test-membership-failure', 'sharedSimulatedMembershipFailure',
                  'Membership lookup failure (simulated for acceptance)'):
    assert forbidden not in strings, f'Development feature in Release binary: {forbidden}'
for forbidden in ('-shared-test-access-loss', 'testSharedInvalidateAccess', 'M2-SYNTHETIC-INVALID-TOKEN', '-shared-no-periodic-poll', 'SharedCommandAcceptanceChecks', '-shared-command-checks', 'sharedCommandAcceptanceResult', 'verifyRefreshForAcceptance', 'storedCredentialsMatchForAcceptance', 'refreshedCredentialPersistence', 'DemoFixtures', 'DemoRole', 'SampleReviewView', 'SamplePreviewView', 'SecondLookUITests', 'Preview role', 'Simulate delivery', 'testShowPrivacyShield', 'testRestoreApp', 'Show privacy shield', 'Restore app for test', '-privacy-testing', 'com.secondlook.ui-tests.privacy.show', 'com.secondlook.ui-tests.privacy.hide', '-shared-testing', 'SECONDLOOK_TEST_AUTH_URL', 'SECONDLOOK_TEST_PUBLISHABLE_KEY', 'SECONDLOOK_TEST_SERVER_URL', '.isolated-ui-tests', '.shared-ui-test', '.local-ui-test', 'Second Look local test Keychain status'):
    assert forbidden not in strings, f'Development feature in Release binary: {forbidden}'
print('Release boundary verified: separate identity, no development adapter, role picker, privacy or connection test controls.')

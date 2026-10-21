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
for forbidden in ('-shared-test-initial-revision-floor', 'SharedLaggingInitialSnapshotClient',
                  'Simulated lagging explicit-space response: visible revision ',
                  '-shared-test-confirmed-consumption-suspend',
                  'sharedSimulatedConfirmedCreationPause',
                  'Confirmed creation consumption paused (simulated for acceptance)',
                  '-shared-test-scope-loss-purge', 'sharedSimulatedCommandScopeLoss',
                  'Command scope loss after commit (simulated for acceptance)',
                  '-shared-test-draft-lifecycle', '-shared-test-draft-access-loss',
                  'armSharedDraftRevalidation', 'resumeSharedDraftRevalidation',
                  'sharedSimulatedDraftRevalidationPause', 'sharedSimulatedDraftAccessLoss',
                  'sharedDraftPresentationGate', 'Protected presentation held for verification',
                  'prepareSharedReviewDraftProbe', 'sharedReviewDraftProbeStatus',
                  'Review draft checks ready', 'Review draft synthetic',
                  'Foreground draft revalidation paused (simulated for acceptance)',
                  '-shared-test-cleanup-status', 'runSharedCleanupProbe',
                  'sharedCleanupProbeStatus', 'Cleanup archive checks ready',
                  'SharedSyntheticEvidenceTestClient', '_testing/synthetic-evidence',
                  'M2-SYNTHETIC-NO-REAL-PHOTO',
                  '-shared-test-delayed-refresh', '-shared-test-refresh-account-mismatch',
                  'testDelaySharedRefresh', 'testResumeSharedRefresh', 'testSharedRefreshMismatch',
                  'sharedSimulatedRefreshDelay', 'sharedSimulatedRefreshIdentityMismatch',
                  'testDelaySharedRefreshInEditor', 'testResumeSharedRefreshInEditor',
                  'sharedSimulatedRefreshDelayInEditor',
                  'testOverlapSharedRefresh', 'testOverlapSharedRefreshInEditor',
                   '-shared-test-forbidden-restore', 'sharedSimulatedForbiddenRestore',
                  'sharedForbiddenRestoreCredentialStatus', 'Saved-session rejection (simulated for acceptance)',
                  '-shared-test-creation-receipt-one-off', '-shared-test-creation-receipt-save-as-routine',
                  '-shared-test-creation-editor-oneoff', '-shared-test-creation-editor-routine',
                  '-shared-test-creation-open-saveas', '-shared-test-creation-archive-repeat',
                  '-shared-test-creation-archive-saveas',
                  'sharedSimulatedCreationReplyLoss', 'sharedCreationReceiptResult',
                  'Creation reply loss (simulated for acceptance)', 'Creation receipt checks passed',
                  '-shared-test-invitation-receipts', '-shared-test-create-reply-loss',
                  '-shared-test-lifecycle-receipt', 'sharedSimulatedLifecycleRevalidationPause',
                  'resumeSharedLifecycleRevalidation', 'sharedSimulatedSecondLifecycleRevalidationPause',
                  'Foreground membership publication paused (simulated for acceptance)',
                  'Lifecycle receipt checks ready for background', 'Lifecycle receipt checks passed',
                  'SharedInvitationReceiptLossClient',
                  'sharedSimulatedCommandReplyLoss', 'sharedInvitationReceiptResult',
                  'Command reply loss (simulated for acceptance)',
                  'Invitation receipt checks ready for retry', 'Invitation receipt checks passed',
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

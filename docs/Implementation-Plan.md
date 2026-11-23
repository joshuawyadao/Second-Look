# Plan

Refresh Second Look’s Swiftly PR against the merged cache upgrade and verify the combined workflow before merging.

## Scope
- In: Sync PR #8 with the merged #9 cache change, preserve both workflow changes, refresh the connected-source receipt, and verify PR and post-merge CI.
- Out: Application or assertion changes, gate changes, deployments, real services, and physical devices.

## Action items
- [x] Confirm PR #9 merged at `68bf349` and its main push CI started.
- [x] Merge the new `main` into the existing Swiftly feature ref and preserve both upgrade records and exact pins.
- [x] Generate a receipt using the repository’s four-case smoke on an owned iOS simulator and an ephemeral localhost stack. Keep the existing assertions and checked fingerprint.
- [x] Run `./scripts/verify-repository.sh` and `check-connected-native-evidence.py check`. Use the existing workflow contract, signing-key, native and backend tests because executable changes are limited to the previously reviewed pins and signing bootstrap.
- [ ] Record actual combined-source evidence in `docs/Verification.md`, publish the branch and verify its fresh review and CI.
- [ ] Merge the verified Swiftly PR, verify the exact merge commit’s main push CI and confirm both merged feature refs are absent.

## Open questions
- None

# Plan

Unblock the standalone setup-swift v3 beta update by importing Swiftly's pinned signing identity before the installer runs.

## Scope
- In: Resolve the existing PR #3 missing-public-key error, keep Swift compiler 6.2.1 and signature checks, and regenerate a source-matched receipt.
- Out: Cache pin, app and server product behavior, production data, hosted deployment, and branch protection changes.

## Action items
- [x] Match the hosted GPG failure fingerprint to Swift.org's active signing key list.
- [ ] Add an installer key bootstrap that downloads the public key over HTTPS, compares the full primary fingerprint, and imports only the expected key into a runner-owned keyring.
- [ ] Pin the exact setup-swift beta from PR #3 and explicitly retain signature verification. Use narrow bootstrap tests to protect wrong-key and download failure boundaries.
- [ ] Run repository checks, generate fresh connected evidence on the isolated native smoke stack, and validate the required receipt.
- [ ] Document the trust boundary, validation results, and independent rollback path.
- [ ] Save, open a standalone PR, and complete hosted CI and review.

## Open questions
- None

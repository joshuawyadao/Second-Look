# Plan

Update the Swift server’s crypto dependency to 5.1.2 with the compatible Vapor and SwiftNIO Extras patches, then verify the combined source and prepare it for review.

## Scope

- In: The backend package manifest, lockfile, generated connected native receipt, and verification record.
- Out: Application and API behavior changes, provider or schema changes, toolchain upgrades, hosted deployment, and physical-device acceptance.

## Action items

- [ ] Confirm current main, official tag constraints, and the backend Debug/Release and integration checks in Backend Operations.
- [ ] Pin Vapor 4.122.3 and Swift Crypto 5.1.2, declare the server's existing direct Crypto dependency, and resolve SwiftNIO Extras 1.35.2 through the backend lockfile. Verify tag revisions, retained package pins, and reproducibility under Swift 6.2.1.
- [ ] Use existing server hashing, receipt, snapshot, and Auth/SQL/HTTP/restart tests for compatibility. Retain the existing test assertions and add cases only if an uncovered behavior change appears.
- [ ] Regenerate the receipt with all four connected cases on an owned iOS simulator and an ephemeral localhost stack. Verify both PR and push modes and record the evidence in Verification.
- [ ] Save the dependency update and source receipt together as the rollback boundary. Push the reviewed branch and open a PR.
- [ ] Complete exact-head Brooks and Codex review and required CI, preserving signature verification and the connected-source gate.

## Open questions

None.

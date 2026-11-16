# Plan

Close stale or missing connected-native evidence while preserving real local backend and native safety boundaries.

## Scope
- In: Scoped CI enforcement, automated validation, meaningful orchestration regressions, and canonical verification documentation for Second Look.
- Out: Product feature changes, deployment, paid services or account changes, personal data, physical-device operation, and release signing/publishing.

## Action items
- [ ] Read Backend-Operations and Verification docs, native fixture guards and shared-state wrappers.
- [ ] Confirm existing CI Verify enforcement and map supported hosted versus local native-stack execution.
- [ ] Add a bounded connected-native smoke/evidence gate using existing wrappers and synthetic services without relying on an unsupported hosted Docker/Xcode combination.
- [ ] Test that missing, stale, skipped, failed or wrong-source evidence cannot satisfy the affected-boundary gate.
- [ ] Validate repository, package and orchestration tests; run the connected smoke only in an isolated supported environment.
- [ ] Document any runner-provisioning limitation and manual acceptance, then save and push the scoped branch.

## Discovery notes
- Baseline: `03f8f7b5ab3ec469cdcc324e3603cd13a3f44fc7` (`origin/main`), isolated from the original checkout.
- Existing in-progress changes in original project folders remain untouched.
- Missing hosting/account capabilities are reported as concrete limitations; they are not permission to weaken required checks.

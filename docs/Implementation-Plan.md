# Plan

Revalidate the cache 6.1.0 update on current main with an independent branch and fresh connected native evidence.

## Scope
- In: Replace the backend CI cache pin from Dependabot PR #5 and regenerate the source-matched receipt through the existing isolated smoke runner.
- Out: Swift toolchain changes, cache scope/key changes, cloud or device operations, and branch protection changes.

## Action items
- [x] Confirm the cache update's required failure is the stale source fingerprint; its backend job passed.
- [ ] Apply only the reviewed cache action pin to current main.
- [ ] Keep cache paths and the lockfile-derived key unchanged. Use the existing cache-boundary test; it already asserts the intended behavior.
- [ ] Generate a receipt on an owned iPhone simulator against the disposable localhost stack, then validate it with the required CI checker.
- [ ] Run repository checks, record the evidence in Verification, and confirm the source remains stable.
- [ ] Save the scoped branch and run current-head GitHub CI and review on its PR.

## Open questions
- None

# Plan

Address actionable Codex comments and observed PR CI failures without widening Milestones 0–1. Preserve versioned local evidence and unsent work, validate restored review decisions, make snooze preferences usable, cover modal presentations when inactive, and prevent generated Xcode bundles from entering the public repository.

## Scope
- In: Exact-version withdrawal and retained replacement drafts; restored submission/decision consistency; future snooze picker initialization; a privacy shield above native sheets and portable UI-test taps for its separate windows; Xcode artifact verifier rules; focused regression tests, canonical documentation, item-specific commits/pushes/reactions, and final PR checks.
- Out: Backend/authentication, real photos/uploads/deletion, scheduling, paid services, distribution, changing protection/bypass rules, resolving review threads without authorization, and merging.

## Action items
[x] Read current PR threads, confirm the five P2 findings against core/UI/verifier code, and inspect Product-Spec, Architecture, Verification, tests, and the clean feature branch at `342764c`.
[x] Checkpoint this resolved plan before implementation (`7ef4426`); keep Git operations sequential and assign disjoint worker ownership.
[x] Require the observed submission version for withdrawal, preserve separate drafts, update the confirmation caller, and test stale/current/unauthorized/closed withdrawal plus retained draft persistence and resend. All 17 core tests pass.
[x] Initialize enabled snooze to an editable future picker value with clear sample language; constrain date choice and add a UI regression for saving/reopening a future deadline. The targeted simulator regression passes after correcting its tap to the trailing native switch and asserting it turns on. No scheduling or agreed cadence is introduced.
[x] Replace the root-only privacy overlay with a scene/window-level shield that covers sheets; all 3 new native privacy tests pass. Manual iOS 27 app-switcher inspection hides the editor and activation restores entered text; physical-device and software-keyboard limits are recorded.
[x] Reject tracked/force-added Xcode result/archive/dSYM bundles and generated build/cache directories in the verifier; add temporary-repository forced-add and safe-path regression cases. Repository verification and all 9 tooling tests pass.
[x] Update Product-Spec/Architecture and Verification with changed contracts, sample defaults, exact checks, and remaining device/service limits. Repository 9/core 17 tests pass; 7 UI tests passed in the combined run and the corrected snooze test passes on focused rerun. Debug tests, Release build, and expanded Release boundary check pass. Hosted CI must still validate the full final suite.
[x] Follow-up Codex comment `4174673339`: reject restored current evidence with an unauthorized/stale/missing decision or mismatched verdict/status, and preserve valid approved/requested/sending/failed/draft records. Two disk/repository regressions bring the core suite to 19 passing tests; malformed approvals cannot become editable state or complete a run. Architecture/Verification record the schema-v1 contract without a migration.
[ ] Hosted CI run `37150206853`: correct only the overlay test-control taps that Xcode 16.4 cannot scroll into view. Preserve every coverage assertion, validate the privacy tests locally, document the failure/correction, and wait for a new full hosted CI result.
[ ] Save each validated feedback cluster separately, push and react after each save, inspect fresh review/CI/mergeability, and finish with the PR unmerged. Any addressed but unresolved threads remain a final authorization step.

## Open questions
- None block these fixes. The snooze picker may start one hour ahead as a reversible editable UI seed, not an agreed reminder cadence; scheduling remains deferred. Review-thread resolution requires separate authorization only after fixes are concrete and verified.

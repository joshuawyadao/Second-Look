# Plan

Address the five actionable Codex comments on PR #1 without widening Milestones 0–1. Preserve versioned local evidence and unsent work, make snooze preferences usable, cover modal presentations when inactive, and prevent generated Xcode bundles from entering the public repository.

## Scope
- In: Exact-version withdrawal and retained replacement drafts; future snooze picker initialization; a privacy shield above native sheets; Xcode artifact verifier rules; focused regression tests, canonical documentation, item-specific commits/pushes/reactions, and final PR checks.
- Out: Backend/authentication, real photos/uploads/deletion, scheduling, paid services, distribution, changing protection/bypass rules, resolving review threads without authorization, and merging.

## Action items
[x] Read current PR threads, confirm the five P2 findings against core/UI/verifier code, and inspect Product-Spec, Architecture, Verification, tests, and the clean feature branch at `342764c`.
[ ] Checkpoint this resolved plan before implementation; keep Git operations sequential and assign disjoint worker ownership.
[ ] Require the observed submission version for withdrawal, preserve separate drafts, update the confirmation caller, and test stale/current/unauthorized/closed withdrawal plus retained draft persistence and resend.
[ ] Initialize enabled snooze to an editable future picker value with clear sample language; constrain date choice and add a UI regression for saving/reopening a future deadline. No scheduling or agreed cadence is introduced.
[ ] Replace the root-only privacy overlay with a scene/window-level shield that covers sheets; add focused native regression evidence for modal shielding and restored presentation after activation, with actual app-switcher timing limitations recorded.
[ ] Reject tracked/force-added Xcode result/archive/dSYM bundles and generated build/cache directories in the verifier; add temporary-repository forced-add and safe-path regression cases.
[ ] Update Product-Spec/Architecture and Verification with changed contracts, sample defaults, exact checks, and remaining device/service limits; run repository/core/native tests, Debug/Release builds, and the Release boundary check.
[ ] Save each validated feedback cluster separately, push and react after each save, inspect fresh review/CI/mergeability, and finish with the PR unmerged. Any addressed but unresolved threads remain a final authorization step.

## Open questions
- None block these fixes. The snooze picker may start one hour ahead as a reversible editable UI seed, not an agreed reminder cadence; scheduling remains deferred. Review-thread resolution requires separate authorization only after fixes are concrete and verified.

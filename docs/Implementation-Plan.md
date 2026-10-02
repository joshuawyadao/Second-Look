# Plan

Complete Milestones 0 and 1 from the October 2 Second Look handoff: preserve its product contracts in canonical documentation and build a runnable native iPhone local foundation. Use SwiftUI, a dependency-free Swift package for rules and persistence, a checked-in Xcode project, and clearly isolated Debug-only simulated services.

## Scope
- In: iOS 17+ local app, editable routines and one-offs, independent snapshot runs, standard progress, exact-version photo/review fixtures, replacement and closure rules, configurable settings models, text-only history, durable local storage, meaningful tests, simulator validation, and a pushed feature branch.
- Out: Real camera/library media, backend/auth/pairing, remote uploads, push or durable scheduled jobs, real media deletion guarantees, paid services, signing/distribution, Milestones 2–6, pull requests, and merges.

## Action items
[x] Read the complete handoff, applicable guidance, repository docs/tests, Git state, and installed tools; confirm a clean `main`, existing origin, Xcode 27/Swift 6.4, and available iOS 26.5/27 simulators.
[ ] Create `codex/second-look-foundation` from the current checkout and checkpoint this resolved plan; repository rules require feature branches, overriding the handoff's generic current-branch default.
[ ] Update README, contributor/agent/security guidance, Product-Brief, and canonical Product-Spec, Roadmap, Architecture, and native workflow decision docs; distinguish confirmed requirements, reversible assumptions, simulated behavior, and deferred work.
[ ] Implement a framework-independent value model and local state transitions with fixed run roles, immutable snapshots, exact submission versions, review notes, approval invalidation, terminal closure, text-only archives, and cleanup status separate from completion.
[ ] Add atomic versioned persistence with recoverable error reporting and tests for relaunch, failed saves, malformed data, run isolation, defaults, authorization checks, stale actions, and closure order using an injected clock.
[ ] Build native Routines, Review, History, editors, checklist, preview, and settings views; confine synthetic identities/evidence/retry/cleanup controls to Debug demo builds and persist local progress without production credentials.
[ ] Add a reproducible checked-in Xcode project/scheme, relevant CI checks, and scripts; checkpoint coherent core, app, and documentation slices locally after appropriate checks.
[ ] Run repository verification, focused and complete Swift tests, discovered-destination simulator build/run and UI smoke checks, plus a Release build to check demo exclusion. Record exact commands/results and genuine gaps in Verification.md.
[ ] Review important invariants and accessibility/recovery paths, update completed plan status, then use save-branch to commit and push only task-owned files to origin without opening a PR.

## Open questions
- None block Milestones 0–1. iOS 17 is a reversible development target pending the real devices; backend/vendor, notification cadence, optional timeout duration, signing, paid services, and distribution remain deferred.

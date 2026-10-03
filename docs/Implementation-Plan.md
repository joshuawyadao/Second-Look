# Plan

Complete Milestones 0 and 1 from the October 2 Second Look handoff: preserve its product contracts in canonical documentation and build a runnable native iPhone local foundation. Use SwiftUI, a dependency-free Swift package for rules and persistence, a checked-in Xcode project, and clearly isolated Debug-only simulated services.

## Scope
- In: iOS 17+ local app, editable routines and one-offs, independent snapshot runs, standard progress, exact-version photo/review fixtures, replacement and closure rules, configurable settings models, text-only history, durable local storage, meaningful tests, simulator validation, and a pushed feature branch.
- Out: Real camera/library media, backend/auth/pairing, remote uploads, push or durable scheduled jobs, real media deletion guarantees, paid services, signing/distribution, Milestones 2–6, pull requests, and merges.

## Action items
[x] Read the complete handoff, applicable guidance, repository docs/tests, Git state, and installed tools; confirm a clean `main`, existing origin, Xcode 27/Swift 6.4, and available iOS 26.5/27 simulators.
[x] Create `codex/second-look-foundation` from the current checkout and checkpoint this resolved plan (`703583b`); repository rules require feature branches, overriding the handoff's generic current-branch default.
[x] Update README, contributor/agent/security guidance, Product-Brief, and canonical Product-Spec, Roadmap, Architecture, and native workflow decision docs; distinguish confirmed requirements, reversible assumptions, simulated behavior, and deferred work.
[x] Implement a framework-independent value model and local state transitions with fixed run roles, immutable snapshots, exact submission versions, review notes, approval invalidation, terminal closure, text-only archives, and cleanup status separate from completion.
[x] Add atomic versioned persistence with recoverable error reporting and tests for relaunch, failed saves, malformed data, run isolation, defaults, authorization checks, stale actions, and closure order using an explicit command timestamps.
[x] Build native Routines, Review, History, editors, checklist, preview, and settings views; confine synthetic identities/evidence/retry/cleanup controls to Debug demo builds and persist local progress without production credentials.
[x] Add a reproducible checked-in Xcode project/scheme, relevant CI checks, and scripts; checkpoint coherent core, app, and documentation slices locally after appropriate checks.
[x] Run repository verification, focused and complete Swift tests, discovered-destination simulator build/run and UI smoke checks, plus a Release build to check demo exclusion. Record exact commands/results and genuine gaps in Verification.md.
[x] Review important invariants and accessibility/recovery paths, complete the verification record, and prepare the final save of task-owned files to the existing origin without opening a PR.
[x] Fix the UI harness setup isolation exposed by GitHub's Xcode 16.4, retain all assertions, and rerun the four local UI tests successfully. Publish the correction and report the final remote CI outcome with the handoff.

Local checkpoints: `703583b` (resolved plan), `2df83f1` (domain/storage and canonical docs), `f0ba968` (native app, tests, and CI), and `c5d50bb` (verification documentation). The UI harness compatibility correction completes the save workflow; remote CI status is reported after publication.

Validation: 15 Swift core tests, 4 native UI tests, and 7 repository-tooling tests pass. Debug simulator test/build, Release simulator build, and the Release demo-exclusion check passed on Xcode 27 / iOS 27. Code and documentation reviews informed fixes for settings validation, timestamp persistence, cleanup status, navigation overlap, and sheet error recovery. Real services/media and device distribution remain deferred.

## Open questions
- None block Milestones 0–1. iOS 17 is a reversible development target pending the real devices; backend/vendor, notification cadence, optional timeout duration, signing, paid services, and distribution remain deferred.

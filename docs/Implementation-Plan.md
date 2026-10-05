# Plan

Implement Milestone 2's authenticated private shared state on `codex/milestone-2-private-shared-state`. Use Supabase Auth/Postgres behind a Swift command server that reuses the existing core, and verify the real HTTP/auth/database path locally before any hosted provisioning. Keep local/demo functionality isolated and report local-stack evidence separately from hosted acceptance.

## Scope
- In: Official-source backend comparison and ADR; authenticated two-person pairing; server-derived actors/time, participant authorization and atomic versioned commands; shared native sign-in/pairing/refresh; account/session isolation; core, transport, database/auth integration and native tests; verification/docs; checkpoints and branch push.
- Out: Hosted provisioning or billing, public signup/multiple households, real photos/uploads/cleanup, push/scheduling, unpairing policy, distribution, opening a PR, and merging.

## Action items
[x] Inspect canonical product/architecture/roadmap, core transitions, native mutation sites, tests, Git state, available Docker and current official provider/framework docs. Preserve exact evidence versions, fixed roles, snapshots, terminal closure and local drafts.
[x] Checkpoint this resolved plan before implementation; give bounded workers disjoint core and native ownership and coordinate the shared interfaces before edits.
[x] Record the Supabase/Firebase/CloudKit comparison and reversible Auth/Postgres + Swift server decision in `docs/Backend-Comparison.md` and ADR 002, including privacy, transactions, durable jobs/APNs, cost/operations and deferred prerequisites.
[x] Add typed commands/snapshots and a session-scoped convergence coordinator in the dependency-free core. Exclude actor/time/full-state uploads and unsent previews; test authorization, stale versions, delayed snapshots/responses, account switches and rollback/closure.
[x] Add a pinned Swift/Vapor server and restricted Postgres persistence RPCs: one private space, two allowed authenticated accounts, targeted one-use expiring invitation, membership checks on reads/writes, compare-and-swap revisions and atomic command receipts. Verify credentials using the provider, never a decoded/unverified subject or role picker.
[x] Implement the native authenticated composition and account/pairing UI, secure session handling, typed asynchronous commands, foreground/manual refresh and immediate sign-out/isolation. Paired write/convergence/foreground and fresh-pairing acceptance pass against actual localhost services; real photo submission remains deferred and synthetic evidence is labeled.
[x] Add isolated localhost Supabase tooling and integration tests with generated synthetic users/credentials outside Git. Actual local Auth/Postgres/HTTP acceptance passes, including pre-join discovery, concurrent identical receipts and server restart; normal/Release composition rejects synthetic evidence routes.
[x] Run repository checks, `swift test`, backend Debug/Release boundaries, actual integration/restart, discovered-simulator `verify-native.sh`, Release exclusion and both native authenticated flows including saved-session relaunch. All local checks pass; evidence, repaired failures and limitations are in `docs/Verification.md`.
[x] Update README, AGENTS, Product-Brief/Spec, Architecture and Roadmap to distinguish implemented local-stack behavior from missing hosted/two-device acceptance. Keep full M2 exit criteria and prerequisites explicit.
[x] Review the integrated changes, checkpoint coherent slices and prepare only task-owned files for the final `save-branch` commit/push. Independent server/session review findings are repaired; the final Git/CI outcome is reported with the branch handoff.
[ ] Repair the remote Swift installer mismatch using an immutable action release and a supported Swift 6.2 toolchain, run repository checks, save the correction, and inspect the resulting CI run.
[ ] Complete the hosted acceptance gate after provider setup, operator access and secrets are resolved. Provisioning remains deferred; full M2 and the goal remain in progress. No PR or merge is authorized.

## Open questions
- None block the local implementation. Supabase Auth/Postgres and a Swift server are a reversible engineering choice; Docker is available. Hosted endpoint/region/operator access, actual participant accounts, secrets and authorization to provision remain deferred prerequisites for hosted acceptance. Unpairing's proposed cancel/revoke/history behavior requires a separate product decision in M4 and is not implemented here.

# Plan

Test Second Look's native private-space sign-in, pairing and shared writes against the existing Supabase/Render Free deployment on `codex/milestone-2-private-shared-state`. Use normally launched, ad hoc signed Debug simulator clients with the actual hosted Release server, private operator-entered credentials and invented standard checklist content. Record actual evidence separately from local fixtures and the remaining M2 exit checks.

## Scope
- In: Existing two-account hosted sign-in; two simulator clients; fresh pairing if the space is unjoined, otherwise discovery/reopen; accepted routine writes and peer convergence; foreground/relaunch and sign-out isolation; concrete fixes if testing exposes defects; canonical documentation, relevant validation, checkpoints and final branch push.
- Out: New/reset credentials, hosted resets or deletion, third-account provisioning, local integration scripts pointed at hosted services, synthetic evidence on the host, real photos, paid services, physical-device signing/distribution, PR creation or merge. This slice alone cannot close all M2 acceptance.

## Action items
[x] Inspect AGENTS, README, product contracts, operations/verification, connected UI/model and existing acceptance scripts. Delegate a bounded read-only acceptance/signing map. Available destinations include the booted iPhone 18 Pro/iOS 27 and iPhone 17 Pro/iOS 26.5; Device Hub provides native UI control. Local integration automation resets its disposable stack and rejects hosted fixtures, so it must not be reused against this project.
[ ] Checkpoint this resolved plan before changes, then build the current Debug client with existing simulator ad hoc signing and Keychain entitlements. Install only Second Look on the selected existing simulators; preserve unrelated apps and local data.
[ ] Prepare both clients' public Auth URL, publishable key and Render HTTPS URL through their native connection screens. Ask the operator to enter existing email/password credentials privately in the app; never collect passwords/tokens in chat, logs, test files or Git.
[ ] Verify account A sign-in and current membership discovery. Prepare a targeted invitation only if needed, keep it private, and obtain action-time confirmation before granting the other account new space access. Have the operator sign into account B privately and verify pairing/membership without a hosted reset.
[ ] Create and edit an invented all-standard routine, verify accepted server writes and convergence on the other client, then check foreground/relaunch revalidation and immediate sign-out clearing. Retain invented acceptance records; do not delete hosted data as cleanup without authorization.
[ ] Diagnose concrete failures before changes; add meaningful regression coverage and run repository/Core/native checks for app changes, plus local Auth/Postgres/HTTP integration when its boundary changes. If executable sources remain unchanged, add no implementation-mirroring tests: use actual hosted UI evidence, the signed build and repository checks instead.
[ ] Update Verification and relevant canonical setup/operations/status docs with executed checks, simulator/signing details and precise limits. Keep authenticated token-expiry refresh, outsider/concurrency/receipt/version/restart/cold-start and physical-device evidence unverified until actually exercised.
[ ] Review task-owned changes, validate documentation and save/push the existing feature branch with save-branch. Do not automatically redeploy a documentation-only push or open a PR.

## Open questions
- None block preparation. Existing account credential entry and later access-grant confirmation are external operator steps, not unresolved design choices. Use the first account the operator signs into as the space creator if no space exists. No paid upgrade or physical-device distribution is authorized.

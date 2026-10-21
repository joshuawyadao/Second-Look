# Plan

Finish PR #2 after review5593261083 on6b79926 adds two P2 findings (69total): reject unusable successful Auth credentials and retain text-only cleanup provenance for canceled undecided evidence. Preserve the installed schema, paired space, accounts, Free safeguards and all previous source-specific evidence. Leave the PR unmerged.

## Scope
- In: successful sign-in/refresh response validation; closure provenance, backward-compatible local/shared decoding and behavior regressions; canonical docs; required current-source local/native/hosted tests and final review/CI.
- Out: private-data reset/unpairing, credential changes, paid services, real media or cleanup jobs, push, distribution and merge.

## Action items
[x] Read both findings, map Auth transport and Core closure/persistence seams, preserve6b79926 hosted before/after-restart passes and checkpoint this resolved queue before new edits.
[x] Successful Auth token validation:16 meaningful HTTP200 red assertions,26 focused transport/session and130 full package green. Reject before returning sessions for vault installation/persistence; preserve valid bytes. Save/push and acknowledge item1.
[x] Resolve the smallest compatible text-only closure provenance design from the existing model/persistence contracts, document its legacy semantics before implementation, then add undecided-evidence mirrored-cleanup red coverage plus legitimate withdrawn/unsubmitted/acknowledged controls. Validate direct/JSON/shared-wire behavior and save/push/acknowledge item2.
[ ] Update canonical product/architecture/operation/verification docs and this plan with exact sources, tests and limitations. Previous69-minus2 repairs remain individually committed, tested and acknowledged; do not call unfinished global gates passed.
[ ] Complete current-source package/tooling/server Debug+Release, ordinary native Debug/Release/exclusion, both official local key modes and focused connected native cases. Private focused driver is prepared and elevated preflight passes; no focused cases have run. Use only task-owned B838 simulator/resettable localhost stack.
[ ] Upgrade the existing manual Render service to reviewed final server source if affected; run both preserved-session hosted wrappers before/after an actual service restart. No further SQL is assumed until design proves otherwise; inspect before any hosted mutation.
[ ] Complete scoped Brooks and fresh Codex review plus exact saved-head terminal CI, resolve only validated/pushed threads under existing authorization, and mark ready only when all gates pass. Never merge.

## Resolved closure interface
- Add ChecklistRun.hadEvidenceAtClosure: Bool?; nil while open, required Boolean when closed. Compute it before stripping submission/preview. false requiresnotNeeded; true requirespending or local simulatedConfirmed. Final current decision requires true; standard-only closure requiresfalse. Existing run/archive cleanup equality binds both.
- Encode SecondLookState.closureProvenanceVersion=1. Present1 enforces new markers; null/type-invalid/future versions reject. Absent version admits only legacy shapes with no marker keys, infers closed markers from matched original cleanup statuses, then applies normal validation. Load migrates in memory without writing files; next normal save/revisioned command encodes normalized fields.
- Keep outer local document version1, SharedSnapshot envelope1 and SQL RPC contracts unchanged. No image identifiers/bytes/URLs enter archives. Legacy lost evidence cannot be reconstructed, and unsigned wholesale downgrades cannot be authenticated; keep the server as sole connected-state writer and document that limit. No DDL/reset is needed for this additive opaque-JSON state shape.

## Open questions
- None for the user. Keep successful Auth credentials bounded/nonempty and reject whitespace/control characters rather than trimming opaque tokens. Choose a reversible, explicit compatibility path for text-only closure provenance; a legacy record cannot reconstruct already discarded evidence, so document that limit instead of fabricating proof. No private record may be erased to satisfy a validation test.

Closure implementation checkpoint: four meaningful undecided-cancellation red assertions; eight focused cases and138 full portable cases green. Text-only marker/version with strict new-shape validation and in-memory legacy inference; no SQL migration. Current-source local/native/hosted and external gates remain pending.

## Focused Brooks follow-up

P2 contract mismatch: successful Auth access tokens at exactly8192 UTF-8 bytes pass the phone but the command service rejects them. Align access-token acceptance with the existing exclusive8192 server limit; keep refresh-token bound independent. Add meaningful sign-in/refresh exact-boundary red assertions and valid8191-byte preservation, run focused/package tests and save the repair separately. No user decision is needed. Existing provenance/local/native checks retain their exact source.

Auth exact-limit repair: two meaningful red sign-in/refresh assertions; three focused cases and139 full package cases pass. Existing server contract preserved; no DDL or credential mutation. Save/push as a distinct Brooks repair; current source native/hosted acceptance remains pending.

## Further Codex follow-up

Review5593423259 onb03d94d adds2 P2 findings (71total): equal-revision different membership/explicit snapshots can publish before coordinator has its first snapshot, and malformed Auth expiry metadata can postpone refresh indefinitely. All six focused localhost cases now pass on235ed53/b03d94d; preserve that source-specific evidence.

- Reject an explicit refresh view at the same revision when it differs from the incoming membership view or the visible/held verified view. Keep the existing revision floor, exact scopes and immutable revisions; prove rejection, retained original view and later genuine recovery with behavior tests. Resolve implementation seam before editing.
- Require a positive bounded successful Auth expires_in and derive the persisted local deadline from response receipt time and that duration, without trusting absolute expires_at. Document a reversible one-day admission bound, retain hour-long current provider sessions, preserve valid token bytes, and add sign-in/refresh malformed-duration and far-future-absolute regressions before repair. No provider/session/reset change.
- Save/push/acknowledge each finding separately; run appropriate current-source package/native/hosted follow-up, fresh Brooks/Codex and final CI. Installed server235ed53 remains unchanged by phone-only repairs; no further SQL.

No open user question: these are bounded validation repairs under the existing task.

Auth expiry repair checkpoint:10 invalid-duration and6 far-future deadline red assertions;2focused+141package green. Both Auth paths normalize receipt-based expiry before vault installation, retain old credentials on failure and do not change provider configuration. Save/push/acknowledge4331720819 before the equal-revision implementation.

## Resolved consistency interface

Extend coordinator.refresh with default-empty validatingAgainst snapshots. Check each trusted reference's actor/exact space, fetched revision floor and equal-revision full equality BEFORE coordinator publication; rejection must leave coordinator snapshot, receipts and requests untouched. Model supplies authenticated membership plus visible/held verified view in production refresh/publication paths, and its visible view in first-command preflight. Keep existing command fetch/revision-floor semantics. A post-publication model-only check is insufficient because it poisons coordinator recovery and can leak through confirmed receipts.

Native test-first seam: dedicated revision-consistency localhost fixture/runner selection; genuine membership/fetch with a single clearly labeled simulated altered routine title at unchanged revision. First manual refresh must keep original content, reject altered content and show bounded error; later genuine refresh and one accepted write prove recovery. Portable coordinator tests cover both references, wrong scopes, stale floor, unchanged/equal/newer acceptance and rejection without retained-state mutation. No provider/server-route/SQL change.

Consistency repair checkpoint: genuine native altered-content red73.075s (failed Xcode group cleanup scoped after failure), nativegreen97.405s with recovery+write;5portable reference/receipt cases and146package green;53tooling green. Four production sites supply verified references before coordinator publication. Save/push/acknowledge4331720812, then current-source revision-floor/receipt/lifecycle follow-up, preserved hosted clients before/after actual restart and external review/CI.

Current affected native revision-floor rerun onf5f9d01 fails83.627s with actual visible revision-1 versus verified1. Prepublication stale rejection correctly leaves coordinator.snapshot nil, but execute catch overwrites the verified model snapshot with nil. Preserve the existing verified model view when no coordinator candidate was admitted; existing session/scope-loss handling still clears before this branch. Keep older/equal-conflict candidate rejection and all native assertions. Checkpoint this narrow follow-up, then rerun the original revision-floor and consistency cases plus receipt/lifecycle.

Verified-view retention follow-up: original nativefloorcase passes89.362s after83.627sregressionred, with unchangedassertions andlateronewrite. Smallcatchassignment retainsverifiedview onlywhen no coordinator candidatewasadmitted; knownaccess/scopeloss clearsfirst. Save/pushthischeckpoint whiletheother3affectedcasescontinue; no falseall-suitegreenclaim.

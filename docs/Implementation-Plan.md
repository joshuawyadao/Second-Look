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

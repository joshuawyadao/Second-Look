# Plan

Complete the requested automated checks after Docker becomes available, then record the actual results on the existing Milestone 2 feature branch. Keep earlier failures, skipped cases and remaining hosted acceptance gates explicit; this evidence update changes documentation only.

## Scope

- In: Repository, Core/transport, backend Debug/Release, native foundation and isolated localhost shared-state checks; October 8–9 evidence in `docs/Verification.md`; cleanup of task-owned test resources; local checkpoints and final branch push.
- Out: App/server behavior changes, hosted data or account changes, deployment, real media, paid services, distribution, PR or merge. Full M2 remains in progress.

## Action items

[x] Read applicable instructions, canonical product docs, `docs/Backend-Operations.md`, `docs/Verification.md` and the shared-state verification workflow. Confirm the existing branch and tested executable source commit `112de84`.
[ ] Checkpoint this resolved documentation plan before editing the verification record.
[ ] Finish the unmodified legacy and modern-key localhost workflows, including actual server restart and both gated native scenarios. Record failures and intentional companion-case skips separately from passing cases; preserve existing hosted simulator sessions.
[ ] Update `docs/Verification.md` with October 8 ordinary suite results and failed attempts, October 9 recovery results, the separate remote CI startup failure and remaining hosted gates. No test files need changes because executable behavior and assertions are unchanged.
[ ] Remove only the task-owned disposable simulator and stop only the named local Supabase stack while preserving its volumes. Keep private fixtures and logs outside Git.
[ ] Run `./scripts/verify-repository.sh` and `git diff --check`; check evidence claims and task-owned documentation for private data before saving.
[ ] Commit the completed plan and evidence, then push `codex/milestone-2-private-shared-state` to its existing origin. Do not open a PR, deploy or mark M2 complete.

## Open questions

- None. The requested checks use existing synthetic fixtures and isolated local services. Pending hosted lifecycle and other acceptance work remains recorded in the canonical verification and roadmap docs.

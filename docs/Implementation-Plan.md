# Plan

Complete the requested automated checks after Docker becomes available, then record the actual results on the existing Milestone 2 feature branch. Keep earlier failures, skipped cases and remaining hosted acceptance gates explicit; this evidence update changes documentation only.

## Scope

- In: Repository, Core/transport, backend Debug/Release, native foundation and isolated localhost shared-state checks; October 8–9 evidence in `docs/Verification.md`; cleanup of task-owned test resources; local checkpoints and final branch push.
- Out: App/server behavior changes, hosted data or account changes, deployment, real media, paid services, distribution, PR or merge. Full M2 remains in progress.

## Action items

[x] Read applicable instructions, canonical product docs, `docs/Backend-Operations.md`, `docs/Verification.md` and the shared-state verification workflow. Confirm the existing branch and tested executable source commit `112de84`.
[x] Checkpoint this resolved documentation plan before editing the verification record (`4d7c845`).
[x] Finish the unmodified legacy and modern-key localhost HTTP/restart workflows: both pass. The paired native scenario fails its foreground assertion; the separate unchanged fresh-pairing scenario passes. Record intentional companion skips separately and preserve existing hosted simulator sessions.
[x] Update `docs/Verification.md` with October 8 ordinary suite results and failed attempts, October 9 recovery results, the separate remote CI startup failure and remaining hosted gates. No test files need changes because executable behavior and assertions are unchanged. Native foreground failure and hosted acceptance remain open; this task records checks without claiming a repair.
[x] Remove only the task-owned disposable simulator and stop only the named local Supabase stack while preserving its volumes. Both cleanup operations succeed. Keep private fixtures and logs outside Git.
[x] Run `./scripts/verify-repository.sh` (12 tooling tests, local Markdown references and whitespace pass) and `git diff --check`; inspect evidence claims and task-owned documentation for private data before saving.
[x] Prepare the completed plan and evidence for the save-branch final docs-only commit/push to `codex/milestone-2-private-shared-state` on its existing origin. No unrelated files are changed or intentionally left unstaged. Do not open a PR, deploy or mark M2 complete.

## Open questions

- None. The requested checks use existing synthetic fixtures and isolated local services. Pending hosted lifecycle and other acceptance work remains recorded in the canonical verification and roadmap docs.

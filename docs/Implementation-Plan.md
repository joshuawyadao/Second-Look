# Plan

Resolve the remaining Milestone 2 native and CI failures, complete the available hosted acceptance checks, and prepare a reviewed pull request. Use narrow reproductions and meaningful regressions, preserve the existing private accounts and hosted records, and keep M2 incomplete until its required evidence is verified.

## Scope

- In: Existing feature branch; foreground/account isolation; safe Supabase startup diagnosis and CI repair; synthetic local tests; existing two hosted clients and invented checklist writes; canonical evidence/status docs; validation, checkpoints, branch push and PR review cycle.
- Out: New access recipients, credential resets, hosted data reset/deletion, paid services, real photos/uploads, push, unpairing, distribution or merge. Any necessary deployment must be concrete and reviewable before operator approval.

## Action items

[x] Read instructions and product, architecture, operations, roadmap, ADR and verification docs; map native and CI failure phases with bounded read-only agents. Existing branch is clean at `568e17d`; referenced GitHub helper skills are unavailable, so use connected GitHub tools/CLI for their equivalent steps.
[x] Checkpoint this resolved plan before changes (`178071a`). Maintain concise private review/fix notes and task-owned file boundaries.
[ ] Reproduce the native foreground failure with bounded safe state diagnostics, minimize its trigger, and fix the proven cause. Preserve account-epoch publication protection; add a regression at the actual lifecycle seam and retain the original connected assertion.
[ ] Expose only fixed startup-error categories from the private Supabase log with tooling tests; use the observed local/runner cause to make a narrow CI repair. `cf05521`/CI `38282060795` failed startup with unknown cause; `b554a67`/CI `38283588060` narrows this to Docker/API. The final refinement passes 21 tooling tests and separates fixed Docker subreasons; CI also reports the daemon's public API range. Private debug logs and stable compiler caches remain in place. This is diagnosis, not a functional repair. Preserve loopback binding and full Auth/SQL/HTTP/restart assertions.
[ ] Verify hosted relaunch, foreground, sign-out/account isolation and session refresh on existing clients; then exercise allowed standard commands, stale/repeated/concurrent writes, terminal state, server restart and Free cold-start behavior where access permits. Do not enable hosted synthetic media or create an outsider account without required authorization; record any concrete unavailable gate.
[ ] Run repository, root package, backend Debug/Release, native Debug/Release boundary and both local API-key integration/restart modes, including paired and fresh native cases. Discover destinations, isolate test resources, and preserve hosted app sessions.
[ ] Update `docs/Verification.md`, operations/architecture docs for actual changes, and canonical milestone status only when evidence warrants it. Clean up task-owned local resources, review private-data boundaries, save checkpoints and push the existing branch with `save-branch`.
[ ] Open/attach a draft M2 PR, request Codex review, run Brooks review, fix actionable feedback and CI, and verify mergeability. Report a merge-ready PR only when all required gates pass; otherwise identify exact blockers and leave it unmerged.

## Open questions

- None for local diagnosis and implementation. Existing accounts, services and pairing remain authorized. If a hosted check needs private sign-in or an explicit consequential action, request that specific operator step while continuing independent work.

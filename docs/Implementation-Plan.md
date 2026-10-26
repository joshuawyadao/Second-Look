# Plan

Implement the current-milestone efficiency recommendations on `codex/resource-efficiency` from main `416d70a` (PR #2 merged), preserving shared-state, privacy and retry guarantees, then prepare an unmerged PR through review and CI.

## Scope
- In: single-response snapshot admission; strong content-bound unchanged responses for active polls; tested adaptive polling; indexed history validation; one command-prepare RPC; bounded global request concurrency; content-free capacity observations; CI/build reuse; canonical docs and review evidence.
- Out: provider migration, paid resources/settings, hosted deployment/schema application, history or receipt expiry, real photos/uploads/deletion/schedulers, broad native-model rewrite, and merging any PR.

## Action items
- [x] Confirm PR #2 merged, fetch main416d70a and create codex/resource-efficiency; checkpoint this resolved plan before implementation.
- [x] Preserve current chronology/history/equal-revision/receipt guards while admitting a fetched membership snapshot directly; index run/archive correlation without changing public semantics.
- [x] Add opt-in HTTP200 unchanged replies bound to space, revision and a strong server content validator. Keep full stored-state validation and redirect denial; foreground/held-state restoration stays unconditional and legacy servers remain usable.
- [x] Add deterministic 5–30s active-idle polling and capped transient-error backoff in the portable core, with native lifecycle/session eligibility and explicit command retry unchanged.
- [x] Add service-only `sl_prepare` with one authorized consistent receipt-or-snapshot result, retaining locked commit/CAS and authoritative post-commit receipt checks. Generate an append-only migration using the pinned CLI; validate only against named local synthetic storage.
- [x] Add a bounded global in-flight gate with typed 429/Retry-After and fixed-label content-free counters; observe aggregate/receipt capacity without extra per-poll database queries or expiry. Preserve main’s existing Core/SQL capacity reservations and streamed bounded phone reception; those audit gaps were already repaired before this branch.
- [x] Deduplicate branch/PR CI work while preserving required CI Verify and pre-PR dispatch, cache pinned dependencies, and improve Docker dependency-cache locality without including private data or build secrets.
- [x] Add focused request-count, unchanged-content, corruption, scope/epoch/revision, replay/concurrency, admission and polling tests; run package Debug/Release, repository, native/Release, backend and both local key-mode checks relevant to changed paths.
- [x] Update Product-Spec, Architecture, ADR002, Backend-Operations, Verification and cost/capacity guidance with actual results and deployment prerequisites; retain future-media budgeting as later milestone work.
- [ ] Save/push coherent checkpoints, open a PR to main, attach it, request Codex review, run Brooks review, address actionable feedback and CI failures, and stop unmerged at merge-ready or a concrete blocker.

## Open questions

None. PR #2 is merged; the user authorized implementation on a new branch and a PR to main. Hosted rollout, paid resources and future-media implementation remain outside scope.

## Review and validation ledger

- Baseline main `416d70a`: 269 portable Debug cases (232 Core + 37 Transport) and 54 tooling cases pass. New main capacity/receipt/streaming limits are preserved.
- Checkpoints: `3ace567` resolved plan; `a89d33a` CI/cache reuse; `22c3bd5` shared refresh/index/polling and retry handling; `9dd1663` Backend/SQL; `758e51c` foreground-only periodic task.
- Local review fixed two concrete issues: periodic scheduling could cancel its own foreground refresh (lifecycle callbacks now own revalidation); a pre-Auth 429 on an exact retry could erase a previously committed unknown action (all 429s retain the original envelope for explicit same-ID retry).
- Current portable suites pass 287 Debug (241 Core + 46 Transport), 278 Release. Nine new transport and 14 focused retry/creation cases pass. Repository tooling: 58 pass. Ordinary native: 10 passes/35 expected skips (45 total), Release build and exclusion pass; the later 429-only Core change also has both portable configurations green.
- Backend: 70 Debug and 65 Release cases pass; optimized Release build and actual modern/legacy local Auth/Postgres/HTTP/SQL/restart workflows pass. Local Docker build and nonroot Release smoke pass. No hosted deployment is credited.
- Independent sampled Brooks reviews of Backend/SQL/DTO/transport and native/CI/docs find no additional actionable issue. Admission limits route processing, not slow-client transmission. Seven distinct current-source connected native cases pass. The combined draft group first times out at its existing 420s limit during repeated XCTest animation-notification waits; its last reviewer-note case then passes standalone in 126.281s after restarting only the task simulator, without source/assertion/deadline changes. The timed-out group is not credited as passing. Final PR review/CI gates remain pending and are tracked on the PR.

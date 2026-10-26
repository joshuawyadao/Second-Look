# Plan

Implement the current-milestone efficiency recommendations on codex/resource-efficiency from main416d70a (PR #2 merged), preserving shared-state, privacy and retry guarantees, then prepare an unmerged PR through review and CI.

## Scope
- In: single-response snapshot admission; strong content-bound unchanged responses for active polls; tested adaptive polling; indexed history validation; one command-prepare RPC; bounded global request concurrency; content-free capacity observations; CI/build reuse; canonical docs and review evidence.
- Out: provider migration, paid resources/settings, hosted deployment/schema application, history or receipt expiry, real photos/uploads/deletion/schedulers, broad native-model rewrite, and merging any PR.

## Action items
- [x] Confirm PR #2 merged, fetch main416d70a and create codex/resource-efficiency; checkpoint this resolved plan before implementation.
- [ ] Preserve current chronology/history/equal-revision/receipt guards while admitting a fetched membership snapshot directly; index run/archive correlation without changing public semantics.
- [ ] Add opt-in HTTP200 unchanged replies bound to space, revision and a strong server content validator. Keep full stored-state validation and redirect denial; foreground/held-state restoration stays unconditional and legacy servers remain usable.
- [ ] Add deterministic 5–30s active-idle polling and capped transient-error backoff in the portable core, with native lifecycle/session eligibility and explicit command retry unchanged.
- [ ] Add service-only sl_prepare with one authorized consistent receipt-or-snapshot result, retaining locked commit/CAS and authoritative post-commit receipt checks. Generate an append-only migration using the pinned CLI; validate only against named local synthetic storage.
- [ ] Add a bounded global in-flight gate with typed429/Retry-After and fixed-label content-free counters; measure aggregate/receipt capacity without extra per-poll database queries, automatic expiry or misleading post-buffer memory caps.
- [ ] Deduplicate branch/PR CI work while preserving required CI Verify and pre-PR dispatch, cache pinned dependencies, and improve Docker dependency-cache locality without including private data or build secrets.
- [ ] Add focused request-count, unchanged-content, corruption, scope/epoch/revision, replay/concurrency, admission and polling tests; run package Debug/Release, repository, native/Release, backend and both local key-mode checks relevant to changed paths.
- [ ] Update Product-Spec, Architecture, ADR002, Backend-Operations, Verification and cost/capacity guidance with actual results and deployment prerequisites; retain future-media budgeting as later milestone work.
- [ ] Save/push coherent checkpoints, open a PR to main, attach it, request Codex review, run Brooks review, address actionable feedback and CI failures, and stop unmerged at merge-ready or a concrete blocker.

## Open questions

None. PR #2 is merged; the user authorized implementation on a new branch and a PR to main. Hosted rollout, paid resources and future-media implementation remain outside scope.

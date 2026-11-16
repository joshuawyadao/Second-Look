# Plan

Require source-matched local connected-native smoke evidence from a fresh UUID-scoped synthetic stack, preserving the existing stack and safety boundaries. Keep combined Docker/Xcode runner provisioning as a follow-up.

## Scope
- In: Required CI evidence, bounded localhost orchestration, meaningful regressions, Debug acceptance diagnostics, and canonical verification documentation.
- Out: Unrelated product features, deployment, paid resources, personal data, physical devices, and release signing/publishing.

## Action items
- [x] Read Backend-Operations/Verification, existing CI, native fixture guards and wrapper tests.
- [x] Preserve existing CI Verify enforcement and all portable/native/backend checks; require the connected receipt for affected source.
- [x] Bind evidence to source contents and executable modes; require each exact native case to pass and reject absent/stale/wrong-source/skipped/failed/ambiguous evidence.
- [x] Isolate smoke in private copied config/migrations, four loopback ports, a UUID project/network, and per-run fixture pointer; preserve full legacy behavior and existing data.
- [x] Require exact scoped db/kong/auth/rest names, labels, network and approved mounts, with no published Auth/PostgREST ports; inspect ownership before SQL and before cleanup.
- [x] Test source-copy integrity, invalid scopes, foreign mounts/volumes, stopped/disconnected resources, cleanup failure and diagnostic redaction: 84 repository tests pass.
- [x] Add fixed Debug-only final-refresh refusal/error categories and preserve the command runner's first failed fixed step in its failure label. Keep refresh/network/admission behavior and all assertions unchanged.
- [x] Run the required four-case connected smoke and commit its source-matched receipt only after all cases and owned cleanup pass.
- [x] Revalidate the saved source in hosted CI, update canonical docs and save the branch.

## Discovery notes
- Base: `03f8f7b5ab3ec469cdcc324e3603cd13a3f44fc7` (`origin/main`), in an isolated clone. Original project folders remain unchanged.
- Initial legacy-stack attempts hit database backup startup/status failures; no existing volumes were deleted. Disposable scope now starts cleanly and cleans up only its new resources.
- Live evidence corrected the initial three-service assumption: Swift `Provider.swift` uses PostgREST RPC. The full original service set is restored; all four required services use strict ownership checks.
- At source `5361c66`, database expiry/rotation/privilege/receipt checks, Swift build, and real HTTP integration before/after restart pass. Native owner/peer/outsider isolation passes (142 seconds), but the command acceptance case fails at `postRunRefresh`; later required cases do not run and no receipt exists.
- `postRunRefresh` currently masks whether fixed command checks passed and whether refresh refused entry or threw a sanitized failure. Read-only code tracing has not established an app defect; add only fixed categories, then use the unchanged live assertion to diagnose. Do not loosen validation, add blind retries or skip a case.
- Hosted run `43940654068` at `4cf5e2c` passes repository, native foundation and backend jobs (both API key modes/restart). Evidence/aggregate correctly fail on the absent receipt. Later changes require current-source verification.
- Canonical docs: `docs/Backend-Operations.md`, `docs/Verification.md`. Synthetic credentials/logs stay private outside Git; the receipt contains no credentials, endpoints or personal data.

## Open questions
None.

- The Debug diagnostic slice compiles with `build-for-testing` (Xcode 27.2/iOS 26.5). It adds only fixed failure labels and retains existing guards, network calls, deadlines and native assertions; no new mirror tests were added. The existing live command assertion is the meaningful validation, and a complete fresh source-matched run follows.

- At `f210190`, all four required native cases pass: paired isolation (141.032s), paired commands (16.084s), fresh pairing/reopen (63.408s), invitation access loss (58.217s). Database checks, HTTP integration before/after restart, exact-case evidence parsing, stable source fingerprint and owned-resource cleanup all pass. Receipt generated 2026-11-16T22:31:38Z with Xcode 27.2 / Swift 6.4.2. An earlier post-run refresh failure remains an observed intermittent issue with unconfirmed cause; no network/admission behavior was changed to obtain this pass.

- Complete hosted CI passes at `ea09ce3`: repository checks, native foundation, Debug/Release backend boundaries, legacy/modern API key integration with restart, source evidence and CI Verify. Run: https://github.com/joshuawyadao/Second-Look/actions/runs/43971087775 . Later documentation-only completion records do not alter the receipt fingerprint. Disposable Docker resources and simulators are removed; Docker Desktop is restored to its initially stopped state.

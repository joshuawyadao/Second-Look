# Plan

Require local, source-matched connected-native smoke evidence from an opt-in fresh UUID-scoped synthetic stack, preserving the legacy named stack/volumes and native safety boundaries. Combined Docker/Xcode runner provisioning is a follow-up.

## Scope
- In: Scoped CI enforcement, automated validation, meaningful orchestration regressions, and canonical verification documentation for Second Look.
- Out: Product feature changes, deployment, paid services or account changes, personal data, physical-device operation, and release signing/publishing.

## Action items
- [x] Read Backend-Operations and Verification docs, native fixture guards and shared-state wrappers.
- [x] Confirm existing CI Verify enforcement and map supported hosted versus local native-stack execution.
- [x] Add a bounded connected-native smoke/evidence gate using existing wrappers and synthetic services without relying on an unsupported hosted Docker/Xcode combination.
- [x] Add a per-run private project/network/config/port scope to the bounded smoke only, with exact adapter allowlists and owned-resource cleanup.
- [x] Reject foreign mounts in create and inspect paths, prove stopped/disconnected resource ownership before volume cleanup, and keep the legacy fixture pointer intact.
- [x] Test that missing, stale, skipped, failed or wrong-source evidence cannot satisfy the affected-boundary gate.
- [x] Include Git's executable flag in the source fingerprint and test mode-only changes, so changing how a runner can execute invalidates old evidence.
- [x] Add an opt-in `--native-smoke --ephemeral` path with an internally generated UUID project/network, four loopback ports and a private temporary CLI workdir; keep the legacy full run unchanged.
- [x] Copy only reviewed local config/migrations, validate the exact derived fields and adapter ownership allowlists, and clean up only freshly owned resources on every exit path.
- [x] Test invalid scopes, unrelated resource refusal, source-copy integrity, cleanup failures and unchanged legacy behavior before attempting the isolated real smoke.
- [x] Validate repository and orchestration regressions: all 81 repository tests pass outside sandbox socket restrictions. Connected smoke remains blocked by local service startup; no passing receipt is claimed.
- [ ] Run the four-case connected smoke and commit a matching receipt: blocked by an initial 300-second Supabase database-backup startup timeout, then a failed separate CLI status check after a bounded Docker restart.
- [x] Document runner-provisioning limitations and manual acceptance; save the scoped branch with evidence generation explicitly pending.

## Discovery notes
- Baseline: `03f8f7b5ab3ec469cdcc324e3603cd13a3f44fc7` (`origin/main`), isolated from the original checkout.
- Existing in-progress changes in original project folders remain untouched.
- Missing hosting/account capabilities are reported as concrete limitations; they are not permission to weaken required checks.
- Docker Desktop inventory initially timed out, then became responsive. The corrected generator retained a private outer log identifying a 300-second Supabase startup timeout. Its stack log last reported database-backup startup. After a bounded engine restart, a retry completed the start command but failed the separate local Supabase status check. Direct probes reported an unhealthy synthetic database and intermittent Docker/pg_isready timeouts. No required native case ran and no receipt was produced. All three disposable simulators were removed; no physical device was used. The underlying local engine/database cause remains unconfirmed; no volumes were deleted.
- Hosted native foundation and repository jobs passed at source `4cf5e2c`; the source evidence job failed on the absent receipt as intended. The full hosted backend job also passed, including both local API key modes and restart checks; CI Verify fails only because the connected receipt is absent.
- Pinned Supabase CLI 2.119.0 supports an explicit temporary `--workdir` and project-scoped `stop --project-id --no-backup`. A fresh disposable namespace may avoid unhealthy backup reuse, but it cannot guarantee Docker daemon health. Existing named-stack volumes must remain untouched, and ownership uncertainty must fail cleanup and evidence generation.

- Before the isolated live smoke, all 81 repository tests pass outside sandbox socket restrictions, including strict foreign-volume/mount refusal, private source-copy invariants, owned cleanup failure paths and unchanged legacy stack behavior. This establishes orchestration checks only, not passing connected-native evidence.

- The first isolated live attempt initialized schema and applied all four migrations, then the adapter refused a create request. Fresh owned resources were cleaned up; no native case ran. The current static `container_scope` diagnostic cannot distinguish name/label/network/mount/port rejection. Add only closed-set refusal reason codes with no request content, verify redaction and every guard path, then rerun on a new namespace before considering any source-backed compatibility correction.

- Fixed diagnostics confirmed the refused request is exactly the fresh namespace PostgREST service (`create_service_rest`). Pinned CLI 2.119.0 `start --help` confirms `--exclude postgrest`. The bounded smoke exercises localhost Auth, direct Postgres transactions and the custom Swift HTTP server; it never calls PostgREST. Exclude only that unused service in ephemeral smoke, retaining all backend/native assertions and the three-service allowlist; preserve the existing full/legacy stack command. Add an orchestration regression and re-run isolated acceptance.

- Minimal-service regression and fixed private diagnostics are verified in the complete 83-test repository suite (all pass). The existing default/full backend service set is unchanged; ephemeral smoke alone excludes PostgREST and still requires Auth/Kong health checks and every integration/native assertion.

# Plan

Require local, source-matched connected-native smoke evidence when a change touches the connected boundary, while preserving real local backend and native safety boundaries. Combined Docker/Xcode runner provisioning is a follow-up.

## Scope
- In: Scoped CI enforcement, automated validation, meaningful orchestration regressions, and canonical verification documentation for Second Look.
- Out: Product feature changes, deployment, paid services or account changes, personal data, physical-device operation, and release signing/publishing.

## Action items
- [x] Read Backend-Operations and Verification docs, native fixture guards and shared-state wrappers.
- [x] Confirm existing CI Verify enforcement and map supported hosted versus local native-stack execution.
- [x] Add a bounded connected-native smoke/evidence gate using existing wrappers and synthetic services without relying on an unsupported hosted Docker/Xcode combination.
- [x] Test that missing, stale, skipped, failed or wrong-source evidence cannot satisfy the affected-boundary gate.
- [x] Validate repository and orchestration regressions: all 64 repository tests pass outside sandbox socket restrictions. Connected smoke remains blocked by local Docker readiness; no passing receipt is claimed.
- [x] Document runner-provisioning limitations and manual acceptance; save the scoped branch with evidence generation explicitly pending.

## Discovery notes
- Baseline: `03f8f7b5ab3ec469cdcc324e3603cd13a3f44fc7` (`origin/main`), isolated from the original checkout.
- Existing in-progress changes in original project folders remain untouched.
- Missing hosting/account capabilities are reported as concrete limitations; they are not permission to weaken required checks.
- Docker Desktop was started but its container inventory did not respond within a bounded 20-second probe. The first generator discarded outer output and left no phase diagnostic; the corrected generator now retains a private log path on failure. A new run has not yet diagnosed the cause. The source-matched native receipt remains absent; affected-source CI is expected to fail until the bounded smoke passes on a responsive local host.

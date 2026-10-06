# Plan

Prepare and help provision Second Look's dedicated Supabase Free project for Milestone 2 on `codex/milestone-2-private-shared-state`. Keep costs at zero by selecting a Free organization, prepare the existing Swift server for current Supabase API keys and a Free host, and record actual setup and acceptance evidence separately from the verified localhost implementation.

## Scope
- In: Supabase dashboard setup assistance; Free-plan safeguards; current API-key compatibility; a reproducible Release container for the Swift service; private migration/account/host setup instructions; relevant tests, documentation, local checkpoints and final branch push.
- Out: Paid plans/add-ons, unrelated existing projects, photo buckets or real images, notifications, distribution, opening a PR or merging. Hosted acceptance and two-device acceptance remain incomplete until actually run.

## Action items
[x] Inspect current repository, provider headers, canonical contracts, official Supabase/Render guidance and the previous CI result. The previous run passed repository/native jobs but canceled the backend and aggregate; no green full CI is claimed.
[x] Checkpoint this resolved repository plan before implementation. Treat operator sign-in and private credential entry as external setup prerequisites; they do not block safe repository preparation. Plan checkpoint: `74ba4a2`.
[x] Correct privileged RPC headers for modern Supabase secret keys while preserving legacy local-stack support; test Auth bearer verification and both RPC key modes. Checkpoint: `a4e2027`; actual local integration passes with both modes and CI now exercises both.
[x] Add and verify a Release Docker deployment path that contains no credentials, demo flags or synthetic-evidence route; document Free host settings and secrets entry. Linux/arm64 smoke passes, including sanitized 404 handling repaired after a real connection-close failure.
[ ] Help create the dedicated project in a verified Free organization after operator sign-in. Choose a nearby US region as a reversible default where available, keep public signup/anonymous access disabled, and defer password entry to the operator.
[ ] Apply the existing migration only to the explicitly selected new project and configure two operator-managed accounts/private server secrets when access is available; never publish credentials or participant identifiers.
[x] Run repository/Core/backend tests and relevant local Auth/Postgres integration. Repository tooling 12, Core/transport 29, backend Debug/Release 8 each pass; both actual local API-key modes and restart pass. Container health/unauthenticated denial/synthetic-route absence/configuration checks pass; hosted and device checks remain unavailable.
[x] Update canonical operations, decisions, roadmap/status and verification docs with the Free setup, cost limits, actual state and remaining prerequisites; review task-owned files for the final save on the existing branch. The final commit/push result is recorded in Git and the task handoff.

## Open questions
- None block repository preparation. Supabase operator sign-in is pending in the opened dashboard; project-password/account credentials and any host authorization prompts must be completed privately by the operator at the relevant step. No paid upgrade is authorized.

# Plan

Fix the misleading hosted sign-in error discovered during Milestone 2 acceptance, then resume private sign-in, pairing and shared-write checks on the existing feature branch. Supabase's actual failed password request reports HTTP 400 / `invalid_credentials`; reproduce its numeric `code` and string `error_code` response through the exact app transport before fixing behavior. Keep all credentials private and distinguish local regression evidence from hosted acceptance.

## Scope
- In: Auth-specific bounded error decoding; a clear incorrect-email/password message; deterministic synthetic transport regressions; repository/Core/native and local Auth/Postgres/HTTP validation; a fresh signed simulator client; canonical evidence and checkpoint/final branch save; continued hosted acceptance after private operator input.
- Out: Password reset/new accounts, permissive authorization, changing server/schema, paid services, real media, distribution, hosted resets/deletion, PR or merge. Hosted pairing/writes remain pending until exercised.

## Action items
[x] Inspect the actual simulator alert and hosted Auth log without publishing participant data. Confirm the 11:28 password request was rejected with 400 / invalid_credentials; an invented invalid-credential HTTPS probe returns the same format. Read transport/model, package/test seams, product/architecture/ADR and verification constraints.
[ ] Checkpoint the resolved plan, then add a typed Auth rejection seam and separate transport test target. Delegate only synthetic transport tests with explicit file ownership; keep app behavior and Git operations with the parent.
[ ] Run a minimal red regression against the exact SharedAuthClient signIn path and observed provider format. Show ranked falsifiable explanations after the loop is established; confirm the response-format mismatch before altering decoding.
[ ] Decode only recognized Auth error_code values in Auth requests, expose a clear invalid-credential message, and preserve command-service error mapping, unknown/malformed failure behavior, secure credential handling and existing session guards. No raw provider message or request data enters UI/logs.
[ ] Verify the regression, refresh/session rejection and successful synthetic response handling. Run swift test, repository checks, the ordinary native/Release boundary suite and the existing isolated localhost modern-key integration workflow. Do not point destructive localhost scripts at hosted endpoints.
[ ] Rebuild/install/launch the signed hosted Debug client on the existing simulator with public connection fields only. Have the operator retry existing credentials privately; verify pairing/convergence/isolation only after sign-in and access-grant confirmation where required. Native control may still require operator interaction.
[ ] Update Verification and relevant setup/operations guidance with actual failure/fix evidence, executed results and precise limits. Product contracts and server architecture need no change for Auth error presentation alone.
[ ] Review task-owned files, remove transient diagnostics, checkpoint the fix and save/push the existing feature branch using save-branch. Leave M2 in progress and do not automatically deploy app-only/docs changes.

## Open questions
- None block the correction. Existing credential entry is an external operator step; no passwords or tokens should be provided in chat. Authenticated hosted pairing/writes remain the ongoing objective.

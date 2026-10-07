# ADR 002 — Authoritative private shared state

Date: October 5, 2026. Status: provisional implementation; hosted acceptance pending.

## Context

Milestone 2 needs two authenticated identities to share one private space. A role picker cannot authorize a user. Concurrent clients must preserve routine snapshots, fixed run roles, exact evidence versions and terminal closure. Account changes must clear protected state before delayed network responses can publish.

## Decision

Use Supabase Auth/Postgres through a Swift/Vapor command service that imports `SecondLookCore`. Compare the alternatives in [Backend Comparison](../Backend-Comparison.md). Pin Vapor 4.122.2 and Supabase CLI 2.119.0; keep the core package dependency-free.

The server verifies the bearer token with Auth on each request, then checks a configured allowlist of exactly two distinct account IDs. One account creates the singleton private space; the other joins through a random, targeted, expiring, one-use invitation. The database stores its SHA256 digest, not its plaintext. An unjoined owner can reissue an invitation without losing state. A 15-minute invitation expiry is an engineering default; it is unrelated to reminders, photo retention or unreviewed timeout.

The phone sends typed commands with expected space/run/routine/evidence versions, never an actor, server clock or arbitrary replacement state. The service derives the actor from verified identity and applies the existing rules. Only privileged database RPCs can commit the resulting aggregate. A row lock and revision compare-and-swap atomically save state and an actor/request-bound command receipt. An identical retry returns current state plus the original created ID; reusing an ID with another actor or payload is rejected. A concurrent conflicting change requires a fresh snapshot and explicit new action.

The private SQL schema is not exposed to PostgREST. Its tables have no direct client privileges and RLS is enabled. Public definer RPCs have a fixed empty search path and grant execution only to the service role. This credential is a trusted server capability, not client authorization; it never belongs in app configuration.

Connected iPhone state is memory-only in M2. Keychain holds account credentials scoped to app identity and provider/server configuration. A new session gets an epoch; state publication, errors, credential saves and navigation require that epoch still to be current. Foreground polling/manual refresh fetch server snapshots; commands publish only after successful server commit. Local M1 stores and Debug role/fixture controls are a separate composition.

## Boundaries and consequences

The JSONB aggregate deliberately favors one bounded private space over premature entity infrastructure. It requires aggregate size and performance review before broadening scope. The Swift service introduces hosting, availability, TLS, rate-limit, monitoring and secret-rotation responsibilities. No production deployment is implied by a local development configuration.

M2 has no real photo send API. A Debug server on explicit loopback local-development configuration may create clearly synthetic evidence metadata solely for review authorization tests. Normal composition and Release reject this capability. M3 still owns photos, object storage, media authorization and real cleanup. Unpairing, remote jobs, push and distribution remain deferred.

Local Auth/Postgres/HTTP tests establish local behavior only. Hosted account provisioning, region/privacy review, secrets, service operations and two-device acceptance remain unverified. Do not declare the full M2 exit complete from unit tests or localhost evidence alone. Operations and test commands are in [Backend Operations](../Backend-Operations.md); actual evidence belongs in [Verification](../Verification.md).

## October 6 Free setup follow-up

The operator authorized help setting up a dedicated Supabase Free project. Use a verified Free organization and keep paid upgrades/add-ons deferred. Render Free is the proposed Swift host for development acceptance, with no payment method to prevent bandwidth/build overage charges; its idle sleep and quotas are availability limits. This avoids consuming the operator's photography Vercel deployment allowances. It does not establish hosted readiness or a production availability commitment. [Supabase Free Setup](../Supabase-Free-Setup.md) records the exact steps, current cost-control sources and remaining operator prerequisites.

The server's modern secret key is sent on `apikey` without a non-JWT bearer header; Auth verification continues to use the actual user token. Legacy JWT RPC support remains for the pinned synthetic localhost stack. The Release container consumes configuration at runtime and excludes test fixtures and Debug evidence endpoints. Render also supplies configured Docker environment values as build arguments; the Dockerfile must never declare or reference sensitive arguments. The operator-created Free project in West US (Oregon) now has the private-space migration installed, restricted automatic RLS helper permissions, passing hosted catalog checks and two confirmed Auth accounts. Render's Hobby workspace/no-card/$0 pipeline safeguards are verified and the Free form is prepared, without credentials or deployment. Region is an engineering selection, not a completed privacy/legal review. Actual hosted key authorization, private server allowlist/configuration, Swift deployment and account/device acceptance remain pending; installation/account checks do not close M2.

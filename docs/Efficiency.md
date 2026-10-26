# Resource efficiency and capacity

The two-person Milestone 2 composition stays on Supabase Auth/Postgres and the Swift command host. This branch changes work performed, not service plans. Application/SQL changes require the normal reviewed deployment; no hosted rollout or new paid resource is part of the efficiency PR.

## Synchronization budget

| Operation | Current implementation | Resource effect |
| --- | --- | --- |
| Full membership/foreground/manual refresh | One authenticated membership response admitted by the existing coordinator checks | Removes the normal second snapshot GET; no held content is revealed from a conditional response |
| Active unchanged poll | Exact space/revision and strong server content validator permit a small HTTP 200 unchanged reply | Reduces host-to-phone bytes; server still reads and fully validates the database state |
| Changed or incompatible/older server | Full legacy snapshot; absent/malformed optional ETag disables conditional reuse | The phone remains usable with the existing full-response server |
| New command | Auth + `sl_prepare` + atomic commit in the normal success path | Three provider calls rather than four; races/proof reconciliation can need more |
| Validation | Private run/archive indexes after duplicate-ID guards | Run/archive correlation becomes linear; other semantic/capacity checks remain |

A validator is the server's SHA256 of its exact encoded full snapshot body. It is scoped to the exact admitted snapshot and process-memory account/backend/space, cleared on suspension/scope loss, and never authorizes access. Revision equality alone is insufficient: different valid content at the same revision returns a full body and is rejected by the existing consistency guards. HTTP 3xx, including 304, remains refused. Every request still verifies the user with Auth, allowlist and membership; all shared responses retain `Cache-Control: no-store`.

The active polling policy starts at five seconds, increases unchanged delays by five seconds to thirty, and resets for accepted changes/manual refresh/foreground. Transient failures use 5/10/20/40/80/120-second backoff. Busy, ineligible and canceled work adds no request. The scheduling epoch resets only the periodic task; lifecycle callbacks own foreground revalidation independently. A peer's change can therefore take up to the idle polling delay plus request duration to appear. Manual refresh remains available. This introduces no background keep-alive, notification, offline queue or scheduler.

Two continuously active clients previously performed nominally 48 full snapshot GETs/minute. One GET at the same five-second cadence is 24; steady thirty-second idle polling is four (about 92% fewer). Actual cadence includes request duration and inactive periods. These are request-count scenarios, not measured monetary savings or a claim that database-to-server bytes disappear.

## Existing ceilings and retention

Preserve `SecondLookCore/SharedStateLimits.swift`: bounded UTF-8 fields, 64 items/list, 128 routines, 512 runs/archives, 64 decisions/item and 2 MiB canonical state. Core reserves capacity for open-run closure. The database separately admits at most 8,192 receipts plus proposed receipt/open-run reserves under the existing row lock. Reads and request-bound receipt recovery remain available at capacity. No history, receipt or photo is removed to make space.

The phone's existing streamed receiver rejects declared/chunked excess before append: 256 KiB Auth success, 16 MiB shared success and 16 KiB errors. A provider `.count` check after complete download would not bound buffering; this PR makes no such claim. The global API admission gate bounds concurrent private route processing through response creation, with no per-IP maps, queue or Redis. Its slot is released before Vapor finishes transmitting a body to a slow client; it is not a bound on all open connections, a sustained-abuse limiter or a fairness guarantee. A typed 429 requests a one-second pause; periodic reads back off. Commands retain their original envelope for explicit same-ID retry, even for a first refusal: an admission refusal on a later attempt cannot disprove an earlier commit with a lost response.

## Observing usage without private content

Run [inspect-shared-capacity.sql](../scripts/inspect-shared-capacity.sql) through a deliberate administrative connection to the intended database. It reads only sizes/counts in a bounded read-only transaction. Database JSONB text, stored/compressed size, canonical JSON and HTTP/escaped envelope bytes are different measures. This script does not report a provider's billed usage and does not expose task text, participant IDs or credentials. Private tables/RPC privileges remain unchanged.

Review provider Usage pages separately for database, egress and build quotas. Investigate at a chosen warning threshold (for example half of included usage) before capacity rejection becomes likely; choose actual operating thresholds from observed use. Keep Free organization/instance choices, manual deploys, disabled previews and the documented no-card/$0 pipeline-purchase safeguards. Reverify billing before any paid-plan/card/add-on change; a pipeline limit is not a universal dollar ceiling.

Before the next schema upgrade, maintain a private encrypted export and rehearse restoration in an isolated environment. This PR neither exports private data nor provisions backup infrastructure. Receipt pruning needs a reject-old-command/tombstone contract; history paging needs atomic closure/provenance design. Both remain future decisions, not automatic expiry.

## Verification economics

CI runs automatically on pull requests and main pushes. A feature branch before its PR can use `workflow_dispatch`; removing automatic codex-branch pushes avoids two full runs for each open-PR update. Required `CI Verify` still requires repository, native and both server key-mode checks. No path filters skip that required workflow.

The source-only Swift dependency cache is keyed by runner OS/architecture, pinned Swift version and manifests/lockfile. It excludes compiled output, databases, fixtures, credentials and logs. Docker’s BuildKit mount can reuse dependency downloads when the builder retains that cache; local support is verified, while cross-build retention on Render is not established. Pinned image digests and resolved-version enforcement remain; no cache enters the runtime image. The first use can still be a cold build. No new GitHub artifact archive or paid cache service is introduced.

## Later media

Milestone 3 must benchmark human-readable on-device resizing/compression and upload byte/pixel budgets before enabling real photos. Store private media outside the aggregate under stable upload identities; avoid durable reviewer caches and preserve account/access purge. Durable cleanup intent belongs with logical closure. No default age-based expiry, AI verification, real photo transport or cleanup worker is added here.

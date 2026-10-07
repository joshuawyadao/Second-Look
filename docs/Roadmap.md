# Roadmap and acceptance

Milestones **0–1** established the local foundation. Milestone **2 is in progress** with a provisional Supabase Auth/Postgres and Swift command-service design. “Local” means a native app or local Auth/Postgres/HTTP stack; “simulated” means synthetic identities, evidence, service responses, retry, or cleanup. A local stack can exercise real authentication and database transactions but does not prove hosted operation, two-device behavior, camera behavior, push delivery, or media deletion. [Verification.md](Verification.md) records actual commands and outcomes.

| Milestone | Deliverable and exit condition |
| --- | --- |
| 0 — Repository and documentation | Canonical product, architecture, roadmap, verification, and implementation plan; reproducible project/test workflow; no invented credentials, backend, or completed-feature claims. |
| 1 — Native local foundation | SwiftUI navigation, editable routines and one-offs, independent snapshot runs, standard progress, settings models, text-only history, local approval/replace/closure rules, durable relaunch, and isolated Debug fixtures. Meaningful core/persistence tests and an available-simulator build/run. Real sharing remains unimplemented. |
| 2 — Private shared state **(in progress)** | Choose backend/auth against privacy, transaction, jobs, APNs, cost, and operation needs. Pair two authenticated identities; enforce access and versions on the server; converge clients. A third account and performer self-approval fail. Hosted provider accounts and secrets are prerequisites to hosted acceptance. Local synthetic-account tests do not close this gate. |
| 3 — Real photos and cleanup | Native camera/library, private upload/retry, versioned review, notes, replacements, text-only archive, tracked deletion. Prove no in-app capture enters Photos and verified cleanup reports only confirmed scope. |
| 4 — Recovery and concurrency | Handle interrupted/unknown uploads, duplicate actions, restart, cancellation races, stale notifications, offline devices, unpairing, and access rechecks. Closed runs stay closed and disconnected clients reconcile. |
| 5 — Reminders and optional expiry | Add durable state-aware push/scheduling, grouping, repeat/snooze/quiet hours, time-zone/DST behavior, and explicitly enabled unreviewed timeout. Off retains open evidence; expiry never completes a run. |
| 6 — Device acceptance and daily trial | Resolve signing/distribution for both real iPhones, exercise the full acceptance matrix including Photos, accessibility, denied permissions, and unreliable connections, then document limits and operating steps. |

Shortcuts and automatic starts, broader release, more users, and other platforms are later considerations, not commitments. The [backend comparison](Backend-Comparison.md) and [ADR 002](decisions/002-private-shared-state.md) record the provisional vendor/service choice. [Supabase Free setup](Supabase-Free-Setup.md) has a verified private schema, two confirmed accounts and a live Render Free Release server with approved private configuration. Hosted HTTPS health and public denial boundaries pass; authenticated hosted app acceptance remains pending. Paid services, Apple enrollment, and distribution remain deferred.

## Acceptance matrix

“M1 model” means domain/persistence tests or synthetic UI demonstration, not production enforcement. “Later” identifies when the full behavior must be proven. Milestone 2's server/client work is tracked in [Verification.md](Verification.md); do not treat the matrix's local model column as evidence of hosted acceptance.

| # | Scenario | M1 evidence | Later full proof |
| --- | --- | --- | --- |
| 1 | Empty lists cannot start; all-standard run closes on final check. | Local model/UI | M2 connected transaction |
| 2 | Mixed run stays open until every current required photo is approved. | Synthetic submission/review | M2–3 shared/media |
| 3 | Performer cannot approve own required item. | Local actor rule | M2 server authorization |
| 4 | Template edits leave open runs unchanged; new runs copy no evidence. | Snapshot/persistence tests | M2 sync |
| 5 | Second run preserves first and isolates progress. | Local model/relaunch | M2 sync |
| 6 | Canceling capture/import/replacement preview preserves old evidence. | Synthetic preview/commit rule | M3 real media |
| 7 | Request another photo needs a note and fresh approval. | Local state rule | M3 connected review |
| 8 | Replacing during reviewer view makes old decision stale. | Exact-version local test | M2–4 server race |
| 9 | Final approval racing cancellation has one terminal outcome. | Sequential local terminal rule | M4 transactional race |
| 10 | Failed/unknown upload retries without duplicate submissions. | Synthetic retry state only | M4 network reconciliation |
| 11 | Offline drafts survive restart without age deletion. | Synthetic local draft persistence | M3–4 real media/offline |
| 12 | Timeout Off retains open unreviewed/approved photos. | Default/settings model only | M3–5 real media/scheduler |
| 13 | Enabled expiry blocks stale approval, asks for replacement, never closes. | Settings model only | M5 scheduled expiry |
| 14 | Reminders cannot change retention; routing/cancel follow state. | Independent settings model only | M5 scheduler |
| 15 | Disabled/stale/snoozed/quiet notifications leave state accessible. | Review queue without push | M5 delivery/quiet hours |
| 16 | Closure cleans current/superseded media; failure retries without false success. | Text archive/simulated cleanup-pending | M3–4 storage retry |
| 17 | Offline devices purge revoked evidence on reconciliation. | No real evidence cache | M4 device/network |
| 18 | Unpair/account change blocks unauthorized history/media. | Demo identities only | M2–4 auth/cache |
| 19 | App photos never enter Photos; imported originals stay untouched. | No real media in M1 | M3, M6 device inspection |
| 20 | Denied camera/import, low storage, larger text, VoiceOver recover clearly. | Local UI accessibility/storage paths where possible | M3, M6 device checks |

The immediate task plan lives in [Implementation-Plan.md](Implementation-Plan.md). This roadmap remains the durable milestone and acceptance reference as that task plan changes.

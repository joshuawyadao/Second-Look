# Architecture

## Local foundation boundary

Milestone 1 established a native, local iPhone app. The checked-in `SecondLook.xcodeproj` builds SwiftUI views in `SecondLook/`; a dependency-free `SecondLookCore` Swift package owns checklist rules and local persistence. This reversible foundation permits simulator builds and portable rule tests, with iOS 17 as the provisional deployment floor. Its Debug `SECONDLOOK_DEMO` composition exposes synthetic role/evidence/retry/cleanup controls and uses a separate demo data location. Release excludes those controls. [ADR 001](decisions/001-native-local-foundation.md) records the foundation choice. Build and test outcomes belong in [Verification.md](Verification.md).

| Milestone 1 layer | Owns | Does not claim |
| --- | --- | --- |
| Core models and transitions | Routine definitions, run snapshots, fixed actor/version checks, progress, simulated submissions/decisions, terminal state, text-only archive, independent settings | Server authorization or physical proof |
| Local store | Versioned JSON in Application Support, atomic writes, explicit decode/write errors, restoration of definitions/runs | Shared sync, backup/retention guarantees, real media storage |
| SwiftUI app | Routines, Review, History, editor/checklist/preview/settings navigation; accessible labels and honest local/simulated status | Authenticated identities, capture, remote sending, push |
| Debug demo adapter | Synthetic participant/evidence responses and failure/retry/cleanup-pending paths, isolated from personal data | Real upload, another-device review, deletion |

Pass time explicitly to core commands and use fixed timestamps in tests; no expiry scheduler runs yet. Commands should change state only after actor, item, run, and expected submission-version checks. Persist the result before presenting it as durable; a save error must remain visible and recoverable. A local draft must never be labeled sent.

## Key records and invariants

Withdrawal takes an expected submission version through the core and native confirmation path. It rejects an old intent before mutation and retains a separately prepared replacement draft. Relaunch preserves that draft, and sending it advances the submission version rather than reusing the withdrawn version.

Restoration binds each current decision to the assigned reviewer and exact current submission version. Approved/requested status must match its verdict; a request needs a nonempty note. Only accepted evidence can carry a decision, while sending/failed/waiting records carry none. Draft previews stay separate and use the next version. Inconsistent records fail loading as a corrupt document before becoming editable state; loading does not silently repair or overwrite the saved file. This strengthens schema-v1 validation without a schema migration or connected authorization claim.

`Routine` and ordered `RoutineItem` are mutable definitions. `ChecklistRun` and `RunItem` snapshot requirements, participant roles, and settings at start; a one-off run has no routine ID. `PhotoSubmission` carries one current item/version/source/status and an optional accepted-at time; review deadlines are deferred; `ReviewDecision` names exact version, actor, decision, note, and time. A run closes as Completed only if all standard items are checked and all high-priority current submissions are approved. Canceled is separate and terminal. Only the assigned other participant may review. Committing replacement/withdrawal invalidates approval; discarding a preview does not. Closed runs reject later changes. Archive output contains text only.

`ReminderPreferences` and review-timeout settings are separate models; timeout starts Off and no M1 scheduler runs. M1 stores one run-level snooze/mute/quiet-hours set; recipient-specific controls and timezone-aware scheduling still need modeling before Milestone 5. `CleanupStatus` is separate from run outcome: not needed without evidence, pending for synthetic evidence at closure, or a simulated acknowledgment. Durable `CleanupWork` jobs remain later work. Pending or failed cleanup cannot be displayed as confirmed deletion. The local adapter models transitions without real image bytes. No app-managed image or live URL belongs in the archive.

The shared native preference fields initialize an enabled snooze one hour ahead, constrain new selections to the future, and show an expired saved value without renewing it. This editable example is saved with the routine/run settings; it does not create a reminder scheduler or an agreed cadence.

## Native privacy cover

Each scene owns an opaque privacy window above its presented sheets and alerts. Scene/app deactivation shows the cover; activation removes it. The cover does not become the key window or replace editor state. Scene attachment and disconnection manage its lifetime independently of sheet navigation. This protects local checklist content as well as future media; it is not an access-control mechanism.

Only `SECONDLOOK_DEMO` launches with both `-ui-testing` and `-privacy-testing` register show/hide Darwin notification hooks for deterministic UI tests. These test signals invoke the same cover controller as scene activation; observers are removed on disconnection. Release compilation excludes the hooks, and the built-binary boundary check rejects their markers. Tests cover the root screen, routine editor, and Local settings sheet. OS snapshot timing and keyboard behavior still require device/runtime acceptance; observed simulator evidence is in [Verification.md](Verification.md).

## Milestone 2 connected boundary, in progress

The [backend comparison](Backend-Comparison.md) and [ADR 002](decisions/002-private-shared-state.md) record a reversible choice: Supabase Auth/Postgres behind a Swift/Vapor command server. The service reuses the dependency-free core transitions rather than trusting client mutations. It validates each bearer token with Supabase Auth `getUser`, derives the actor, checks the explicit two-account allowlist and current space membership, and supplies server time. Password sign-in and refresh occur through Auth; the iPhone receives only public configuration and keeps session credentials in Keychain.

The private Postgres schema holds one shared space with at most two distinct account IDs, its core state, a monotonic revision, a targeted expiring invitation hash, and command receipts. Only server-side service-role RPCs can create/join/read/commit; direct app roles have no table or RPC access. The owner can rotate an unused invitation without resetting state. Joining consumes it under a row lock. Each command checks the expected shared revision and relevant core versions, then atomically writes the new state, revision, and actor/request-bound receipt. Repeated command IDs with a different actor or body fail; an exact retry returns the current snapshot and original created ID. Run snapshots fix performer/reviewer roles; an owner cannot review their own high-priority item, and a terminal run cannot reopen. The command interface does not accept arbitrary client state.

The native connected composition keeps shared state in memory and refreshes it after sign-in, foreground return, committed commands, manual refresh, and a five-second active-scene poll. Background transitions invalidate pending publications and discard protected navigation/state; an installed account must revalidate membership before displaying shared state again. Account-scoped session epochs reject stale responses and clear protected navigation/state on sign-out or account switch. The local Debug demo remains separate; its role picker is never authorization. The Debug localhost-only synthetic-evidence route supplies test metadata without an image. The production connected path has no real photo upload or synthetic-evidence command.

Local Supabase Auth/Postgres/HTTP integration with synthetic accounts exercises this boundary; it cannot establish hosted authorization or two-device behavior. [Backend Operations](Backend-Operations.md) describes the local workflow, and [Verification](Verification.md) records observed evidence. A Release server container and [Supabase Free setup](Supabase-Free-Setup.md) support the authorized hosted work. The Free project's private schema, permission checks and two confirmed accounts are prepared; private server credentials/allowlist/deployment and hosted app acceptance remain pending. Paid services, real media/cleanup, notifications, and distribution remain later work under the [roadmap](Roadmap.md).

## Future media and background work

When real media arrives, closure must write cleanup intent with the logical terminal transition; retryable workers then perform physical deletion. Private storage must grant short-lived participant reads. Notifications/reminders derive from current state after access rechecks and never become the record of truth. Uploads need stable logical IDs and unknown-outcome reconciliation. Offline intent replays only after membership/version checks. See [Product-Spec.md](Product-Spec.md) for lifecycle, privacy, and reminder contracts and [Roadmap.md](Roadmap.md) for milestone gates.

## Build and verification workflow

Open `SecondLook.xcodeproj` in Xcode or use a discovered iOS Simulator destination with `xcodebuild`; run `swift test` for the portable package and `./scripts/verify-repository.sh` for public repository safety. Exact successful commands, destinations, and limitations are recorded in [Verification.md](Verification.md). Real-device media and deletion checks require later milestones.

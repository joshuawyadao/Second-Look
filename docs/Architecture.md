# Architecture

## Local foundation boundary

Milestone 1 is a native, local iPhone app. The checked-in `SecondLook.xcodeproj` builds SwiftUI views in `SecondLook/`; a dependency-free `SecondLookCore` Swift package owns checklist rules and local persistence. This reversible foundation permits simulator builds and portable rule tests, with iOS 17 as the provisional deployment floor. Its Debug `SECONDLOOK_DEMO` composition exposes synthetic role/evidence/retry/cleanup controls and uses a separate demo data location. Release excludes that service and UI; it is local-only and **not** a two-person or distribution-ready product. [ADR 001](decisions/001-native-local-foundation.md) records the choice. Build and test outcomes belong in [Verification.md](Verification.md).

| Layer | Owns now | Does not claim |
| --- | --- | --- |
| Core models and transitions | Routine definitions, run snapshots, fixed actor/version checks, progress, simulated submissions/decisions, terminal state, text-only archive, independent settings | Server authorization or physical proof |
| Local store | Versioned JSON in Application Support, atomic writes, explicit decode/write errors, restoration of definitions/runs | Shared sync, backup/retention guarantees, real media storage |
| SwiftUI app | Routines, Review, History, editor/checklist/preview/settings navigation; accessible labels and honest local/simulated status | Authenticated identities, capture, remote sending, push |
| Debug demo adapter | Synthetic participant/evidence responses and failure/retry/cleanup-pending paths, isolated from personal data | Real upload, another-device review, deletion |

Pass time explicitly to core commands and use fixed timestamps in tests; no expiry scheduler runs yet. Commands should change state only after actor, item, run, and expected submission-version checks. Persist the result before presenting it as durable; a save error must remain visible and recoverable. A local draft must never be labeled sent.

## Key records and invariants

Withdrawal takes an expected submission version through the core and native confirmation path. It rejects an old intent before mutation and retains a separately prepared replacement draft. Relaunch preserves that draft, and sending it advances the submission version rather than reusing the withdrawn version.

`Routine` and ordered `RoutineItem` are mutable definitions. `ChecklistRun` and `RunItem` snapshot requirements, participant roles, and settings at start; a one-off run has no routine ID. `PhotoSubmission` carries one current item/version/source/status and an optional accepted-at time; review deadlines are deferred; `ReviewDecision` names exact version, actor, decision, note, and time. A run closes as Completed only if all standard items are checked and all high-priority current submissions are approved. Canceled is separate and terminal. Only the assigned other participant may review. Committing replacement/withdrawal invalidates approval; discarding a preview does not. Closed runs reject later changes. Archive output contains text only.

`ReminderPreferences` and review-timeout settings are separate models; timeout starts Off and no M1 scheduler runs. M1 stores one run-level snooze/mute/quiet-hours set; recipient-specific controls and timezone-aware scheduling still need modeling before Milestone 5. `CleanupStatus` is separate from run outcome: not needed without evidence, pending for synthetic evidence at closure, or a simulated acknowledgment. Durable `CleanupWork` jobs remain later work. Pending or failed cleanup cannot be displayed as confirmed deletion. The local adapter models transitions without real image bytes. No app-managed image or live URL belongs in the archive.

The shared native preference fields initialize an enabled snooze one hour ahead, constrain new selections to the future, and show an expired saved value without renewing it. This editable example is saved with the routine/run settings; it does not create a reminder scheduler or an agreed cadence.

## Later connected boundary

Before Milestone 2, compare providers using current official docs for two-user authentication, participant authorization, transactional reviews/closure, private media, durable jobs while phones are closed, APNs integration, operational load, and cost. No vendor or credentials are selected merely to run M1.

An authoritative service must validate membership, actor, expected run/submission version, and terminal state on every connected transition. It owns one logical closure plus cleanup intent in the same transaction; retryable workers perform physical deletion. Private storage grants short-lived participant reads. Notifications/reminders derive from current state after access rechecks and never become the record of truth. Uploads need stable logical IDs and unknown-outcome reconciliation. Offline intent replays only after membership/version checks. See [Product-Spec.md](Product-Spec.md) for lifecycle, privacy, and reminder contracts and [Roadmap.md](Roadmap.md) for milestone gates.

## Build and verification workflow

Open `SecondLook.xcodeproj` in Xcode or use a discovered iOS Simulator destination with `xcodebuild`; run `swift test` for the portable package and `./scripts/verify-repository.sh` for public repository safety. Exact successful commands, destinations, and limitations are recorded in [Verification.md](Verification.md). Real-device media and deletion checks require later milestones.

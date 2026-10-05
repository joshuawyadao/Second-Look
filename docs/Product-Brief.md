# Product brief

## Purpose and status

Second Look helps two people complete important everyday tasks and verify selected steps together. It aims to reduce the mental load of wondering whether a task was done and the photo-library clutter of sending evidence through Messages. A locked front door after bringing packages inside is a motivating example, not a product restriction.

Milestones 0 and 1 established the **local native iPhone foundation**. Any role switching, photo submission, review, retry, or cleanup in that demo is **simulated with synthetic data**. Milestone 2 is building authenticated private shared state using Supabase Auth/Postgres and a Swift command server; local integration work does not establish hosted or two-device acceptance. Camera/library evidence, notifications, media deletion, and device distribution remain later milestones. See [Product-Spec.md](Product-Spec.md), [Roadmap.md](Roadmap.md), and [Verification.md](Verification.md) for the detailed contracts, delivery sequence, and verified status.

## Confirmed product direction

- The first version is a private iPhone app for the owner and their girlfriend, with two distinct identities in one shared space. Public signup and multiple households are outside initial scope.
- Reusable routines are the main path; occasional one-off checklists use the same flow. Runs begin manually. Each item is standard or high priority.
- A standard item is completed by checking it. A high-priority item requires a photo and approval from the assigned **other** person. A run completes only when all standard items are checked and all high-priority items have valid approval.
- Camera capture is the primary evidence action; choosing a library photo is also supported. In-app capture must not automatically save into either person's Photos library, and importing must leave the original untouched.
- A completed run archives automatically as a text-only record. App-managed photos must be deleted through a reliable cleanup process; completion and confirmed cleanup are separate facts.
- An open run's age does not expire its photos. An optional timeout applies only to submitted, unreviewed photos and defaults **Off**. Review reminders and photo retention settings are independent. Reminders are needed for pending reviewers and performers who need to add, replace, or retry a photo.

## Reversible working assumptions

The handoff proposes these details for a coherent initial model; they are implementation assumptions rather than separately approved choices: active runs fix performer/reviewer roles; a run snapshots its routine; a one-off has no routine reference; multiple runs of one routine may remain open; an item has one current, versioned submission; canceling is terminal and distinct from completion; a request for another photo carries a note; and current evidence remains until replacement, withdrawal, closure, or an enabled unreviewed timeout. The [specification](Product-Spec.md) records the precise state and privacy rules for review.

The iOS 17 minimum, SwiftUI, portable Swift core, and checked-in Xcode project are reversible engineering choices. [ADR 002](decisions/002-private-shared-state.md) records the provisional Supabase Auth/Postgres plus Swift server choice after the [backend comparison](Backend-Comparison.md). It does not settle a hosted operator account, region, paid tier, supported devices, reminder cadence, timeout duration, signing, or distribution.

Do not introduce chat, social feeds, streak penalties, AI image verification, location tracking, monetization, public signup, or App Store launch work in this phase. A human reviewer can assess an image; the app cannot prove that a physical task happened or remains true afterward. Use invented names and synthetic images in public development; never commit personal photos, household details, or credentials.

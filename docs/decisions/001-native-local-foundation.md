# ADR 001: Native local foundation

Status: Accepted for Milestones 0–1 on October 2, 2026; revisit against real devices and connected requirements.

## Context

The handoff asks for a runnable private iPhone foundation before selecting a backend, paid service, or distribution method. The repository previously contained documentation and repository checks. Core rules need deterministic tests independent of UI, while the app needs to restore work after restart and demonstrate two-role flows without implying that a role picker is authentication.

## Decision

Use SwiftUI with a provisional iOS 17 minimum and a checked-in Xcode project. Put checklist models, state transitions, and versioned atomic JSON persistence in the dependency-free `SecondLookCore` Swift package; compose them in the iPhone app. Store app state in Application Support and surface read/write failures. Pass time explicitly to time-dependent commands and use fixed timestamps in tests.

Compile synthetic identities, evidence, retry, and cleanup demonstrations only under `SECONDLOOK_DEMO` in Debug, with a separate demo data location. Release excludes those controls and has no claim of shared use. Sample routine/media references are invented. Add no real photo bytes, camera/library access, backend configuration, push, or cleanup guarantee in this milestone. Keep reminder and timeout choices as persisted models; timeout defaults Off and no scheduler acts on them.

## Consequences and revisit points

`swift test` covers the package while `xcodebuild` verifies app composition on an available simulator. A checked-in project avoids a project generator dependency. JSON is sufficient for bounded local state but needs schema/version migration and recoverable errors; it is neither a shared database nor a backup policy. Demo rules can exercise exact-version transitions but cannot prove another person's authorization, actual uploads, deletion, or notifications.

Before Milestone 2, choose authenticated backend/storage using documented access, transaction, jobs, APNs, cost, and operational criteria. Before Milestone 3, define real media sizing, metadata, file protection, backup exclusion, and cleanup verification. Revisit iOS floor against actual devices. Paid Apple membership and distribution are Milestone 6 decisions.

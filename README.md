# Second Look

[![CI Verify](https://github.com/joshuawyadao/Second-Look/actions/workflows/ci.yml/badge.svg)](https://github.com/joshuawyadao/Second-Look/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Important tasks, double-checked.** Second Look is a native iPhone checklist app being built for two people in a private shared space. Standard tasks are checked off; high-priority tasks will need a photo and approval from the assigned other person.

**Current status: Milestones 0–1, local foundation.** Create and edit routines, make one-off checklists, start independent runs, restore progress after relaunch, and keep text-only completed/canceled history. Debug builds include a clearly labeled local demo for sample submissions, reviews, replacement, retry, and cleanup states. No real photo is captured or sent, and no other person receives anything.

## Run the iPhone app

Use Xcode 16 or newer with Swift 6 and an installed iOS Simulator runtime. Open `SecondLook.xcodeproj`, select the **SecondLook** scheme and an iPhone simulator, then Run. The provisional deployment target is iOS 17; no signing team or backend credentials are needed for simulator use. The checked-in project needs no generator or third-party packages.

Debug launches **Second Look Demo**, with the synthetic “Packages brought inside” routine. Start it or make your own. For a high-priority step, Preview sample evidence → Save local draft or Send sample. A send pauses so you can choose Simulate delivery or Simulate upload failure and Retry. Local settings can preview Demo Alex or Demo Sam; the assigned reviewer sees accepted pending submissions in Review. Completion archives automatically. Cancellation is a distinct terminal result.

The role picker, synthetic services, and sample evidence views are compiled only into Debug using `SECONDLOOK_DEMO`. Release uses a separate app identity and store, with local standard checklists and editable high-priority routine drafts; it cannot start a high-priority run without a connected reviewer. Release is **not** ready for shared use or distribution.

Reminder and timeout preferences are stored only. No notifications or expiry run; timeout defaults Off. Cleanup acknowledgments in the demo are simulated and never claim real media deletion.

## Verify changes

```sh
./scripts/verify-repository.sh
swift test
./scripts/verify-native.sh
```

Repository checks need Git and Python 3.10+. Native verification needs macOS/Xcode: it discovers an available iPhone simulator, runs package and UI tests, builds Release, and checks that the demo adapter is absent. Set `SECONDLOOK_SIMULATOR_ID` to choose another installed device and `SECONDLOOK_DERIVED_DATA` to choose build output. See [Verification](docs/Verification.md) for exact executed commands, results, manual checks, and limits.

## Project documentation

| Document | Purpose |
| --- | --- |
| [Product brief](docs/Product-Brief.md) | Confirmed scope and current boundaries |
| [Product specification](docs/Product-Spec.md) | Durable workflow, privacy, reminder, and lifecycle contracts |
| [Roadmap](docs/Roadmap.md) | Milestones 0–6 and the acceptance matrix |
| [Architecture](docs/Architecture.md) | Core rules, local persistence, UI, and future service boundaries |
| [Native workflow decision](docs/decisions/001-native-local-foundation.md) | Reversible tooling and deployment choices |
| [Verification](docs/Verification.md) | Checks, observed results, and unverified areas |
| [Implementation plan](docs/Implementation-Plan.md) | Replaceable tracking for this assignment |

Next is Milestone 2: compare and decide backend/authentication architecture before provisioning private shared state. Real camera/library media and cleanup, network recovery, notifications/timeouts, and two-device acceptance follow. Paid services, Apple enrollment, and distribution remain deferred.

## Public development

Use invented examples. Keep household photos, addresses, credentials, and private reviewer information out of this public repository. Ignored `local-data/`, `photos/`, and `uploads/` folders are workspace conventions, not app storage APIs. See [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), and the [Code of Conduct](CODE_OF_CONDUCT.md).

Changes to `main` require a pull request and passing `CI Verify`. Original code and documentation use the [MIT License](LICENSE), except where separately attributed.

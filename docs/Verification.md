# Verification

## Commands and requirements

Repository checks require Git, Python 3.10+, and a POSIX shell. The package requires Swift 6. Native checks require macOS, Xcode 16+, and an installed iOS Simulator runtime. The app provisionally targets iOS 17; no device signing or service credentials are needed for a simulator.

```sh
./scripts/verify-repository.sh
swift test
./scripts/verify-native.sh
```

The native script runs the package suite, discovers the newest available iPhone simulator, executes the Debug UI suite, builds Release, and checks its bundle identity and absence of the development adapter/role picker. Override `SECONDLOOK_SIMULATOR_ID` for a particular installed device or `SECONDLOOK_DERIVED_DATA` for output. It does not install a runtime or enroll a developer account.

To inspect destinations or launch manually:

```sh
xcrun simctl list devices available
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -showdestinations
```

Open `SecondLook.xcodeproj` and Run the **SecondLook** scheme on a simulator. Debug uses `com.joshuawyadao.SecondLook.demo` and Application Support/SecondLookDemo/state-v1.json. Release uses `com.joshuawyadao.SecondLook.local` and SecondLookLocal/state-v1.json. UI tests use a separate SecondLookUITests document; only Debug test launches accept `-ui-testing -reset-demo`. A normal launch never resets existing data.

## Observed validation — October 2, 2026

Environment: Xcode 27.0 (27A266a), Swift 6.4, iOS 27 simulator **iPhone 18 Pro**, discovered UUID `ADD1A583-C6C6-4937-A00D-B1112054D521`. This is evidence for that environment, not a claim that every supported iOS/device combination was tested.

- Repository verification: all seven Python regression tests pass, required files/local Markdown paths pass, shell syntax and whitespace checks pass.
- Core: 15 XCTest cases pass, with fixed timestamps including fractional seconds. Exact executed package command:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/second-look-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/second-look-swiftpm-cache \
swift test --scratch-path /tmp/second-look-core-build
```

- Native Debug build succeeded with this discovered destination:

```sh
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Debug \
  -destination 'platform=iOS Simulator,id=ADD1A583-C6C6-4937-A00D-B1112054D521' \
  -derivedDataPath /private/tmp/second-look-derived CODE_SIGNING_ALLOWED=NO build
```

- Release simulator build and binary boundary check succeeded:

```sh
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/second-look-release CODE_SIGNING_ALLOWED=NO build
python3 scripts/verify-release-boundary.py \
  /private/tmp/second-look-release/Build/Products/Release-iphonesimulator/SecondLook.app
```

The final native verification script passed: **15 core tests, 4 simulator UI tests, Debug test build/run, Release build, and Release boundary check**. Exact combined command:

```sh
SECONDLOOK_SIMULATOR_ID=ADD1A583-C6C6-4937-A00D-B1112054D521 \
SECONDLOOK_DERIVED_DATA=/private/tmp/second-look-derived \
./scripts/verify-native.sh
```

The UI suite verifies independent runs and process relaunch, one-off cancellation/repeat, simulated failure/retry/review/history, and visible invalid-setting errors without dismissing the editor. Earlier runs exposed a demo-banner/Back-button overlap and hidden sheet errors; both were corrected and the full suite now passes. Test selectors were also made scroll-aware for native list virtualization.

Manual visual checks covered the Routines screen in light appearance and dark appearance at the largest accessibility text size. The demo banner was compacted at accessibility sizes while retaining its complete accessibility label, then the Debug app was rebuilt and the layout checked again. Simulator display settings were restored. This is a limited visual check, not full VoiceOver acceptance.

The execution sandbox initially blocked SwiftPM compiler caches and CoreSimulator services. The commands above were rerun with host permission and temporary build/cache paths. No signing, membership enrollment, real-device install, or service provisioning was performed. A nonfatal AppIntents metadata warning is expected because Shortcuts are not implemented.

## Meaningful coverage

### PR review corrections — October 3, 2026

The withdrawal regressions raise the core suite to 17 tests. Both the explicit cache/scratch-path package command above and the combined native script passed all 17: stale and unauthorized withdrawal preserve state, closed runs reject withdrawal, and removing current evidence retains a replacement draft through JSON relaunch and resend.

`./scripts/verify-repository.sh` passes 9 tooling tests after adding force-added Xcode result/archive/dSYM bundle and build/cache regressions. Synthetic ignored contents are force-added in temporary Git repositories; both nested/case-varied artifacts and safe similarly named source/document paths are checked.

The combined native run passed 17 core tests and 7 of 8 UI tests, then failed the new snooze test because its row-center tap did not enable the trailing switch. Manual inspection confirmed the editor displays a future deadline. The test now taps the switch itself and asserts it is enabled before checking the deadline. The focused rerun passed, verifying a future date survives routine save/reopen:

```sh
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Debug \
  -destination 'platform=iOS Simulator,id=ADD1A583-C6C6-4937-A00D-B1112054D521' \
  -derivedDataPath /private/tmp/second-look-derived -parallel-testing-enabled NO \
  -only-testing:SecondLookUITests/SecondLookUITests/testSnoozeStartsInFutureAndPersistsWithRoutine \
  CODE_SIGNING_ALLOWED=NO test
```

All three new privacy UI tests passed in the combined run: the opaque window prevents root/editor/Local settings controls from being hit, restoration makes them usable again, and entered routine text remains. Test controls require both Debug test flags and are absent in Release. The separate Release simulator build and expanded binary boundary command above passed, checking the local identity and absence of demo/role-picker/privacy-test markers.

Manual Device Hub inspection on the same iOS 27 simulator showed the open routine editor covered in the app-switcher snapshot. Returning to the app restored the sheet and its entered synthetic name. The simulator used a hardware keyboard; software-keyboard/prediction-strip pixels were not checked. This single snapshot observation and deterministic cover tests do not establish timing on every supported runtime or physical device.

A follow-up Codex finding added two restoration regressions, bringing the core suite to **19 passing tests** in both the explicit cache/scratch-path command above and a combined native rerun. Malformed current decisions (self/unassigned actor, stale/future version, missing decision, verdict/status mismatch, missing acceptance, and invalid request notes) fail both disk loading and repository initialization without overwriting the file. Valid waiting/requested evidence, a replacement draft, a later approved version, and its terminal text-only archive still restore; historical decisions remain attached to their original versions. Hosted Xcode 16.4 failed to tap the privacy test overlay window; its test interaction correction is still being validated. No passing full hosted run is claimed for these follow-up changes yet.

The core suite covers empty and standard completion; distinct reviewer/actor checks; independent snapshots; routine edits/deletion; one-off/save-as-routine/repeat structure; undo while open; required review notes; exact-version replacement and stale approvals; preserved approval when a preview is discarded; failed-send retry without version duplication; both sequential closure orderings; text-only archive and cleanup separation; settings validation and Off defaults; atomic persistence across relaunch; malformed/unsupported and selected inconsistent saved documents; failed-write rollback.

The UI suite covers creation, independent runs, progress after process relaunch, one-off cancellation/repeat, synthetic submission failure/retry/reviewer approval/history, and editor error recovery. Assertions exercise native accessible controls. Synthetic tests do not establish real authentication, upload reliability, notification delivery, or deletion.

## Manual local acceptance

- Create/edit/reorder a routine, and create a one-off. Save and relaunch; definitions remain.
- Start the same routine twice using Resume or start → Start another run. Checking one run must not check the other. Edit/delete its routine; open runs keep their snapshots.
- Preview a high-priority synthetic sample, save a local draft, relaunch, and resume it. Send and choose the simulated response. A failed send can retry; an accepted submission appears only for its assigned reviewer.
- Request another photo with a note. Discard a replacement preview and verify the old evidence/note remains. Send a replacement and require a fresh review.
- Close by completion or confirmed cancellation; history shows the correct outcome and no evidence image. A simulated cleanup acknowledgment must never claim real deletion.
- Try large text, light/dark appearance, and VoiceOver; all actions should remain reachable and state must be described with text. Test an invalid timing value in an editor and verify the error appears without losing entered text.

## Limits and future checks

No real camera/library permissions, media bytes, uploads, pairing/accounts, scheduler, expiry, push, or deletion jobs exist. No physical-device Photos-library, backup exclusion, storage protection, offline two-device reconciliation, network race, or notification check can pass at this milestone. iOS 17 runtime and full VoiceOver-on-device acceptance remain unverified. Quiet-hours values are saved preferences only; timezone/DST scheduling is Milestone 5. The JSON loader checks its schema and selected invariants, not arbitrary hostile or hand-edited state; this is an app-owned local document, not an import format.

The repository verifier checks required files, common private filenames, escaping symlinks, local inline Markdown paths, and whitespace. It does not inspect photo contents or all possible secret patterns, and does not validate external links or Markdown anchors. Review staged content before publishing.

## CI

`CI Verify` runs on `main`, `codex/**`, pull requests, and manual dispatch. Ubuntu runs repository checks; macOS runs the native script. The final **CI Verify** job requires both jobs to succeed. Checkout is pinned, permissions are read-only, and checkout credentials are not persisted. Dependabot checks GitHub Actions weekly. Branch rules require a pull request, resolved conversations, and passing CI for `main`; this assignment only pushes its feature branch.

The initial hosted run selected Xcode 16.4 and exposed a UI test harness compatibility issue: its synchronous XCTest setup override is nonisolated, unlike the local toolchain's behavior. UI launch setup now runs in an explicit main-actor helper called by each test, preserving all four scenarios and their assertions. The final remote CI outcome is reported with the branch handoff.

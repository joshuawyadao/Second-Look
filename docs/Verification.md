# Verification

## Commands and requirements

Repository checks require Git, Python 3.10+, and a POSIX shell. The core package requires Swift 6; the pinned server dependencies require Swift 6.2+ (CI uses 6.2.1). Native checks require macOS, Xcode 16+, and an installed iOS Simulator runtime. The app provisionally targets iOS 17; no device signing or service credentials are needed for a simulator.

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

## Supabase Free setup — October 6, 2026

The operator signed in and created a dedicated **Second Look** project in the existing **Free** organization, in **West US (Oregon)**. The dashboard reports Healthy and Nano compute. Database password entry/submission was performed privately by the operator. No paid upgrade, add-on, Storage bucket or Swift host was provisioned. [Supabase Free Setup](Supabase-Free-Setup.md) records the remaining operator steps and official cost-control sources.

Saved Auth settings were verified after reload: public signup **Off**, anonymous sign-in **Off**, email/password **Enabled**, and email confirmation **On**. The exact checked-in `202610050001_private_space.sql` was staged and compared with its repository source, then run in this new project after the operator's action-time approval. The SQL editor returned **Success. No rows returned**. The read-only [hosted installation checks](../supabase/tests/hosted_installation_checks.sql) returned **seven true rows**: two private tables with RLS, denied direct schema/table access for all three API roles, five definer RPCs with empty search paths, service-role-only RPC execution, denied internal-function execution, and empty initial shared state/receipts.

The Security Advisor initially reported broad execute permissions on the dashboard-created `public.rls_auto_enable()` event-trigger helper, plus two private-table no-policy notices. The helper definition was inspected and execute privileges revoked from PUBLIC, anon, authenticated and service_role. Two hosted catalog checks returned **true** for API execution denial and the automatic RLS trigger remaining enabled. The Advisor then showed only the two expected **RLS Enabled No Policy** notices on the private tables; they were not dismissed or resolved through permissive policies.

These are hosted installation and permission-inspection results, not hosted Auth/HTTP app acceptance. Two operator-managed Auth accounts, private server configuration, Swift HTTPS deployment, actual user-token/key authorization, pairing/writes/convergence/restart and physical-device acceptance remain **unverified**. No real media was used. The app and server executable sources are unchanged in this setup-recording slice; no additional Swift/native test cases or reruns are needed. Repository checks are run before saving this slice.

The API-key correction keeps modern non-JWT secrets on `apikey` only, legacy service-role JWTs on their existing headers, and actual user bearer verification independent of the server secret. The localhost integration script now supports `--modern-keys`, and CI exercises both modes. Request tests cover the headers, returned snapshots and rejection of a verified third account.

- `./scripts/verify-repository.sh`: **12 tooling tests pass**; local Markdown references and whitespace checks pass.
- `swift test`: **29 Core/transport tests pass**.
- Backend Debug and Release request/boundary suites: **8 tests pass in each configuration**, including bounded HTTP missing-route/unhandled-error responses; the two gated integration cases skip without their private fixture.
- `SECONDLOOK_BACKEND_SCRATCH=/private/tmp/secondlook-backend-build ./scripts/verify-shared-state.sh`: **passes** actual localhost Auth/Postgres/HTTP acceptance, privilege/expiry/rotation/receipt checks and server restart using legacy JWT API keys.
- The same command with `--modern-keys`: **passes** the same acceptance using actual local modern publishable/secret keys. This includes password sign-in, user-token verification/refresh, membership denial, atomic writes/retries/concurrency and restart; these are synthetic local accounts, not a hosted deployment.

`docker build -f Backend/Dockerfile -t secondlook-m2-server:free-setup .` **passes** using pinned official Swift 6.2.1 and Ubuntu 24.04 images. A live **Linux/arm64** container smoke check passes with a loopback-only port and synthetic runtime configuration: `/health` returns 200, unauthenticated private state returns 401, the absent synthetic-evidence route returns 404, and missing/forbidden configuration exits 78. The image runs as the unprivileged app user and contains no credential defaults. Observed idle memory was **12.21 MiB within a 512 MiB limit**; this is not an authenticated workload, load test, amd64-host build or Render deployment.

Initial verification found a throwing fixture encode missing error handling and a container package-manifest source-path overlap when backend test sources were omitted. Both were repaired. The container's first live HTTP smoke check then found unknown routes closed the connection because the framework error middleware had been removed; a sanitized replacement and bounded-response regression address this without restoring request/error logging. Both legacy and modern localhost integration/restart workflows pass again after that fix. Native app sources did not change in this setup task; the October 5 native evidence remains the most recent local simulator evidence.

Previous remote run [37365352414](https://github.com/joshuawyadao/Second-Look/actions/runs/37365352414) passed repository and native jobs; backend and aggregate jobs were canceled. On the subsequent `cf1d181` push, run [37507366860](https://github.com/joshuawyadao/Second-Look/actions/runs/37507366860) passed repository/native jobs and all eight Linux server boundary/request tests. Its private shared-state job failed during the first isolated Supabase CLI startup, before Auth/Postgres/HTTP integration; CI Verify therefore failed. The private CLI log was not exported, so the startup cause is not established. Neither run is full green CI evidence. Diagnose that startup failure before claiming a merge-ready branch; do not publish raw private logs or treat a rerun as a repair.

## Milestone 2 local evidence — October 5, 2026

Environment: Xcode 27.0 (27A266a), Swift 6.4, iPhone 18 Pro on the installed iOS 27 simulator (`ADD1A583-C6C6-4937-A00D-B1112054D521`), Docker 29.6.1, pinned Supabase CLI 2.119.0 and Vapor 4.122.2. These are synthetic accounts and invented checklist content. Auth, Postgres, PostgREST and the Swift HTTP server are actual running localhost services; synthetic photo metadata has no image bytes.

- `./scripts/verify-repository.sh`: **12 tooling tests pass**, including loopback binding enforcement, unrelated-project rejection and bounded private request forwarding.
- `SECONDLOOK_SIMULATOR_ID=ADD1A583-C6C6-4937-A00D-B1112054D521 SECONDLOOK_DERIVED_DATA=/private/tmp/secondlook-m2-native ./scripts/verify-native.sh`: **passes** all 29 core tests, **10 ordinary native UI cases**, Debug test build/run, Release build and Release binary exclusion. The two connected cases intentionally skip without their private fixture; their evidence is recorded separately below.
- `swift test` with temporary compiler caches and scratch path: **29 core tests pass**. The ten M2 regressions cover typed commands, actor/version rules, snapshots, closure, account scope, delayed responses/errors and wire dates.
- `swift test --package-path Backend --scratch-path /private/tmp/secondlook-backend-build -j 8 --filter ServiceBoundaryTests`: **5 pass**. Auth must be provider-verified, actor fields are rejected, configuration fails closed, normal composition excludes synthetic evidence, and an identical retry can find a receipt committed between its reads.
- The same boundary filter with `-c release` and a separate scratch path: **5 pass**. Release rejects the synthetic-evidence configuration; the production route is absent.
- `SECONDLOOK_BACKEND_SCRATCH=/private/tmp/secondlook-backend-build ./scripts/verify-shared-state.sh`: **passes** SQL privilege/expiry/rotation/receipt checks, actual Auth/HTTP integration, and a second authenticated read after command-server restart. The primary integration case passes before restart; the separately gated durability case passes afterward. A skip in the other phase is not counted as evidence.

The real localhost path verifies two distinct authenticated clients; an authenticated third account; malformed and correctly signed expired tokens; refresh; pre-join discovery without access to an explicit space; targeted invitation rotation, replay and competing joins; forged actor rejection; denied direct table/RPC access; performer self-approval denial; exact submission versions and replacement; fixed run roles and template snapshot isolation; terminal closure; concurrent distinct writes; concurrent identical commands; actor/body-bound receipts returning the current snapshot; and persisted restart state. Rejected operations leave the aggregate unchanged.

Native connected acceptance is run reproducibly using:

```sh
SECONDLOOK_BACKEND_SCRATCH=/private/tmp/secondlook-backend-build \
SECONDLOOK_DERIVED_DATA=/private/tmp/secondlook-m2-native \
./scripts/verify-shared-state.sh --native
```

The complete command above **passed** after the final foreground guard changes: backend integration and restart, **one paired UI case**, and **one fresh-pairing UI case**. The runner privately generates the accounts, runs the backend/restart checks, then keeps its owned server alive for the paired and fresh-pairing UI scenarios. The paired case checks an accepted native routine write, background/foreground membership revalidation, process-relaunch session verification/refetch, the other account seeing that write, immediate sign-out isolation, and server rejection of the third account. The fresh case resets only the named synthetic aggregate and checks native owner creation, invitation entry by the unjoined peer, and owner reopening the joined space. Each fixture mode runs one acceptance case and deliberately skips the other.

Earlier local runs exposed an SQL timestamp identifier collision, pre-join discovery incorrectly signing the invited peer out, a receipt lookup/commit race, and missing Keychain entitlement in an unsigned simulator app. Those defects were repaired without relaxing denial or version assertions. Actual connected UI tests use simulator-only ad hoc signing and the Debug Keychain entitlement; no Apple enrollment, physical-device signing or distribution was performed. A new routine visibility assertion also exposed SwiftUI list virtualization; authenticated database reads confirmed the write, and the test now scrolls before asserting the exact server title. The ordinary local-mode test then exposed inherited public connection settings from authenticated UI tests. Debug ordinary and shared UI tests now use separate preference namespaces, and reset clears only that test mode’s public configuration; real sign-in storage errors still surface.

Independent review caught a queued refresh starting after inactivity. Inactivity now synchronously disarms foreground eligibility and advances the generation; async entry/publication requires an active app and the current generation, and queued UI actions capture the generation at the tap. Protected connected state/navigation is discarded until access is revalidated; unsaved connected editor input is not durable across that transition. Core delayed-session tests and the native foreground scenario cover their respective boundaries. No deterministic paused-auth UI timing test or physical-device lifecycle timing proof is claimed.

The hosted Supabase project's schema and permission inspection are now recorded above. Actual participant accounts, Swift HTTPS operation, hosted app acceptance and two physical devices remain **unverified**. M2 remains in progress under the roadmap's hosted gate. Real photos, media cleanup, push/scheduling, durable offline intent and distribution are later work. Local passing checks do not close those gates.

## Milestone 1 validation history — October 2–3, 2026

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

All three new privacy UI tests initially passed locally: the opaque window prevents root/editor/Local settings controls from being hit, restoration makes them usable again, and entered routine text remains. The test hooks require both Debug test flags and are absent in Release. The separate Release simulator build and expanded binary boundary command above passed, checking the local identity and absence of demo/role-picker/privacy-test markers.

Manual Device Hub inspection on the same iOS 27 simulator showed the open routine editor covered in the app-switcher snapshot. Returning to the app restored the sheet and its entered synthetic name. The simulator used a hardware keyboard; software-keyboard/prediction-strip pixels were not checked. This single snapshot observation and deterministic cover tests do not establish timing on every supported runtime or physical device.

A follow-up Codex finding added two restoration regressions, bringing the core suite to **19 passing tests** in both the explicit cache/scratch-path command above and a combined native rerun. Malformed current decisions (self/unassigned actor, stale/future version, missing decision, verdict/status mismatch, missing acceptance, and invalid request notes) fail both disk loading and repository initialization without overwriting the file. Valid waiting/requested evidence, a replacement draft, a later approved version, and its terminal text-only archive still restore; historical decisions remain attached to their original versions.

Hosted run `37150206853` on Xcode 16.4 passed all five routine/checklist/snooze UI tests but failed the three privacy tests because XCTest could not scroll to the separate small test-control window. Two local coordinate-tap attempts also missed that window. The test-only trigger now uses Darwin show/hide notifications, gated by both test flags, with observers removed at disconnect and no ordinary-launch listener. It invokes the same privacy controller as scene lifecycle notifications; every visibility, restoration, and preserved-input assertion remains. All three privacy scenarios pass on focused rerun, and a fourth regression proves the show signal is ignored when `-privacy-testing` is absent. The suite now contains **9 UI tests**; the other five also passed in the restored-core combined native run. New hosted full-suite confirmation remains a PR gate.

The focused privacy command passed three tests; the gate command passed one test (not merely a successful build):

```sh
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Debug \
  -destination 'platform=iOS Simulator,id=ADD1A583-C6C6-4937-A00D-B1112054D521' \
  -derivedDataPath /private/tmp/second-look-derived -parallel-testing-enabled NO \
  -only-testing:SecondLookUITests/PrivacyShieldUITests CODE_SIGNING_ALLOWED=NO test
# The separate new gate case:
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Debug \
  -destination 'platform=iOS Simulator,id=ADD1A583-C6C6-4937-A00D-B1112054D521' \
  -derivedDataPath /private/tmp/second-look-derived -parallel-testing-enabled NO \
  -only-testing:SecondLookUITests/PrivacyShieldUITests/testPrivacySignalRequiresBothTestFlags \
  CODE_SIGNING_ALLOWED=NO test
```

After integrating the signal hook, the Release build and expanded binary boundary check passed again. The built Release app excludes both Darwin names as well as demo/role-picker/test-launch markers.

Hosted run `37152259568` passed all 19 core tests and eight of nine UI cases. The Local settings privacy case passed its cover visibility, blocked-control, hide, and restored-control assertions, then failed a display-text lookup of the section header. The existing local-storage summary now has the stable accessibility identifier `localStorageSummary`; the test checks that same content before and after protection while retaining all privacy and dismissal assertions. The focused case passed locally:

```sh
xcodebuild -project SecondLook.xcodeproj -scheme SecondLook -configuration Debug \
  -destination 'platform=iOS Simulator,id=ADD1A583-C6C6-4937-A00D-B1112054D521' \
  -derivedDataPath /private/tmp/second-look-derived -parallel-testing-enabled NO \
  -only-testing:SecondLookUITests/PrivacyShieldUITests/testPrivacyCoverHidesLocalSettingsSheetAndRestoresIt \
  CODE_SIGNING_ALLOWED=NO test
```

After this selector correction, the complete `./scripts/verify-native.sh` command above passed in one run: **19 core tests, all 9 UI tests, the Release build, and the binary exclusion check**. `./scripts/verify-repository.sh` also passed all 9 tooling tests. Hosted confirmation is reported with the PR handoff.

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

No real camera/library permissions, media bytes, uploads, scheduler, expiry, push, or deletion jobs exist. M2 now has real authentication and pairing against a synthetic localhost provider, with server concurrency tests; this does not establish hosted operation, physical-device Photos-library behavior, backup exclusion, device storage protection, offline two-device reconciliation, or notification delivery. iOS 17 runtime and full VoiceOver-on-device acceptance remain unverified. Quiet-hours values are saved preferences only; timezone/DST scheduling is Milestone 5. The JSON loader checks its schema and selected invariants, not arbitrary hostile or hand-edited state; this is an app-owned local document, not an import format.

The repository verifier checks required files, common private filenames, escaping symlinks, local inline Markdown paths, and whitespace. It does not inspect photo contents or all possible secret patterns, and does not validate external links or Markdown anchors. Review staged content before publishing.

## CI

The first M2 push was rejected before jobs started because `runner.temp` was used at job-level `env`. It now appears only in step-level `env`, where [GitHub’s context reference](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability) permits `runner`. Both server steps still share the same scratch path. Final branch CI is reported with the handoff.

The next run reached the Ubuntu server job but failed during toolchain installation: the pinned setup action v2.3.0 has a static version list ending at Swift 6.1 and rejected `6.2.4` before any server tests ran. The workflow now pins [setup-swift v2.4.0](https://github.com/swift-actions/setup-swift/releases/tag/v2.4.0) by its commit SHA and selects `6.2.1`, which its [published version list](https://github.com/swift-actions/setup-swift/blob/7ca6abe6b3b0e8b5421b88be48feee39cbf52c6a/src/swift-versions.ts) supports. The official Ubuntu 24.04 download signature endpoint returned HTTP 200. This meets the server's Swift 6.2 minimum; remote compilation and acceptance remain subject to the corrected run's results.

`CI Verify` runs on `main`, `codex/**`, pull requests, and manual dispatch. Ubuntu runs repository checks; macOS runs the native script. A separate Ubuntu job installs Swift 6.2.1 and exercises server boundaries plus actual localhost Auth/Postgres/HTTP and restart acceptance. The final **CI Verify** job requires all three jobs to succeed. Connected native tests skip without their private fixture; the ordinary macOS job checks the local native suite and Release boundary. Checkout is pinned, permissions are read-only, and checkout credentials are not persisted. Dependabot checks GitHub Actions weekly. Branch rules require a pull request, resolved conversations, and passing CI for `main`; this assignment only pushes its feature branch.

The initial hosted run selected Xcode 16.4 and exposed a UI test harness compatibility issue: its synchronous XCTest setup override is nonisolated, unlike the local toolchain's behavior. UI launch setup now runs in an explicit main-actor helper called by each test, preserving all four scenarios and their assertions. The final remote CI outcome is reported with the branch handoff.

import XCTest

@MainActor
final class ConnectedDraftLifecycleUITests: XCTestCase {
    private struct Account: Decodable {
        let email: String
        let password: String
    }

    private struct Fixture: Decodable {
        let authURL: String
        let publishableKey: String
        let serverURL: String
        let owner: Account
        let peer: Account
        let pairingRecovery: Bool?
        let recoveryCase: String?
    }

    func testEditorDraftSurvivesVerifiedForegroundReturn() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-draft-lifecycle")
        connectAndSignIn(fixture.owner, in: app)
        ensureOwnerSpace(in: app)

        tap("armSharedDraftRevalidation", in: app)
        tap("sharedCreateRoutine", in: app)
        enter("sharedRoutineTitle", text: "Unsent synthetic draft", in: app)
        enter("sharedStepTitle-0", text: "Keep this step local", in: app)
        pauseAfterGenuineMembershipLookup(in: app)
        XCTAssertFalse(app.textFields["sharedRoutineTitle"].exists)
        XCTAssertFalse(app.buttons["sharedCreateRoutine"].exists)
        tap("resumeSharedDraftRevalidation", in: app)

        let title = app.textFields["sharedRoutineTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "Verified same-space foreground return should restore the unsent editor")
        XCTAssertEqual(title.value as? String, "Unsent synthetic draft")
        let step = app.textFields["sharedStepTitle-0"].exists
            ? app.textFields["sharedStepTitle-0"] : app.textViews["sharedStepTitle-0"]
        XCTAssertEqual(step.value as? String, "Keep this step local")
        XCTAssertTrue(app.buttons["sharedSaveRoutine"].isEnabled)
    }

    func testChecklistSettingsDraftSurvivesVerifiedForegroundReturn() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-draft-lifecycle")
        connectAndSignIn(fixture.owner, in: app)
        ensureOwnerSpace(in: app)

        tap("Create one-off checklist", in: app)
        enter("sharedRoutineTitle", text: "Settings draft source", in: app)
        enter("sharedStepTitle-0", text: "Synthetic setting step", in: app)
        tap("sharedSaveRoutine", in: app)
        XCTAssertTrue(app.navigationBars["Checklist"].waitForExistence(timeout: 20))
        tap("armSharedDraftRevalidation", in: app)
        tap("Checklist settings", in: app)
        let reminder = app.switches["Remind reviewer"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 8))
        reminder.tap()
        XCTAssertEqual(reminder.value as? String, "1")
        pauseAfterGenuineMembershipLookup(in: app)
        XCTAssertFalse(reminder.exists)
        XCTAssertFalse(app.buttons["Checklist settings"].exists)
        tap("resumeSharedDraftRevalidation", in: app)

        XCTAssertTrue(reminder.waitForExistence(timeout: 20),
                      "Verified foreground return should restore the open settings sheet")
        XCTAssertEqual(reminder.value as? String, "1",
                       "An unsaved reminder choice must remain a draft")
    }

    func testReviewerNoteDraftSurvivesVerifiedForegroundReturn() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-draft-lifecycle")
        connectAndSignIn(fixture.owner, in: app)
        ensureOwnerSpace(in: app)
        ensurePaired(fixture, in: app)
        tap("prepareSharedReviewDraftProbe", in: app)
        let ready = app.staticTexts["sharedReviewDraftProbeStatus"]
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        XCTAssertEqual(ready.label, "Review draft checks ready")

        tap("Account settings", in: app)
        tap("sharedSignOut", in: app)
        signIn(fixture.peer, in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20))
        tap("armSharedDraftRevalidation", in: app)
        app.tabBars.buttons["Review"].tap()
        let review = app.staticTexts["Synthetic review draft step"]
        XCTAssertTrue(review.waitForExistence(timeout: 20))
        review.tap()
        let note = app.textFields["What should another photo show?"].exists
            ? app.textFields["What should another photo show?"]
            : app.textViews["What should another photo show?"]
        XCTAssertTrue(note.waitForExistence(timeout: 8))
        note.tap()
        note.typeText("Please show the synthetic lock label")
        pauseAfterGenuineMembershipLookup(in: app)
        XCTAssertFalse(note.exists)
        XCTAssertFalse(app.buttons["Approve version 1"].exists)
        tap("resumeSharedDraftRevalidation", in: app)

        XCTAssertTrue(note.waitForExistence(timeout: 20),
                      "Verified foreground return should restore the review sheet")
        XCTAssertEqual(note.value as? String, "Please show the synthetic lock label")
    }

    func testAccessLossPurgesUnsentEditorDraft() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-draft-access-loss")
        connectAndSignIn(fixture.owner, in: app)
        ensureOwnerSpace(in: app)

        tap("armSharedDraftRevalidation", in: app)
        tap("sharedCreateRoutine", in: app)
        enter("sharedRoutineTitle", text: "Must clear on access loss", in: app)
        enter("sharedStepTitle-0", text: "Private unsent step", in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 30),
                      "A forbidden foreground membership result must clear the connected session")
        XCTAssertFalse(app.textFields["sharedRoutineTitle"].exists)
        XCTAssertFalse(app.staticTexts["Must clear on access loss"].exists)

        signIn(fixture.owner, in: app)
        XCTAssertTrue(app.buttons["sharedCreateRoutine"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["sharedRoutineTitle"].exists,
                       "A later valid session must not restore the old unsent draft")
    }

    private func pauseAfterGenuineMembershipLookup(in app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        app.activate()
        let pause = app.staticTexts["sharedSimulatedDraftRevalidationPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 30),
                      "A genuine foreground membership GET should finish before publication is paused")
        XCTAssertEqual(pause.label,
                       "Foreground draft revalidation paused (simulated for acceptance)")
    }

    private func ensurePaired(_ fixture: Fixture, in app: XCUIApplication) {
        if app.staticTexts["Private space connected."].exists { return }
        tap("Account settings", in: app)
        var invitation = app.staticTexts["pairingInvitation"]
        if !invitation.waitForExistence(timeout: 2) {
            tap("newPairingInvitation", in: app)
            invitation = app.staticTexts["pairingInvitation"]
        }
        XCTAssertTrue(invitation.waitForExistence(timeout: 20))
        guard invitation.exists else { return }
        let code = invitation.label
        XCTAssertEqual(code.utf8.count, 72)
        tap("sharedSignOut", in: app)
        signIn(fixture.peer, in: app)
        let field = app.textFields["invitationCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText(code)
        tap("joinPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20))
        tap("Account settings", in: app)
        tap("sharedSignOut", in: app)
        signIn(fixture.owner, in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20))
    }

    private func ensureOwnerSpace(in app: XCUIApplication) {
        if app.buttons["createPrivateSpace"].waitForExistence(timeout: 5) {
            tap("createPrivateSpace", in: app)
        }
        XCTAssertTrue(app.buttons["sharedCreateRoutine"].waitForExistence(timeout: 20))
    }

    private func loadFixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No private localhost fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == "draft-lifecycle" else {
            throw XCTSkip("Dedicated draft lifecycle fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Draft lifecycle acceptance requires localhost endpoints")
            }
        }
        return fixture
    }

    private func launch(_ fixture: Fixture, flag: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo",
                               "-shared-no-periodic-poll", flag]
        if flag == "-shared-test-draft-access-loss" {
            app.launchArguments.append("-shared-test-draft-lifecycle")
        }
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()
        return app
    }

    private func connectAndSignIn(_ account: Account, in app: XCUIApplication) {
        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)
        signIn(account, in: app)
    }

    private func signIn(_ account: Account, in app: XCUIApplication) {
        let email = app.textFields["sharedEmail"]
        let password = app.secureTextFields["sharedPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 8))
        email.tap()
        email.typeText(account.email)
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        password.typeText(account.password)
        tap("sharedSignIn", in: app)
    }

    private func enter(_ identifier: String, text: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(text)
    }

    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button: \(identifier)", file: file, line: line)
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed,
                       "Button should become enabled: \(identifier)", file: file, line: line)
        button.tap()
    }
}

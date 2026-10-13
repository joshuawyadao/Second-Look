import XCTest

@MainActor
final class SharedCreationReceiptRecoveryUITests: XCTestCase {
    private struct Account: Decodable {
        let email: String
        let password: String
    }

    private struct Fixture: Decodable {
        let authURL: String
        let publishableKey: String
        let serverURL: String
        let owner: Account
        let pairingRecovery: Bool?
        let recoveryCase: String?
    }

    func testOneOffRetryOpensOriginalCreatedChecklist() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-creation-receipt-one-off")
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        tap("Create one-off checklist", in: app)
        enter("sharedRoutineTitle", text: "Receipt recovery one-off", in: app)
        enter("sharedStepTitle-0", text: "Verify synthetic step", in: app)
        tap("sharedSaveRoutine", in: app)

        let alert = app.alerts["Shared action not completed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 25),
                      "The genuine committed creation must have a simulated lost decoded reply")
        XCTAssertTrue(alert.buttons["Retry this action"].exists)
        alert.buttons["OK"].tap()
        let save = app.buttons["sharedSaveRoutine"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertFalse(save.isEnabled,
                       "A second Start must not create another run while the original receipt is unconfirmed")
        XCUIDevice.shared.press(.home)
        app.activate()
        let draft = app.textFields["sharedRoutineTitle"]
        XCTAssertTrue(draft.waitForExistence(timeout: 30),
                      "Verified foreground return should restore the pending creation editor")
        let interactive = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: draft)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 20), .completed,
                       "The retained editor must reopen only after verified membership publication")
        XCTAssertEqual(draft.value as? String, "Receipt recovery one-off")
        XCTAssertFalse(save.isEnabled,
                       "Foreground revalidation must retain the original receipt lock")
        tap("retryCreationAction", in: app)

        XCTAssertTrue(app.navigationBars["Checklist"].waitForExistence(timeout: 20),
                      "The original editor should close and show the run recovered by its receipt")
        XCTAssertTrue(app.buttons["Verify synthetic step"].waitForExistence(timeout: 8))
        assertVerifiedOriginalReceipt(in: app)
    }

    func testConfirmedCreationSurvivesSuspendBeforeModelConsumption() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-confirmed-consumption-suspend")
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        tap("Create one-off checklist", in: app)
        enter("sharedRoutineTitle", text: "Confirmed consumption synthetic one-off", in: app)
        enter("sharedStepTitle-0", text: "Confirm exact original run", in: app)
        tap("sharedSaveRoutine", in: app)
        let pause = app.staticTexts["sharedSimulatedConfirmedCreationPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 25),
                      "The genuine server and coordinator must confirm before model consumption pauses")
        XCTAssertEqual(pause.label,
                       "Confirmed creation consumption paused (simulated for acceptance)")

        XCUIDevice.shared.press(.home)
        app.activate()
        let draft = app.textFields["sharedRoutineTitle"]
        XCTAssertTrue(draft.waitForExistence(timeout: 30))
        let interactive = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: draft)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 20), .completed,
                       "The original editor must reopen only after genuine membership verification")
        XCTAssertEqual(draft.value as? String, "Confirmed consumption synthetic one-off")
        let save = app.buttons["sharedSaveRoutine"]
        XCTAssertFalse(save.isEnabled,
                       "A confirmed but unconsumed creation must keep the original Start locked")
        tap("retryCreationAction", in: app)

        XCTAssertTrue(app.navigationBars["Checklist"].waitForExistence(timeout: 20),
                      "Explicit original-action retry should complete the originating flow")
        XCTAssertTrue(app.buttons["Confirm exact original run"].waitForExistence(timeout: 8))
        assertVerifiedOriginalReceipt(in: app, replyLossExpected: false)
    }

    func testSaveAsRoutineRetryUpdatesCompletion() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-creation-receipt-save-as-routine")
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        // A normal server-created standard one-off supplies the source run. Only save-as loses a reply.
        tap("Create one-off checklist", in: app)
        enter("sharedRoutineTitle", text: "Receipt recovery source", in: app)
        enter("sharedStepTitle-0", text: "Inspect synthetic step", in: app)
        tap("sharedSaveRoutine", in: app)
        XCTAssertTrue(app.navigationBars["Checklist"].waitForExistence(timeout: 20))

        tap("Save structure as a routine", in: app)
        let alert = app.alerts["Shared action not completed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 25),
                      "The server must commit save-as before the Debug adapter discards its reply")
        XCTAssertTrue(alert.buttons["Retry this action"].exists)
        alert.buttons["OK"].tap()
        let saveAs = app.buttons["Save structure as a routine"]
        XCTAssertTrue(saveAs.waitForExistence(timeout: 8))
        XCTAssertFalse(saveAs.isEnabled,
                       "A second save-as must not create another routine while the original is unconfirmed")
        tap("retryUnconfirmedAction", in: app)
        tap("Save checklist as routine", in: app)

        XCTAssertTrue(app.buttons["Saved as a routine"].waitForExistence(timeout: 20),
                      "The original checklist view should reflect the recovered save-as receipt")
        assertVerifiedOriginalReceipt(in: app)
    }

    func testSimulatedCommandScopeLossPurgesOtherPendingActions() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = launch(fixture, flag: "-shared-test-scope-loss-purge")
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        // First genuine creation commits; only its decoded reply is discarded.
        tap("Create one-off checklist", in: app)
        enter("sharedRoutineTitle", text: "Scope purge original synthetic run", in: app)
        enter("sharedStepTitle-0", text: "Check synthetic keys", in: app)
        tap("sharedSaveRoutine", in: app)
        let lostReply = app.alerts["Shared action not completed"]
        XCTAssertTrue(lostReply.waitForExistence(timeout: 25))
        XCTAssertTrue(lostReply.buttons["Retry this action"].exists)
        lostReply.buttons["OK"].tap()
        tap("Cancel", in: app)
        tap("Refresh", in: app)
        let retry = app.buttons["retryUnconfirmedAction"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20),
                      "A genuine shared refresh must retain the first original retry")
        let refreshFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshFinished], timeout: 20), .completed,
                       "The original retry must remain after the genuine refresh finishes")

        // The second command also reaches the genuine localhost server. The Debug
        // adapter injects a labeled scope-loss response after decoding its commit.
        tap("sharedCreateRoutine", in: app)
        enter("sharedRoutineTitle", text: "Scope purge second synthetic routine", in: app)
        enter("sharedStepTitle-0", text: "Check synthetic door", in: app)
        tap("sharedSaveRoutine", in: app)
        let marker = app.staticTexts["sharedSimulatedCommandScopeLoss"]
        XCTAssertTrue(marker.waitForExistence(timeout: 25))
        XCTAssertEqual(marker.label, "Command scope loss after commit (simulated for acceptance)")

        XCTAssertFalse(app.buttons["retryUnconfirmedAction"].exists,
                       "A scope-loss purge must remove every earlier retry")
        XCTAssertFalse(app.textFields["sharedRoutineTitle"].exists,
                       "The protected editor and its creation callback must be discarded")
        let create = app.buttons["createPrivateSpace"]
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertFalse(create.isEnabled, "A command error alone cannot prove the account has no space")
        XCTAssertFalse(app.buttons["joinPrivateSpace"].isEnabled)
        tap("Account settings", in: app)
        XCTAssertTrue(app.staticTexts["Signed in"].waitForExistence(timeout: 8),
                      "Scope loss keeps the verified Auth account installed")
        tap("Done", in: app)

        tap("sharedCheckPairing", in: app)
        XCTAssertTrue(app.buttons["sharedCreateRoutine"].waitForExistence(timeout: 20),
                      "A real membership lookup restores the existing private space")
        XCTAssertFalse(app.buttons["retryUnconfirmedAction"].exists,
                       "Revalidation must not resurrect purged retry IDs or callbacks")
        XCTAssertFalse(app.textFields["sharedRoutineTitle"].exists)
    }

    private func assertVerifiedOriginalReceipt(in app: XCUIApplication,
                                               replyLossExpected: Bool = true) {
        if replyLossExpected {
            let marker = app.staticTexts["sharedSimulatedCreationReplyLoss"]
            XCTAssertTrue(marker.waitForExistence(timeout: 8))
            XCTAssertEqual(marker.label, "Creation reply loss (simulated for acceptance)")
        }
        let result = app.staticTexts["sharedCreationReceiptResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "A genuine receipt retry must verify the original created ID and one server object")
        XCTAssertEqual(result.label, "Creation receipt checks passed")
    }

    private func loadFixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No private localhost fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == "creation" else {
            throw XCTSkip("Dedicated creation receipt fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Creation receipt acceptance requires synthetic localhost endpoints")
            }
        }
        return fixture
    }

    private func launch(_ fixture: Fixture, flag: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo",
                               "-shared-no-periodic-poll", flag]
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()
        return app
    }

    private func connectOwnerAndCreateSpace(_ owner: Account, in app: XCUIApplication) {
        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)
        let email = app.textFields["sharedEmail"]
        let password = app.secureTextFields["sharedPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 8))
        email.tap()
        email.typeText(owner.email)
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        password.typeText(owner.password)
        tap("sharedSignIn", in: app)
        // A fixture can already have a space. For a fresh account, wait for the
        // genuine membership lookup to enable Create before sending the command.
        let routines = app.buttons["sharedCreateRoutine"]
        let create = app.buttons["createPrivateSpace"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !routines.exists && !(create.exists && create.isEnabled) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !routines.exists {
            XCTAssertTrue(create.exists && create.isEnabled,
                          "Membership lookup must enable Create before setup can proceed")
            create.tap()
        }
        let connected = routines.waitForExistence(timeout: 20)
        if !connected && app.alerts["Change not saved"].exists {
            XCTFail("Creating the fixture space reported a shared service error")
        }
        XCTAssertTrue(connected, "A genuine fixture space must be available before the receipt probe")
    }

    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button: \(identifier)", file: file, line: line)
        button.tap()
    }

    private func enter(_ identifier: String, text: String, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Missing field: \(identifier)", file: file, line: line)
        field.tap()
        field.typeText(text)
    }
}

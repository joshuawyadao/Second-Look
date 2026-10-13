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
        tap("retryCreationAction", in: app)

        XCTAssertTrue(app.navigationBars["Checklist"].waitForExistence(timeout: 20),
                      "The original editor should close and show the run recovered by its receipt")
        XCTAssertTrue(app.buttons["Verify synthetic step"].waitForExistence(timeout: 8))
        assertVerifiedOriginalReceipt(in: app)
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

    private func assertVerifiedOriginalReceipt(in app: XCUIApplication) {
        let marker = app.staticTexts["sharedSimulatedCreationReplyLoss"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "Creation reply loss (simulated for acceptance)")
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
        // The class may run both cases against one local fixture; the second sign-in reuses its space.
        if app.buttons["createPrivateSpace"].waitForExistence(timeout: 5) {
            tap("createPrivateSpace", in: app)
        }
        XCTAssertTrue(app.buttons["sharedCreateRoutine"].waitForExistence(timeout: 20))
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

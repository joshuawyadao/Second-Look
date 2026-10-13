import XCTest

@MainActor
final class SharedMutationRecoveryUITests: XCTestCase {
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

    func testBusyRefreshDisablesMutationUntilRefreshCompletes() throws {
        let fixture = try loadFixture(for: "busy")
        let app = launch(fixture, scenario: "-shared-test-delayed-refresh")
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        let title = "Busy refresh synthetic routine"
        let step = "Check synthetic step"
        tap("sharedCreateRoutine", in: app)
        enter("sharedRoutineTitle", text: title, in: app)
        enter("sharedStepTitle-0", text: step, in: app)
        let save = app.buttons["sharedSaveRoutine"]
        waitUntilEnabled(save, context: "A complete editor should allow saving before refresh")

        tap("testDelaySharedRefreshInEditor", in: app)
        assertSimulatedDelay(in: app, inEditor: true)
        XCTAssertFalse(save.isEnabled, "The editor must block saving until genuine refresh completes")
        tap("testResumeSharedRefreshInEditor", in: app)
        waitUntilEnabled(save, context: "Save after genuine refresh")
        tap("sharedSaveRoutine", in: app)
        XCTAssertTrue(revealRoutine(title, in: app), "The server must accept the saved routine")

        let start = app.buttons["sharedStartRoutine-\(title)"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        tap("testDelaySharedRefresh", in: app)
        assertSimulatedDelay(in: app, inEditor: false)
        XCTAssertFalse(start.isEnabled, "Starting a run must wait for genuine refresh")
        tap("testResumeSharedRefresh", in: app)
        waitUntilEnabled(start, context: "Start after genuine refresh")
        tap("sharedStartRoutine-\(title)", in: app)
        XCTAssertTrue(app.navigationBars["Checklist"].waitForExistence(timeout: 20),
                      "An accepted start must open the server-created run")
        XCTAssertTrue(app.buttons[step].waitForExistence(timeout: 8))
    }

    func testRejectedOneOffPreservesEditorDraft() throws {
        let fixture = try loadFixture(for: "draft")
        let app = launch(fixture, scenario: nil)
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        let title = "Rejected synthetic one-off"
        let step = "Show synthetic evidence"
        tap("Create one-off checklist", in: app)
        enter("sharedRoutineTitle", text: title, in: app)
        enter("sharedStepTitle-0", text: step, in: app)
        let highPriority = app.switches["High priority · photo and review"]
        XCTAssertTrue(highPriority.waitForExistence(timeout: 8))
        func visibleBottom() -> CGFloat {
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists
                ? min(app.frame.maxY - 100, keyboard.frame.minY - 16)
                : app.frame.maxY - 100
        }
        for _ in 0..<8 {
            let frame = highPriority.frame
            if frame.width > 0 && frame.height > 0 &&
                frame.minY > app.frame.minY + 80 && frame.maxY < visibleBottom() { break }
            app.swipeUp()
        }
        XCTAssertLessThan(highPriority.frame.maxY, visibleBottom())
        XCTAssertTrue(highPriority.isHittable)
        // SwiftUI exposes the row as a switch; target its trailing control.
        highPriority.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: highPriority
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        XCTAssertEqual(highPriority.value as? String, "1")
        tap("sharedSaveRoutine", in: app)

        let rejection = app.alerts["Shared action not completed"]
        XCTAssertTrue(rejection.waitForExistence(timeout: 20),
                      "The real one-member service must reject a run requiring a joined reviewer")
        rejection.buttons["OK"].tap()
        let titleField = app.textFields["sharedRoutineTitle"]
        let stepField = app.textFields["sharedStepTitle-0"].exists
            ? app.textFields["sharedStepTitle-0"] : app.textViews["sharedStepTitle-0"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 8), "Rejection must keep the editor open")
        XCTAssertEqual(titleField.value as? String, title)
        XCTAssertEqual(stepField.value as? String, step)
        XCTAssertEqual(highPriority.value as? String, "1",
                       "The high-priority draft choice must survive the rejected command")

        tap("Cancel", in: app)
        XCTAssertFalse(app.staticTexts[title].exists,
                       "A rejected one-off must not create an accepted run")
    }

    func testRefreshAccountMismatchClearsProtectedState() throws {
        let fixture = try loadFixture(for: "identity")
        let app = launch(fixture, scenario: "-shared-test-refresh-account-mismatch")
        connectOwnerAndCreateSpace(fixture.owner, in: app)

        let title = "Identity mismatch synthetic routine"
        tap("sharedCreateRoutine", in: app)
        enter("sharedRoutineTitle", text: title, in: app)
        enter("sharedStepTitle-0", text: "Check synthetic step", in: app)
        tap("sharedSaveRoutine", in: app)
        XCTAssertTrue(revealRoutine(title, in: app), "The owner must first receive protected content")

        tap("Account settings", in: app)
        tap("testSharedRefreshMismatch", in: app)
        let alert = app.alerts["Shared action not completed"]
        if alert.waitForExistence(timeout: 8) { alert.buttons["OK"].tap() }
        if app.buttons["Done"].exists { tap("Done", in: app) }
        assertSignedOutWithoutRoutine(title, in: app)
        let marker = app.staticTexts["sharedSimulatedRefreshIdentityMismatch"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "Refresh account mismatch (simulated for acceptance)")

        app.terminate()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-shared-no-periodic-poll",
                               "-shared-test-refresh-account-mismatch"]
        app.launch()
        assertSignedOutWithoutRoutine(title, in: app)
    }

    private func loadFixture(for scenario: String) throws -> Fixture {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No connected shared-state fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == scenario else {
            throw XCTSkip("Dedicated mutation recovery fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Mutation recovery acceptance requires synthetic localhost endpoints")
            }
        }
        return fixture
    }

    private func launch(_ fixture: Fixture, scenario: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo",
                               "-shared-no-periodic-poll"] + (scenario.map { [$0] } ?? [])
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
        XCTAssertTrue(app.staticTexts["PRIVATE SHARED SPACE"].waitForExistence(timeout: 8))
        let email = app.textFields["sharedEmail"]
        let password = app.secureTextFields["sharedPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 8))
        email.tap()
        email.typeText(owner.email)
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        password.typeText(owner.password)
        tap("sharedSignIn", in: app)
        XCTAssertTrue(app.buttons["createPrivateSpace"].waitForExistence(timeout: 20))
        tap("createPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 20))
    }

    private func assertSimulatedDelay(in app: XCUIApplication, inEditor: Bool) {
        let identifier = inEditor ? "sharedSimulatedRefreshDelayInEditor" : "sharedSimulatedRefreshDelay"
        let marker = app.staticTexts[identifier]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "Shared refresh delay (simulated for acceptance)")
    }

    private func assertSignedOutWithoutRoutine(_ title: String, in app: XCUIApplication) {
        let email = app.textFields["sharedEmail"]
        let password = app.secureTextFields["sharedPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        XCTAssertTrue(password.exists)
        XCTAssertTrue(app.buttons["sharedSignIn"].exists)
        XCTAssertFalse(app.buttons["sharedSignIn"].isEnabled)
        XCTAssertTrue(["", "Email"].contains(email.value as? String ?? ""),
                      "The sign-in email field must be blank")
        XCTAssertTrue(["", "Password"].contains(password.value as? String ?? ""),
                      "The sign-in password field must be blank")
        XCTAssertFalse(app.staticTexts["sharedRoutine-\(title)"].exists)
        XCTAssertFalse(app.buttons["sharedCreateRoutine"].exists)
    }

    private func waitUntilEnabled(_ button: XCUIElement, context: String) {
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: button
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed, context)
    }

    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        let exists = button.waitForExistence(timeout: 8)
        XCTAssertTrue(exists, "Missing button: \(identifier)", file: file, line: line)
        guard exists else { return }
        waitUntilEnabled(button, context: "Button should become enabled: \(identifier)")
        for _ in 0..<8 where !button.isHittable {
            let viewport = app.windows.firstMatch.frame
            let visibleBottom = app.keyboards.firstMatch.exists
                ? min(viewport.maxY, app.keyboards.firstMatch.frame.minY) : viewport.maxY
            if button.frame.maxY >= visibleBottom - 8 {
                app.swipeUp()
            } else if button.frame.minY <= viewport.minY + 8 {
                app.swipeDown()
            } else {
                // A mounted control within the viewport may belong to a covered root view.
                break
            }
        }
        XCTAssertTrue(button.isHittable, "Button must be visible and tappable: \(identifier)",
                      file: file, line: line)
        guard button.isHittable else { return }
        button.tap()
    }

    private func enter(_ identifier: String, text: String, in app: XCUIApplication) {
        let textField = app.textFields[identifier].firstMatch
        let textView = app.textViews[identifier].firstMatch
        let field = textField.exists ? textField : textView
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Missing field: \(identifier)")
        field.tap()
        field.typeText(text)
    }

    private func revealRoutine(_ title: String, in app: XCUIApplication) -> Bool {
        let row = app.staticTexts["sharedRoutine-\(title)"]
        if row.waitForExistence(timeout: 3) { return true }
        let collection = app.collectionViews.firstMatch
        let table = app.tables.firstMatch
        func scroll(up: Bool) {
            if collection.exists {
                if up { collection.swipeUp() } else { collection.swipeDown() }
            } else if table.exists {
                if up { table.swipeUp() } else { table.swipeDown() }
            } else {
                if up { app.swipeUp() } else { app.swipeDown() }
            }
        }
        for _ in 0..<6 { scroll(up: false) }
        if row.exists { return true }
        for _ in 0..<12 {
            scroll(up: true)
            if row.waitForExistence(timeout: 2) { return true }
        }
        return false
    }
}

import XCTest

@MainActor
final class SharedInvitationAccessLossUITests: XCTestCase {
    private struct Account: Decodable {
        let email: String
        let password: String
    }

    private struct Fixture: Decodable {
        let authURL: String
        let publishableKey: String
        let serverURL: String
        let owner: Account
        let invitationAccessLoss: Bool?
    }

    /// Uses a fresh, synthetic localhost space. The test changes only the in-memory bearer;
    /// the real local Auth service must reject the subsequent invitation request.
    func testInvitationActionClearsProtectedStateAfterAccessLoss() throws {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No connected shared-state fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.invitationAccessLoss == true else {
            throw XCTSkip("Invitation access-loss fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Automated fixture acceptance requires synthetic localhost endpoints")
            }
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo",
                               "-shared-no-periodic-poll", "-shared-test-access-loss"]
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()

        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)
        let email = app.textFields["sharedEmail"]
        let password = app.secureTextFields["sharedPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 8))
        email.tap()
        email.typeText(fixture.owner.email)
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        password.typeText(fixture.owner.password)
        tap("sharedSignIn", in: app)

        XCTAssertTrue(app.buttons["createPrivateSpace"].waitForExistence(timeout: 20),
                      "Owner should reach the empty synthetic space")
        tap("createPrivateSpace", in: app)
        let waiting = app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 20)
        let category = safeContext(in: app)
        XCTAssertTrue(waiting, "Owner should hold a one-member private snapshot; " + category)
        guard waiting else { return }

        tap("Account settings", in: app)
        let invalidate = app.buttons["testSharedInvalidateAccess"]
        for _ in 0..<6 where !invalidate.isHittable { app.swipeUp() }
        XCTAssertTrue(invalidate.waitForExistence(timeout: 8))
        guard invalidate.exists else { return }
        XCTAssertEqual(invalidate.label, "Invalidate access token for test")
        invalidate.tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Test access token invalidated"),
            object: invalidate)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        let renew = app.buttons["newPairingInvitation"]
        for _ in 0..<6 where !renew.isHittable { app.swipeDown() }
        XCTAssertTrue(renew.exists,
                      "The invitation action should still be available before the rejected request")
        renew.tap()

        let alert = app.alerts["Shared action not completed"]
        if alert.waitForExistence(timeout: 8) { alert.buttons["OK"].tap() }
        let done = app.buttons["Done"]
        if done.exists { done.tap() }

        XCTAssertTrue(email.waitForExistence(timeout: 20),
                      "Rejected invitation must clear the signed-in account")
        XCTAssertTrue(app.buttons["sharedSignIn"].exists)
        XCTAssertFalse(app.staticTexts["Waiting for your invited reviewer."].exists)
        XCTAssertFalse(app.buttons["createPrivateSpace"].exists)
        XCTAssertFalse(app.buttons["newPairingInvitation"].exists)
        XCTAssertFalse(app.staticTexts["pairingInvitation"].exists)
        XCTAssertFalse(app.buttons["sharedCreateRoutine"].exists)
        XCTAssertFalse(app.staticTexts["Private space connected."].exists)
    }

    private func safeContext(in app: XCUIApplication) -> String {
        let alert = app.alerts["Shared action not completed"]
        let messages = [
            ("Sign in again to continue.", "unauthenticated"),
            ("This account does not have access to that private space.", "forbidden"),
            ("The service returned an unexpected response. No local change was saved.", "invalid_response"),
            ("The service is unavailable. Try again when connected.", "service_unavailable"),
            ("Connection failed. Check the service and try again.", "connection_failed"),
            ("The account changed. Reopen the current space.", "session_changed")
        ]
        for (message, category) in messages where alert.staticTexts[message].exists { return category }
        return alert.exists ? "other_shared_alert" :
            app.textFields["sharedEmail"].exists ? "signed_out" : "other_state"
    }

    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button: \(identifier)", file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed,
                       "Button should become enabled: \(identifier)", file: file, line: line)
        button.tap()
    }
}

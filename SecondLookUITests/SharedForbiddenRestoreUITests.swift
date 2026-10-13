import XCTest

@MainActor
final class SharedForbiddenRestoreUITests: XCTestCase {
    private struct Account: Decodable { let email: String; let password: String }
    private struct Fixture: Decodable {
        let authURL: String; let publishableKey: String; let serverURL: String
        let owner: Account; let pairingRecovery: Bool?; let recoveryCase: String?
    }

    func testForbiddenRestoreClearsSavedCredentialsBeforeRelaunch() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No private localhost fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == "forbidden" else {
            throw XCTSkip("Dedicated forbidden-restoration fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Restoration acceptance requires synthetic localhost endpoints")
            }
        }
        let app = XCUIApplication()
        let flags = ["-ui-testing", "-shared-testing", "-shared-no-periodic-poll"]
        app.launchArguments = flags + ["-reset-demo"]
        app.launchEnvironment = ["SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL]
        app.launch()
        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)
        let email = app.textFields["sharedEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 8))
        email.tap(); email.typeText(fixture.owner.email)
        let password = app.secureTextFields["sharedPassword"]
        password.tap(); password.typeText(fixture.owner.password)
        tap("sharedSignIn", in: app)
        tap("createPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 20))

        app.terminate()
        app.launchArguments = flags + ["-shared-test-forbidden-restore"]
        app.launch()
        let alert = app.alerts["Shared action not completed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        alert.buttons["OK"].tap()
        let marker = app.staticTexts["sharedSimulatedForbiddenRestore"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "Saved-session rejection (simulated for acceptance)")
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["sharedCreateRoutine"].exists)
        let status = app.staticTexts["sharedForbiddenRestoreCredentialStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "No saved credentials",
                       "Forbidden restoration must use checked deletion before another launch")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 20))
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "No saved credentials")
        XCTAssertFalse(marker.exists, "Relaunch must not retry the rejected saved credential")
        XCTAssertFalse(app.buttons["sharedCreateRoutine"].exists)
    }

    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button: \(identifier)", file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
        button.tap()
    }
}

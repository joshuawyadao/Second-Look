import XCTest

@MainActor
final class SharedInvitationReceiptRecoveryUITests: XCTestCase {
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

    func testRenewalPreservesOriginalCommandReceipt() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo",
                               "-shared-no-periodic-poll", "-shared-test-invitation-receipts"]
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
        tap("createPrivateSpace", in: app)

        let alert = app.alerts["Shared action not completed"]
        if alert.waitForExistence(timeout: 20) { alert.buttons["OK"].tap() }
        let marker = app.staticTexts["sharedSimulatedCommandReplyLoss"]
        XCTAssertTrue(marker.waitForExistence(timeout: 30),
                      "The committed reply must be discarded only by the Debug localhost adapter")
        XCTAssertEqual(marker.label, "Command reply loss (simulated for acceptance)")

        let result = app.staticTexts["sharedInvitationReceiptResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 40),
                      "The app must finish genuine refresh and revision-conditional renewal")
        guard result.exists else { return }
        XCTAssertEqual(result.label, "Invitation receipt checks ready for retry",
                       "Same-space renewal must retain the original pending command and retry control")

        let retry = app.buttons["retryUnconfirmedAction"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8),
                      "The original command must remain available through the user retry menu")
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
        tap("Start checklist", in: app)
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Invitation receipt checks passed"),
            object: result
        )
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 40), .completed,
                       "Explicit retry must recover the original created ID and one server run")
    }

    private func loadFixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No private localhost fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == "receipt" else {
            throw XCTSkip("Dedicated invitation receipt fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Invitation receipt acceptance requires synthetic localhost endpoints")
            }
        }
        return fixture
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

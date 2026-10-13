import XCTest

@MainActor
final class ConnectedCleanupStatusUITests: XCTestCase {
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

    func testConnectedArchivesShowDistinctSyntheticCleanupStates() throws {
        continueAfterFailure = false
        let fixture = try loadFixture()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo",
                               "-shared-no-periodic-poll", "-shared-test-cleanup-status"]
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()

        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)
        signIn(fixture.owner, in: app)
        tap("createPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 20))
        tap("Account settings", in: app)
        let invitation = app.staticTexts["pairingInvitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 20))
        guard invitation.exists else { return }
        let code = invitation.label
        XCTAssertEqual(code.utf8.count, 72, "The test must use the actual opaque invitation")
        tap("sharedSignOut", in: app)

        signIn(fixture.peer, in: app)
        let codeField = app.textFields["invitationCode"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 20))
        codeField.tap()
        codeField.typeText(code)
        tap("joinPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20))
        tap("Account settings", in: app)
        tap("sharedSignOut", in: app)

        signIn(fixture.owner, in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20))
        tap("runSharedCleanupProbe", in: app)
        let result = app.staticTexts["sharedCleanupProbeStatus"]
        XCTAssertTrue(result.waitForExistence(timeout: 45),
                      "Genuine local commands should close both invented runs")
        XCTAssertEqual(result.label, "Cleanup archive checks ready")

        app.tabBars.buttons["History"].tap()
        assertArchive("Cleanup status standard synthetic", status: "No evidence cleanup needed", in: app)
        let back = app.navigationBars["History record"].buttons["History"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        back.tap()
        assertArchive("Cleanup status evidence synthetic", status: "Cleanup pending (simulated)", in: app)
    }

    private func assertArchive(_ title: String, status: String, in app: XCUIApplication) {
        let link = app.staticTexts[title]
        XCTAssertTrue(link.waitForExistence(timeout: 12), "Missing synthetic archive: \(title)")
        link.tap()
        let cleanup = app.staticTexts["sharedArchiveCleanupStatus"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 8))
        XCTAssertEqual(cleanup.label, status)
        let explanation = app.staticTexts["sharedArchiveCleanupExplanation"]
        XCTAssertTrue(explanation.exists)
        XCTAssertEqual(explanation.label,
                       "This status describes synthetic test metadata only. No real photo is stored or deleted; connected cleanup jobs are not available yet.")
        let media = app.staticTexts["sharedArchiveMediaExplanation"]
        XCTAssertTrue(media.exists)
        XCTAssertEqual(media.label, "History contains no image, thumbnail, or live photo link.")
    }

    private func loadFixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No private localhost fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == "cleanup" else {
            throw XCTSkip("Dedicated cleanup acceptance fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Synthetic cleanup acceptance requires localhost endpoints")
            }
        }
        return fixture
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

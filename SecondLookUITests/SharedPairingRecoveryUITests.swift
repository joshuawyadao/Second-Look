import XCTest

@MainActor
final class SharedPairingRecoveryUITests: XCTestCase {
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

    func testRenewalReplyLossInvalidatesOldInvitation() throws {
        let fixture = try loadFixture(for: "invitation")
        let app = launch(fixture, arguments: ["-reset-demo", "-shared-test-renewal-reply-loss"])
        connectAndSignIn(fixture.owner, in: app)
        createPrivateSpace(in: app)
        tap("Account settings", in: app)
        let invitation = app.staticTexts["pairingInvitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 20))
        guard invitation.exists else { return }
        let oldCode = invitation.label
        XCTAssertEqual(oldCode.utf8.count, 72, "Expected a single opaque synthetic invitation")

        tap("newPairingInvitation", in: app)
        dismissExpectedReplyLoss(in: app, withinSettings: true)
        XCTAssertFalse(invitation.exists)

        tap("newPairingInvitation", in: app)
        XCTAssertTrue(invitation.waitForExistence(timeout: 20),
                      "A fresh renewal must recover after the ambiguous first reply")
        guard invitation.exists else { return }
        XCTAssertEqual(invitation.label.utf8.count, 72)
        XCTAssertTrue(invitation.label != oldCode,
                      "The recovered invitation must not reuse the invalidated token")
    }

    func testJoinReplyLossKeepsPairingDisabledUntilMembershipCheck() throws {
        let fixture = try loadFixture(for: "join")
        let app = launch(fixture, arguments: ["-reset-demo", "-shared-test-join-reply-loss"])
        connectAndSignIn(fixture.owner, in: app)
        createPrivateSpace(in: app)
        tap("Account settings", in: app)
        let invitation = app.staticTexts["pairingInvitation"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 20))
        guard invitation.exists else { return }
        let code = invitation.label
        XCTAssertEqual(code.utf8.count, 72)
        tap("sharedSignOut", in: app)
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 8))

        signIn(fixture.peer, in: app)
        let codeField = app.textFields["invitationCode"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 20))
        guard codeField.exists else { return }
        codeField.tap()
        codeField.typeText(code)
        tap("joinPrivateSpace", in: app)
        dismissExpectedReplyLoss(in: app)

        let create = app.buttons["createPrivateSpace"]
        let join = app.buttons["joinPrivateSpace"]
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertTrue(join.exists)
        XCTAssertFalse(create.isEnabled, "A lost committed join reply cannot authorize another space")
        XCTAssertFalse(join.isEnabled, "A lost committed join reply cannot authorize a second join")
        XCTAssertFalse(app.staticTexts["Private space connected."].exists)

        tap("sharedCheckPairing", in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "The manual membership check must discover the committed two-member space")
        XCTAssertFalse(create.exists)
        XCTAssertFalse(join.exists)
    }

    func testRacingRestoreAttemptsOneCandidate() throws {
        let fixture = try loadFixture(for: "restore")
        let app = launch(fixture, arguments: ["-reset-demo"])
        connectAndSignIn(fixture.owner, in: app)
        createPrivateSpace(in: app)
        XCTAssertTrue(app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 20),
                      "Owner should hold the one-member synthetic space before relaunch")

        app.terminate()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-shared-no-periodic-poll",
                               "-shared-test-restore-race"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 30),
                      "Relaunch must refresh Auth and restore the actual one-member snapshot")
        let count = app.staticTexts["sharedRestoreCandidateCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 8),
                      "The Debug race hook must expose the number of admitted restore candidates")
        XCTAssertEqual(count.label, "1", "Concurrent restore entry points must admit one candidate")
    }

    private func loadFixture(for scenario: String) throws -> Fixture {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No connected shared-state fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.pairingRecovery == true, fixture.recoveryCase == scenario else {
            throw XCTSkip("Dedicated pairing recovery fixture was not supplied")
        }
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Pairing recovery acceptance requires synthetic localhost endpoints")
            }
        }
        return fixture
    }

    private func launch(_ fixture: Fixture, arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-shared-no-periodic-poll"] + arguments
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
        XCTAssertTrue(app.staticTexts["PRIVATE SHARED SPACE"].waitForExistence(timeout: 8))
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

    private func createPrivateSpace(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["createPrivateSpace"].waitForExistence(timeout: 20),
                      "Synthetic owner should reach empty-space pairing")
        tap("createPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Waiting for your invited reviewer."].waitForExistence(timeout: 20),
                      "Space creation must commit before the recovery scenario")
    }

    private func dismissExpectedReplyLoss(in app: XCUIApplication, withinSettings: Bool = false) {
        let alert = app.alerts["Shared action not completed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20),
                      "The simulated lost reply must be surfaced to the user")
        guard alert.exists else { return }
        alert.buttons["OK"].tap()
        if withinSettings {
            // Presenting the root alert may already dismiss the settings sheet.
            // Inspect the invitation only after deliberately reopening the sheet.
            if app.buttons["Done"].waitForExistence(timeout: 1) { tap("Done", in: app) }
        }
        let marker = app.staticTexts["sharedSimulatedPairingReplyLoss"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8),
                      "The Debug hook must label the failure as simulated")
        XCTAssertEqual(marker.label, "Pairing reply loss (simulated for acceptance)")
        if withinSettings { tap("Account settings", in: app) }
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

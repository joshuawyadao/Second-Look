import XCTest

@MainActor
final class SharedCommandAcceptanceUITests: XCTestCase {
    /// Operator opt-in only: reuse an already signed-in hosted simulator without a reset
    /// or a credential fixture. Every command creates invented acceptance records.
    func testHostedExistingSessionSharedCommandsAndForeground() throws {
        guard ProcessInfo.processInfo.environment["SECONDLOOK_RUN_HOSTED_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Existing hosted-session acceptance was not explicitly requested")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-shared-command-checks", "-shared-no-periodic-poll"]
        app.launch()
        let connected = app.staticTexts["Private space connected."].waitForExistence(timeout: 90)
        XCTAssertTrue(connected, "Hosted session must revalidate; " + safeContext(in: app))
        guard connected else { return }
        let result = app.staticTexts["sharedCommandAcceptanceResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 180), "Hosted command checks must finish; " + safeContext(in: app))
        guard result.exists else { return }
        XCTAssertEqual(result.label, "Shared command checks passed")

        // Restore normal polling and prove a new process and foreground transition still
        // revalidate the same installed account. No test reset or password entry is used.
        app.terminate()
        app.launchArguments = ["-ui-testing", "-shared-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 30),
                      "Hosted relaunch must restore verified membership; " + safeContext(in: app))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "Hosted foreground return must revalidate; " + safeContext(in: app))
    }

    /// A Debug-only service lookup failure must not be mistaken for an empty private space.
    /// The installed hosted session supplies real Auth identity and the recovery lookup is real.
    func testHostedMembershipFailureKeepsPairingDisabled() throws {
        guard ProcessInfo.processInfo.environment["SECONDLOOK_RUN_HOSTED_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Existing hosted-session acceptance was not explicitly requested")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-shared-no-periodic-poll",
                               "-shared-test-membership-failure"]
        app.launch()

        let alert = app.alerts["Shared action not completed"]
        XCTAssertTrue(alert.waitForExistence(timeout: 90),
                      "Simulated service failure should be reported after real account verification")
        guard alert.exists else { return }
        alert.buttons["OK"].tap()

        let marker = app.staticTexts["sharedSimulatedMembershipFailure"]
        XCTAssertTrue(marker.waitForExistence(timeout: 8))
        XCTAssertEqual(marker.label, "Membership lookup failure (simulated for acceptance)")
        let create = app.buttons["createPrivateSpace"]
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        XCTAssertFalse(create.isEnabled, "Lookup failure must not authorize space creation")
        XCTAssertFalse(app.staticTexts["Private space connected."].exists)
        XCTAssertFalse(app.buttons["sharedCreateRoutine"].exists,
                       "Previously paired data must not publish during lookup failure")

        let invitation = app.textFields["invitationCode"]
        let join = app.buttons["joinPrivateSpace"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 8))
        XCTAssertTrue(join.exists)
        invitation.tap()
        invitation.typeText("synthetic-invalid-invitation-for-membership-test")
        XCTAssertFalse(join.isEnabled, "A typed invented invitation must not bypass lookup failure")

        let check = app.buttons["sharedCheckPairing"]
        for _ in 0..<6 where !check.isHittable { app.swipeUp() }
        XCTAssertTrue(check.waitForExistence(timeout: 8))
        check.tap()
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "Manual lookup should restore verified hosted membership; " + safeContext(in: app))
        XCTAssertFalse(marker.exists, "The simulated failure marker must clear after real lookup")
        XCTAssertFalse(create.exists)
        XCTAssertFalse(join.exists)
    }

    private struct Account: Decodable {
        let email: String
        let password: String
    }

    private struct Fixture: Decodable {
        let authURL: String
        let publishableKey: String
        let serverURL: String
        let owner: Account
        let freshPairing: Bool?
    }

    /// This is intentionally gated by the private localhost fixture produced by the local
    /// integration workflow. Only public endpoint configuration enters the app environment.
    func testPairedOwnerSharedCommandAcceptance() throws {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No connected shared-state fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        for endpoint in [fixture.authURL, fixture.serverURL] {
            guard let url = URL(string: endpoint), url.scheme == "http",
                  ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                throw XCTSkip("Automated fixture acceptance requires synthetic localhost endpoints")
            }
        }
        if fixture.freshPairing == true {
            throw XCTSkip("Command acceptance requires the already paired synthetic space")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo", "-shared-command-checks", "-shared-no-periodic-poll"]
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()

        app.buttons["Local settings"].tap()
        app.buttons["connectPrivateSpace"].tap()
        XCTAssertTrue(app.staticTexts["PRIVATE SHARED SPACE"].waitForExistence(timeout: 8))

        let email = app.textFields["sharedEmail"]
        let password = app.secureTextFields["sharedPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 8))
        email.tap()
        email.typeText(fixture.owner.email)
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        password.typeText(fixture.owner.password)
        app.buttons["sharedSignIn"].tap()

        let connected = app.staticTexts["Private space connected."].waitForExistence(timeout: 20)
        XCTAssertTrue(connected, "Command checks require a paired authenticated session; " + safeContext(in: app))
        guard connected else { return }

        let result = app.staticTexts["sharedCommandAcceptanceResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 120),
                      "The Debug shared command acceptance runner did not complete; " + safeContext(in: app))
        guard result.exists else { return }
        XCTAssertEqual(result.label, "Shared command checks passed",
                       "The Debug shared command acceptance runner reported a failed fixed step")
    }

    private func safeContext(in app: XCUIApplication) -> String {
        let status = app.staticTexts["sharedConnectionStatus"].firstMatch
        let category: String
        switch status.exists ? status.label : "" {
        case "Private space connected.": category = "connected"
        case "Checking private-space access…": category = "checking_access"
        case "Could not authenticate this account.": category = "authentication_failed"
        case "Could not check private-space membership. Try again when connected.": category = "membership_failed"
        case "Could not synchronize. Retrying when connected.": category = "synchronization_failed"
        case "Waiting for your invited reviewer.": category = "peer_missing"
        default: category = "other_or_unavailable"
        }
        return "app_state=\(app.state.rawValue), status=\(category), shared_alert=\(app.alerts["Shared action not completed"].exists)"
    }
}

import XCTest

@MainActor
final class SharedCommandAcceptanceUITests: XCTestCase {
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

import XCTest

@MainActor
final class ConnectedSharedStateUITests: XCTestCase {
    private struct Account: Decodable {
        let email: String
        let password: String
    }
    private struct Fixture: Decodable {
        let authURL: String
        let publishableKey: String
        let serverURL: String
        let syntheticRoutineTitle: String?
        let owner: Account
        let peer: Account
        let outsider: Account?
        let freshPairing: Bool?
    }

    /// Requires a private temporary fixture and a running local auth/service stack. The app
    /// receives public endpoint configuration only; synthetic credentials are typed by XCTest.
    func testAuthenticatedOwnerPeerAndOutsiderIsolation() throws {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No connected shared-state fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        if fixture.freshPairing == true { throw XCTSkip("Fresh pairing uses its dedicated acceptance test") }
        let routineTitle = try XCTUnwrap(fixture.syntheticRoutineTitle)
        let outsider = try XCTUnwrap(fixture.outsider)
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo"]
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()

        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["PRIVATE SHARED SPACE"].waitForExistence(timeout: 8))

        signIn(fixture.owner, in: app)
        let routine = app.staticTexts["sharedRoutine-\(routineTitle)"]
        if !revealRoutine(routineTitle, in: app) {
            failWithSafeAlert("Owner did not receive the seeded synthetic shared routine", in: app)
            return
        }
        let createdTitle = "Shared synthetic check \(UUID().uuidString.prefix(8))"
        tap("sharedCreateRoutine", in: app)
        enter("sharedRoutineTitle", text: createdTitle, in: app)
        enter("sharedStepTitle-0", text: "Check synthetic step", in: app)
        tap("sharedSaveRoutine", in: app)
        let createdRoutine = app.staticTexts["sharedRoutine-\(createdTitle)"]
        XCTAssertTrue(revealRoutine(createdTitle, in: app),
                      "Owner's accepted routine command should appear from the server snapshot")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "Foreground return must revalidate the signed-in account and membership")
        XCTAssertTrue(revealRoutine(routineTitle, in: app))
        XCTAssertTrue(revealRoutine(createdTitle, in: app),
                      "Foreground return must restore the latest accepted shared snapshot")
        // Relaunch without the Debug reset flag: the test-scoped public configuration and
        // Keychain session must be revalidated before shared state is fetched again.
        app.terminate()
        app.launchArguments = ["-ui-testing", "-shared-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "Relaunch must restore the account through provider and membership checks")
        XCTAssertTrue(revealRoutine(routineTitle, in: app),
                      "Relaunch must refetch the seeded synthetic routine")
        XCTAssertTrue(revealRoutine(createdTitle, in: app),
                      "Relaunch must refetch the owner's accepted routine")
        signOut(in: app)
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 8))
        XCTAssertFalse(routine.exists, "Sign-out must clear previous account content immediately")
        XCTAssertFalse(createdRoutine.exists)

        signIn(fixture.peer, in: app)
        XCTAssertTrue(revealRoutine(routineTitle, in: app), "Peer did not receive the same shared routine")
        XCTAssertTrue(revealRoutine(createdTitle, in: app),
                      "Peer did not receive the owner's newly saved routine")
        signOut(in: app)
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 8))
        XCTAssertFalse(routine.exists)

        signIn(outsider, in: app)
        XCTAssertTrue(app.alerts["Shared action not completed"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["This account does not have access to that private space."].exists)
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 20),
                      "The private service must reject the third account")
        XCTAssertFalse(routine.exists, "Third account must not see existing shared content")
        XCTAssertFalse(createdRoutine.exists)
    }

    func testFreshOwnerInvitationPeerJoinAndOwnerReopen() throws {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_SHARED_UI_FIXTURE"] else {
            throw XCTSkip("No connected shared-state fixture was supplied")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.freshPairing == true else { throw XCTSkip("Fresh pairing fixture was not supplied") }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-shared-testing", "-reset-demo"]
        app.launchEnvironment = [
            "SECONDLOOK_TEST_AUTH_URL": fixture.authURL,
            "SECONDLOOK_TEST_PUBLISHABLE_KEY": fixture.publishableKey,
            "SECONDLOOK_TEST_SERVER_URL": fixture.serverURL
        ]
        app.launch()
        tap("Local settings", in: app)
        tap("connectPrivateSpace", in: app)

        signIn(fixture.owner, in: app)
        guard app.buttons["createPrivateSpace"].waitForExistence(timeout: 20) else {
            failWithSafeAlert("Owner could not reach new-space pairing", in: app)
            return
        }
        tap("createPrivateSpace", in: app)
        tap("Account settings", in: app)
        let invitation = app.staticTexts["pairingInvitation"]
        guard invitation.waitForExistence(timeout: 12) else {
            failWithSafeAlert("Owner did not receive a pairing invitation", in: app)
            return
        }
        let token = invitation.label
        XCTAssertEqual(token.utf8.count, 72, "Invitation should be a single opaque token")
        tap("sharedSignOut", in: app)
        XCTAssertTrue(app.buttons["sharedSignIn"].waitForExistence(timeout: 8))

        signIn(fixture.peer, in: app)
        let code = app.textFields["invitationCode"]
        guard code.waitForExistence(timeout: 20) else {
            failWithSafeAlert("Unpaired invited account did not reach Join", in: app)
            return
        }
        code.tap()
        code.typeText(token)
        tap("joinPrivateSpace", in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "Both accounts should see the joined space")

        signOut(in: app)
        signIn(fixture.owner, in: app)
        XCTAssertTrue(app.staticTexts["Private space connected."].waitForExistence(timeout: 20),
                      "Owner should reopen the same joined space after fresh auth and membership checks")
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

    private func signOut(in app: XCUIApplication) {
        tap("Account settings", in: app)
        tap("sharedSignOut", in: app)
    }

    private func tap(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<8 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button: \(identifier)", file: file, line: line)
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

    /// SwiftUI List exposes only mounted rows. Visit the bounded list, then assert the exact
    /// server routine title; a row outside the viewport is not evidence of missing state.
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

    private func failWithSafeAlert(_ context: String, in app: XCUIApplication) {
        let alert = app.alerts["Shared action not completed"]
        if alert.exists {
            let safeMessage = alert.staticTexts.allElementsBoundByIndex.map(\.label)
                .first { $0 != "Shared action not completed" } ?? "No explanation shown"
            XCTFail("\(context). App alert: \(safeMessage)")
        } else {
            XCTFail("\(context); no app alert was shown")
        }
    }
}

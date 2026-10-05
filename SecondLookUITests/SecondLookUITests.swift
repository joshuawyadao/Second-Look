import XCTest

@MainActor
final class SecondLookUITests: XCTestCase {
    var app: XCUIApplication!

    // XCTest's synchronous setup override is nonisolated in Xcode 16.
    // Keep UI setup on the main actor with the test methods on every toolchain.
    private func launchFreshDemo() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["createRoutine"].waitForExistence(timeout: 10))
    }

    func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.buttons[identifier].firstMatch
        for _ in 0..<6 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "Missing button: \(identifier)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "Unreachable button: \(identifier)", file: file, line: line)
        element.tap()
    }

    func enter(_ identifier: String, text: String) {
        let field = app.textFields[identifier].firstMatch
        let area = app.textViews[identifier].firstMatch
        let element = field.exists ? field : area
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
        element.typeText(text)
    }

    func testCreateRoutineIndependentRunsAndRelaunch() {
        launchFreshDemo()
        tap("createRoutine")
        XCTAssertFalse(app.buttons["saveRoutine"].isEnabled)
        enter("routineTitle", text: "Morning check")
        enter("stepTitle-0", text: "Pack keys")
        tap("Add step")
        enter("stepTitle-1", text: "Check desk")
        tap("saveRoutine")
        tap("startRoutine-Morning check")
        tap("check-Pack keys")
        XCTAssertEqual(app.buttons["check-Pack keys"].value as? String, "Checked")

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tap("resume-Morning check")
        XCTAssertEqual(app.buttons["check-Pack keys"].value as? String, "Checked")
        XCTAssertEqual(app.buttons["check-Check desk"].value as? String, "Not checked")
        app.navigationBars.buttons["Routines"].tap()
        tap("startRoutine-Morning check")
        tap("Start another run")
        XCTAssertEqual(app.buttons["check-Pack keys"].value as? String, "Not checked")
        tap("check-Pack keys")
        tap("check-Check desk")
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Routines"].tap()
        tap("resume-Morning check")
        XCTAssertEqual(app.buttons["check-Pack keys"].value as? String, "Checked")
        XCTAssertEqual(app.buttons["check-Check desk"].value as? String, "Not checked")
    }

    func setRole(_ name: String) {
        tap("Local settings")
        tap(name)
        tap("Done")
    }

    func testSimulatedReviewRetryAndTextHistory() {
        launchFreshDemo()
        tap("startRoutine-Packages brought inside")
        tap("check-Bring packages inside")
        tap("check-Put keys away")
        tap("Preview sample evidence")
        XCTAssertTrue(app.staticTexts["Development sample · not a real photo"].exists)
        tap("sendSample")
        tap("Simulate upload failure")
        XCTAssertTrue(app.staticTexts["Upload failed (simulated)"].exists)
        tap("Retry sending (simulated)")
        tap("Simulate delivery")
        XCTAssertTrue(app.staticTexts["Waiting for review (simulated)"].exists)
        setRole("Demo Sam")
        app.tabBars.buttons["Review"].tap()
        tap("review-Lock the front door")
        tap("approveSample")
        XCTAssertTrue(app.staticTexts["No reviews waiting"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        tap("history-Packages brought inside")
        XCTAssertTrue(app.staticTexts["Completed"].exists)
        let pending = app.staticTexts["Cleanup pending (simulated)"]
        for _ in 0..<5 where !pending.exists { app.swipeUp() }
        XCTAssertTrue(pending.exists)
        XCTAssertFalse(app.staticTexts["Synthetic lock illustration"].exists)
        tap("Simulate cleanup acknowledgment")
        XCTAssertTrue(app.staticTexts["Cleanup acknowledged (simulated)"].exists)
    }

    func testInvalidSettingsShowsRecoverableErrorAboveEditor() {
        launchFreshDemo()
        tap("createRoutine")
        enter("routineTitle", text: "Preferences check")
        enter("stepTitle-0", text: "Check bag")
        for _ in 0..<6 where !app.textFields["timeoutMinutes"].isHittable { app.swipeUp() }
        enter("timeoutMinutes", text: "0")
        tap("saveRoutine")
        XCTAssertTrue(app.alerts["Change not saved"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["saveRoutine"].exists)
        XCTAssertTrue(app.textFields["timeoutMinutes"].exists)
    }

    func testSnoozeStartsInFutureAndPersistsWithRoutine() throws {
        launchFreshDemo()
        tap("createRoutine")
        enter("routineTitle", text: "Snooze check")
        enter("stepTitle-0", text: "Pack lunch")

        let snooze = app.switches["snoozeToggle"]
        for _ in 0..<6 where !snooze.isHittable || snooze.frame.maxY > app.frame.maxY - 100 {
            app.swipeUp()
        }
        XCTAssertTrue(snooze.isHittable)
        // SwiftUI exposes the whole row as a switch; tap its trailing control.
        snooze.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(snooze.value as? String, "1")

        let deadline = app.staticTexts["snoozeDeadline"]
        for _ in 0..<6 where !deadline.exists { app.swipeUp() }
        XCTAssertTrue(deadline.waitForExistence(timeout: 5))
        let displayedDeadline = deadline.label
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let savedDate = try XCTUnwrap(formatter.date(from: displayedDeadline))
        XCTAssertGreaterThan(savedDate, Date(), "Enabling Snooze must set a future deadline")

        tap("saveRoutine")
        tap("Edit Snooze check")
        let reopenedDeadline = app.staticTexts["snoozeDeadline"]
        for _ in 0..<6 where !reopenedDeadline.exists { app.swipeUp() }
        XCTAssertTrue(reopenedDeadline.waitForExistence(timeout: 5))
        XCTAssertEqual(reopenedDeadline.label, displayedDeadline)
        XCTAssertGreaterThan(try XCTUnwrap(formatter.date(from: reopenedDeadline.label)), Date())
    }

    func testOneOffCancellationIsNotCompletion() {
        launchFreshDemo()
        tap("Create one-off checklist")
        enter("routineTitle", text: "Quick check")
        enter("stepTitle-0", text: "Close window")
        tap("saveRoutine")
        tap("Cancel checklist")
        app.sheets.buttons["Cancel checklist"].tap()
        XCTAssertTrue(app.staticTexts["Canceled"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Completed"].exists)
        tap("Start new run")
        XCTAssertEqual(app.buttons["check-Close window"].value as? String, "Not checked")
    }

    func testConnectedEntryKeepsLocalDemoSeparate() {
        launchFreshDemo()
        tap("Local settings")
        tap("connectPrivateSpace")
        XCTAssertTrue(app.staticTexts["PRIVATE SHARED SPACE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sharedSignIn"].exists)
        XCTAssertFalse(app.buttons["demoRole"].exists)
        tap("Use local lists")
        XCTAssertTrue(app.buttons["startRoutine-Packages brought inside"].waitForExistence(timeout: 5))
    }
}

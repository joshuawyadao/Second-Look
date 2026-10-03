import CoreFoundation
import XCTest

@MainActor
final class PrivacyShieldUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launchPrivacyDemo() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-privacy-testing", "-reset-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["createRoutine"].waitForExistence(timeout: 10))
    }

    private func verifyCoverAndRestore(over element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, file: file, line: line)
        postPrivacySignal("com.secondlook.ui-tests.privacy.show")
        let cover = app.staticTexts["privacyShieldVisible"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(element.isHittable, "The shield must cover the active presentation", file: file, line: line)
        postPrivacySignal("com.secondlook.ui-tests.privacy.hide")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cover)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, file: file, line: line)
        XCTAssertTrue(element.isHittable, "The previous presentation must remain usable", file: file, line: line)
    }

    private func postPrivacySignal(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil,
            nil,
            true
        )
    }

    func testPrivacySignalRequiresBothTestFlags() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["createRoutine"].waitForExistence(timeout: 10))

        postPrivacySignal("com.secondlook.ui-tests.privacy.show")
        let cover = app.staticTexts["privacyShieldVisible"]
        let unexpectedCover = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: cover
        )
        unexpectedCover.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedCover], timeout: 2), .completed)

        app.buttons["createRoutine"].tap()
        XCTAssertTrue(app.textFields["routineTitle"].waitForExistence(timeout: 5))
    }

    func testPrivacyCoverHidesRootAndRestoresIt() {
        launchPrivacyDemo()
        verifyCoverAndRestore(over: app.buttons["createRoutine"])
    }

    func testPrivacyCoverHidesRoutineEditorAndPreservesInput() {
        launchPrivacyDemo()
        app.buttons["createRoutine"].tap()
        let title = app.textFields["routineTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Prepared checklist")
        verifyCoverAndRestore(over: title)
        XCTAssertEqual(title.value as? String, "Prepared checklist")
    }

    func testPrivacyCoverHidesLocalSettingsSheetAndRestoresIt() {
        launchPrivacyDemo()
        app.buttons["Local settings"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let summary = app.staticTexts["localStorageSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        verifyCoverAndRestore(over: done)
        XCTAssertTrue(summary.exists)
        done.tap()
        XCTAssertTrue(app.buttons["createRoutine"].isHittable)
    }
}

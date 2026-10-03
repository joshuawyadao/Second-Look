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
        XCTAssertTrue(app.buttons["testShowPrivacyShield"].waitForExistence(timeout: 5))
    }

    private func verifyCoverAndRestore(over element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, file: file, line: line)
        app.buttons["testShowPrivacyShield"].tap()
        let cover = app.staticTexts["privacyShieldVisible"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(element.isHittable, "The shield must cover the active presentation", file: file, line: line)
        app.buttons["testRestoreApp"].tap()
        XCTAssertFalse(cover.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, "The previous presentation must remain usable", file: file, line: line)
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
        verifyCoverAndRestore(over: done)
        XCTAssertTrue(app.staticTexts["Local foundation"].exists)
        done.tap()
        XCTAssertTrue(app.buttons["createRoutine"].isHittable)
    }
}

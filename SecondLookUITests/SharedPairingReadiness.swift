import XCTest

/// Discovery can mount Create before it is enabled or has an activation frame.
/// Keep genuine membership eligibility separate from XCTest's layout readiness.
@MainActor
func waitForPrivateSpaceCreate(in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
    let button = app.buttons["createPrivateSpace"].firstMatch
    let eligible = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND enabled == true"), object: button)
    guard XCTWaiter.wait(for: [eligible], timeout: 20) == .completed else {
        XCTFail("Genuine membership must enable Create before activation", file: file, line: line)
        return false
    }
    let positioned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        let frame = button.frame
        return !frame.isEmpty && frame.intersects(app.frame)
    }, object: button)
    guard XCTWaiter.wait(for: [positioned], timeout: 8) == .completed else {
        XCTFail("Create must have a screen position before activation", file: file, line: line)
        return false
    }
    return true
}

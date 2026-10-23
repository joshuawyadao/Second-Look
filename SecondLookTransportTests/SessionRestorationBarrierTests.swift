import Foundation
import XCTest
import SecondLookTransport

final class SessionRestorationBarrierTests: XCTestCase {
    private enum StorageFailure: Error { case unavailable }

    func testFailedDeletionBlocksPriorCredentialsAcrossRelaunchUntilRemovalSucceeds() throws {
        try withPreferences { preferences in
            var credential: String? = "invented-old-session"
            let barrier = SessionRestorationBarrier(scope: "synthetic-backend", preferences: preferences)
            XCTAssertThrowsError(try barrier.deleteCredentials { throw StorageFailure.unavailable })

            // A newly constructed boundary represents a new app process using the same preferences.
            let relaunched = SessionRestorationBarrier(scope: "synthetic-backend", preferences: preferences)
            var reads = 0
            XCTAssertThrowsError(try relaunched.restoreCredentials(read: {
                reads += 1
                return credential
            }, delete: { throw StorageFailure.unavailable }))
            XCTAssertEqual(reads, 0, "Failed sign-out must never read or restore the old credential")
            let restored = try relaunched.restoreCredentials(read: {
                reads += 1
                return credential
            }, delete: { credential = nil })
            XCTAssertNil(restored, "Successful cleanup must leave the user signed out")
            XCTAssertEqual(reads, 0)
        }
    }

    func testOnlySuccessfulFreshCredentialPersistenceClearsSignOutBarrier() throws {
        try withPreferences { preferences in
            var credential: String? = "invented-old-session"
            let barrier = SessionRestorationBarrier(scope: "synthetic-backend", preferences: preferences)
            XCTAssertThrowsError(try barrier.deleteCredentials { throw StorageFailure.unavailable })
            XCTAssertThrowsError(try barrier.persistCredentials { throw StorageFailure.unavailable })
            XCTAssertThrowsError(try barrier.restoreCredentials(read: { credential },
                delete: { throw StorageFailure.unavailable }), "A failed write cannot re-enable restoration")

            try barrier.persistCredentials { credential = "invented-new-session" }
            let restored = try barrier.restoreCredentials(read: { credential },
                delete: { XCTFail("A verified new session should no longer be marked signed out") })
            XCTAssertEqual(restored, "invented-new-session")
        }
    }

    func testSignOutBarrierIsScopedToItsBackendAndNamespace() throws {
        try withPreferences { preferences in
            let first = SessionRestorationBarrier(scope: "first-test-namespace", preferences: preferences)
            try first.deleteCredentials {}
            let second = SessionRestorationBarrier(scope: "second-test-namespace", preferences: preferences)
            let restored = try second.restoreCredentials(read: { "invented-other-session" },
                delete: { XCTFail("Another backend's sign-out must not remove this session") })
            XCTAssertEqual(restored, "invented-other-session")
            XCTAssertNil(try first.restoreCredentials(read: { "invented-old-session" }, delete: {}))
        }
    }

    private func withPreferences(_ operation: (UserDefaults) throws -> Void) throws {
        let name = "SecondLook.SessionBarrierTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        try operation(preferences)
    }
}

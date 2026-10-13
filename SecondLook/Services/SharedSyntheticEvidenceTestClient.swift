#if SECONDLOOK_DEMO
import Foundation
import SecondLookCore

/// Debug-only localhost metadata fixture. This never uploads an image.
enum SharedSyntheticEvidenceTestClient {
    private struct Request: Encodable {
        let spaceID: UUID
        let runID: UUID
        let itemID: UUID
        let expectedSpaceRevision: Int
        let expectedRunRevision: Int
    }

    static func submit(serverURL: URL, token: String, snapshot: SharedSnapshot,
                       run: ChecklistRun, itemID: UUID, actorID: UUID) async throws -> SharedSnapshot {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains("-shared-testing"),
              serverURL.scheme == "http",
              ["localhost", "127.0.0.1", "::1"].contains(serverURL.host ?? "") else {
            throw SharedStateFailure.forbidden
        }
        try SharedEndpointValidation.validate(serverURL, allowLocalHTTP: true)
        var request = URLRequest(url: serverURL.appendingPathComponent("_testing/synthetic-evidence"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try SharedWireCodec.encode(Request(spaceID: snapshot.spaceID,
            runID: run.id, itemID: itemID, expectedSpaceRevision: snapshot.revision,
            expectedRunRevision: run.revision))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SharedStateFailure.serviceUnavailable
        }
        let updated = try SharedWireCodec.decode(SharedSnapshot.self, from: data)
        try updated.validate(for: actorID)
        guard updated.spaceID == snapshot.spaceID, updated.revision == snapshot.revision + 1 else {
            throw SharedStateFailure.invalidResponse
        }
        return updated
    }
}
#endif

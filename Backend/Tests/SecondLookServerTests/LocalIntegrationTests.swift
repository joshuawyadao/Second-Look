import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SecondLookCore
import SecondLookTransport

/// Runs only against the disposable local Auth, Postgres, and Swift server fixture.
/// It never provisions a service or uses the checked-in Debug demo identities.
@MainActor
final class LocalIntegrationTests: XCTestCase {
    private struct Account: Decodable {
        let id: UUID
        let email: String
        let password: String
    }

    private struct Fixture: Decodable {
        let providerURL: URL
        let serverURL: URL
        let publishableKey: String
        let serviceKey: String
        let owner: Account
        let peer: Account
        let outsider: Account
        let expiredToken: String
    }

    private struct SyntheticEvidence: Encodable {
        let spaceID: UUID
        let runID: UUID
        let itemID: UUID
        let expectedSpaceRevision: Int
        let expectedRunRevision: Int
    }

    private func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_LOCAL_FIXTURE"] else {
            throw XCTSkip("Local Supabase fixture is not configured")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        guard [fixture.providerURL, fixture.serverURL].allSatisfy({
            $0.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains($0.host ?? "")
        }), !fixture.publishableKey.isEmpty, !fixture.serviceKey.isEmpty,
            Set([fixture.owner.id, fixture.peer.id, fixture.outsider.id]).count == 3 else {
            throw SharedStateFailure.invalidResponse
        }
        return fixture
    }

    private func signedIn(_ account: Account, auth: SharedAuthClient) async throws -> SharedAuthSession {
        let session = try await auth.signIn(email: account.email, password: account.password)
        XCTAssertEqual(session.user.id, account.id)
        let user = try await auth.getUser(accessToken: session.access_token)
        XCTAssertEqual(user.id, account.id)
        return session
    }

    private func client(_ fixture: Fixture, token: String) -> SharedHTTPClient {
        SharedHTTPClient(serverURL: fixture.serverURL, accessToken: token, allowLocalHTTP: true)
    }

    private func command(_ value: SharedCommand, snapshot: SharedSnapshot,
                         commandID: UUID = UUID()) -> SharedCommandEnvelope {
        SharedCommandEnvelope(spaceID: snapshot.spaceID, commandID: commandID,
                              expectedSpaceRevision: snapshot.revision, command: value)
    }

    private func assertFailure<T>(_ expected: SharedStateFailure,
                                  _ operation: () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SharedStateFailure, expected, file: file, line: line)
        }
    }

    private func raw(_ url: URL, method: String = "GET", token: String? = nil,
                     apiKey: String? = nil, body: Data? = nil,
                     profile: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "apikey") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let profile { request.setValue(profile, forHTTPHeaderField: "Accept-Profile") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SharedStateFailure.invalidResponse }
        return (http.statusCode, data)
    }

    private func synthetic(_ fixture: Fixture, token: String,
                           snapshot: SharedSnapshot, runID: UUID, itemID: UUID) async throws -> SharedSnapshot {
        let run = try XCTUnwrap(snapshot.state.runs.first { $0.id == runID })
        let body = SyntheticEvidence(spaceID: snapshot.spaceID, runID: runID, itemID: itemID,
                                     expectedSpaceRevision: snapshot.revision,
                                     expectedRunRevision: run.revision)
        let url = fixture.serverURL.appendingPathComponent("_testing/synthetic-evidence")
        let (status, response) = try await raw(url, method: "POST", token: token,
                                                body: SharedWireCodec.encode(body))
        XCTAssertEqual(status, 200, "Debug synthetic evidence hook must be enabled locally")
        let updated = try SharedWireCodec.decode(SharedSnapshot.self, from: response)
        try updated.validate(for: fixture.owner.id)
        XCTAssertEqual(updated.revision, snapshot.revision + 1)
        return updated
    }

    func testPrivateSharedState() async throws {
        if ProcessInfo.processInfo.environment["SECONDLOOK_RESTART_CHECK"] == "1" {
            throw XCTSkip("Full integration runs before the server restart")
        }
        let f = try fixture()
        let auth = SharedAuthClient(authURL: f.providerURL,
                                    publishableKey: f.publishableKey, allowLocalHTTP: true)
        let ownerLogin = try await signedIn(f.owner, auth: auth)
        let peerLogin = try await signedIn(f.peer, auth: auth)
        let outsiderLogin = try await signedIn(f.outsider, auth: auth)
        let refreshedOwner = try await auth.refresh(refreshToken: ownerLogin.refresh_token)
        let refreshedUser = try await auth.getUser(accessToken: refreshedOwner.access_token)
        XCTAssertEqual(refreshedUser.id, f.owner.id)
        let owner = client(f, token: refreshedOwner.access_token)
        let peer = client(f, token: peerLogin.access_token)
        let outsider = client(f, token: outsiderLogin.access_token)

        // The allowed participant list is enforced by the Swift service after real Auth.
        await assertFailure(.forbidden) { try await outsider.createSpace() }
        await assertFailure(.forbidden) { try await outsider.currentSpace() }
        let initial = try await owner.createSpace()
        var shared = initial.snapshot
        XCTAssertEqual(shared.members, [f.owner.id])
        try shared.validate(for: f.owner.id)
        await assertFailure(.notPaired) { try await peer.currentSpace() }
        await assertFailure(.forbidden) { try await peer.fetch(spaceID: shared.spaceID) }
        await assertFailure(.forbidden) { try await outsider.fetch(spaceID: shared.spaceID) }
        await assertFailure(.forbidden) { try await outsider.joinSpace(inviteToken: initial.inviteToken) }
        await assertFailure(.invalidInvite) { try await owner.joinSpace(inviteToken: initial.inviteToken) }

        let noBearer = try await raw(f.serverURL.appendingPathComponent("v1/space"))
        XCTAssertEqual(noBearer.0, 401)
        let expired = try await raw(f.serverURL.appendingPathComponent("v1/space"),
                                    token: f.expiredToken)
        XCTAssertEqual(expired.0, 401)
        var forged = refreshedOwner.access_token
        guard let signatureStart = forged.lastIndex(of: ".").map({ forged.index(after: $0) }),
              signatureStart < forged.endIndex else { throw SharedStateFailure.invalidResponse }
        let signatureReplacement = forged[signatureStart] == "A" ? "B" : "A"
        forged.replaceSubrange(signatureStart...signatureStart, with: signatureReplacement)
        let forgedResult = try await raw(f.serverURL.appendingPathComponent("v1/space"), token: forged)
        XCTAssertEqual(forgedResult.0, 401)

        // A standard run made before pairing keeps its original fixed roles across rotation.
        let standard = Routine(title: "Before leaving", items: [
            RoutineItem(title: "Carry keys"), RoutineItem(title: "Close windows")])
        shared = try await owner.execute(command(.saveRoutine(definition: standard,
                                                              expectedDefinitionVersion: nil),
                                                 snapshot: shared)).snapshot
        let standardStart = try await owner.execute(command(.startRun(routineID: standard.id,
                                                                     expectedDefinitionVersion: 1),
                                                        snapshot: shared))
        shared = standardStart.snapshot
        let standardRunID = try XCTUnwrap(standardStart.createdID)
        XCTAssertNil(shared.state.runs.first { $0.id == standardRunID }?.reviewerID)
        let rotating = try await owner.createSpace()
        XCTAssertEqual(rotating.snapshot.spaceID, shared.spaceID)
        XCTAssertEqual(rotating.snapshot.state, shared.state)
        XCTAssertEqual(rotating.snapshot.revision, shared.revision)
        await assertFailure(.invalidInvite) { try await peer.joinSpace(inviteToken: initial.inviteToken) }

        let invitation = rotating.inviteToken
        let joins = await withTaskGroup(of: Result<SharedSnapshot, SharedStateFailure>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { return .success(try await peer.joinSpace(inviteToken: invitation)) }
                    catch { return .failure(error as? SharedStateFailure ?? .serviceUnavailable) }
                }
            }
            var output: [Result<SharedSnapshot, SharedStateFailure>] = []
            for await result in group { output.append(result) }
            return output
        }
        XCTAssertEqual(joins.filter { if case .success = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(joins.filter { if case .failure(.pairingUnavailable) = $0 { return true }; return false }.count, 1)
        shared = try await owner.currentSpace()
        XCTAssertEqual(shared.members, [f.owner.id, f.peer.id])
        let peerAfterJoin = try await peer.currentSpace()
        XCTAssertEqual(shared, peerAfterJoin)
        await assertFailure(.forbidden) { try await outsider.fetch(spaceID: shared.spaceID) }
        let outsiderEnvelope = command(.startOneOff(title: "Denied", items: [RoutineItem(title: "No")],
                                                        settings: .init()), snapshot: shared)
        await assertFailure(.forbidden) { try await outsider.execute(outsiderEnvelope) }

        let prePair = try XCTUnwrap(shared.state.runs.first { $0.id == standardRunID })
        await assertFailure(.domain(.unauthorized)) {
            try await peer.execute(command(.setStandardChecked(runID: standardRunID,
                                                               itemID: prePair.items[0].id,
                                                               checked: true,
                                                               expectedRunRevision: prePair.revision),
                                           snapshot: shared))
        }
        await assertFailure(.domain(.unauthorized)) {
            try await peer.execute(command(.cancel(runID: standardRunID,
                                                   expectedRunRevision: prePair.revision), snapshot: shared))
        }

        // Either member can edit definitions, while run snapshots stay independent.
        let high = Routine(title: "Home check", items: [
            RoutineItem(title: "Lock", priority: .high), RoutineItem(title: "Keys")])
        shared = try await peer.execute(command(.saveRoutine(definition: high,
                                                             expectedDefinitionVersion: nil),
                                                snapshot: shared)).snapshot
        let firstStart = try await owner.execute(command(.startRun(routineID: high.id,
                                                                  expectedDefinitionVersion: 1),
                                                     snapshot: shared))
        shared = firstStart.snapshot
        let highRunID = try XCTUnwrap(firstStart.createdID)
        let highRun = try XCTUnwrap(shared.state.runs.first { $0.id == highRunID })
        XCTAssertEqual(highRun.performerID, f.owner.id)
        XCTAssertEqual(highRun.reviewerID, f.peer.id)
        let secondStart = try await peer.execute(command(.startRun(routineID: high.id,
                                                                  expectedDefinitionVersion: 1),
                                                     snapshot: shared))
        shared = secondStart.snapshot
        let independentID = try XCTUnwrap(secondStart.createdID)
        XCTAssertNotEqual(independentID, highRunID)
        XCTAssertEqual(shared.state.runs.first { $0.id == independentID }?.performerID, f.peer.id)
        let independentRevision = try XCTUnwrap(shared.state.runs.first { $0.id == independentID }?.revision)
        shared = try await peer.execute(command(.cancel(runID: independentID,
                                                       expectedRunRevision: independentRevision),
                                              snapshot: shared)).snapshot
        let changed = Routine(id: high.id, title: "Changed later", items: [RoutineItem(title: "Other")],
                              definitionVersion: 999)
        shared = try await owner.execute(command(.saveRoutine(definition: changed,
                                                              expectedDefinitionVersion: 1),
                                                 snapshot: shared)).snapshot
        XCTAssertEqual(shared.state.routines.first { $0.id == high.id }?.definitionVersion, 2)
        shared = try await owner.execute(command(.deleteRoutine(routineID: high.id,
                                                                expectedDefinitionVersion: 2),
                                                 snapshot: shared)).snapshot
        XCTAssertEqual(shared.state.runs.first { $0.id == highRunID }?.title, "Home check")
        XCTAssertEqual(shared.state.runs.first { $0.id == highRunID }?.items[0].title, "Lock")

        let beforeEvidence = try XCTUnwrap(shared.state.runs.first { $0.id == highRunID })
        await assertFailure(.staleState) {
            try await owner.execute(command(.cancel(runID: highRunID,
                                                    expectedRunRevision: beforeEvidence.revision - 1),
                                            snapshot: shared))
        }
        shared = try await synthetic(f, token: refreshedOwner.access_token, snapshot: shared,
                                     runID: highRunID, itemID: beforeEvidence.items[0].id)
        let pending = try XCTUnwrap(shared.state.runs.first { $0.id == highRunID })
        let pendingVersion = try XCTUnwrap(pending.items[0].submission?.version)
        XCTAssertEqual(pending.items[0].submission?.status, .waitingForReview)
        await assertFailure(.domain(.unauthorized)) {
            try await owner.execute(command(.approve(runID: highRunID, itemID: pending.items[0].id,
                                                     expectedVersion: pendingVersion,
                                                     expectedRunRevision: pending.revision), snapshot: shared))
        }
        shared = try await peer.execute(command(.requestAnother(runID: highRunID,
                                                                itemID: pending.items[0].id,
                                                                expectedVersion: pendingVersion,
                                                                note: "Show the deadbolt",
                                                                expectedRunRevision: pending.revision),
                                                snapshot: shared)).snapshot
        shared = try await synthetic(f, token: refreshedOwner.access_token, snapshot: shared,
                                     runID: highRunID, itemID: pending.items[0].id)
        let replacement = try XCTUnwrap(shared.state.runs.first { $0.id == highRunID })
        XCTAssertEqual(replacement.items[0].submission?.version, pendingVersion + 1)
        await assertFailure(.domain(.staleVersion)) {
            try await peer.execute(command(.approve(runID: highRunID, itemID: replacement.items[0].id,
                                                    expectedVersion: pendingVersion,
                                                    expectedRunRevision: replacement.revision), snapshot: shared))
        }
        shared = try await peer.execute(command(.approve(runID: highRunID,
                                                        itemID: replacement.items[0].id,
                                                        expectedVersion: pendingVersion + 1,
                                                        expectedRunRevision: replacement.revision),
                                               snapshot: shared)).snapshot
        let approved = try XCTUnwrap(shared.state.runs.first { $0.id == highRunID })
        XCTAssertNil(approved.outcome)
        shared = try await owner.execute(command(.setStandardChecked(runID: highRunID,
                                                                      itemID: approved.items[1].id,
                                                                      checked: true,
                                                                      expectedRunRevision: approved.revision),
                                                 snapshot: shared)).snapshot
        let closed = try XCTUnwrap(shared.state.runs.first { $0.id == highRunID })
        XCTAssertEqual(closed.outcome, .completed)
        XCTAssertNil(closed.items[0].submission)
        XCTAssertEqual(shared.state.archives.filter { $0.id == highRunID }.count, 1)
        await assertFailure(.domain(.closed)) {
            try await owner.execute(command(.cancel(runID: highRunID,
                                                    expectedRunRevision: closed.revision), snapshot: shared))
        }

        // A transaction receipt survives later writes and cannot be borrowed by another actor.
        let replayID = UUID()
        let create = command(.startOneOff(title: "Receipt", items: [RoutineItem(title: "One")],
                                          settings: .init()), snapshot: shared, commandID: replayID)
        let created = try await owner.execute(create)
        shared = created.snapshot
        let originalCreatedID = try XCTUnwrap(created.createdID)
        let other = Routine(title: "Unrelated", items: [RoutineItem(title: "Step")])
        shared = try await peer.execute(command(.saveRoutine(definition: other,
                                                             expectedDefinitionVersion: nil),
                                                snapshot: shared)).snapshot
        let runsBeforeReplay = shared.state.runs.count
        let revisionBeforeReplay = shared.revision
        let replayed = try await owner.execute(create)
        XCTAssertEqual(replayed.createdID, originalCreatedID)
        XCTAssertEqual(replayed.snapshot.revision, revisionBeforeReplay)
        XCTAssertEqual(replayed.snapshot.state.runs.count, runsBeforeReplay)
        await assertFailure(.staleState) {
            try await owner.execute(command(.startOneOff(title: "Changed", items: [RoutineItem(title: "Two")],
                                                         settings: .init()), snapshot: created.snapshot,
                                            commandID: replayID))
        }
        await assertFailure(.staleState) { try await peer.execute(create) }

        // Two deliveries of the same intent race through receipt lookup. Both callers
        // must receive the original result even if one arrives after the other's commit.
        let identical = command(.startOneOff(title: "Concurrent receipt",
                                              items: [RoutineItem(title: "Single run")],
                                              settings: .init()), snapshot: shared,
                                commandID: UUID())
        let beforeIdenticalRevision = shared.revision
        let beforeIdenticalRuns = shared.state.runs.count
        let identicalResults = await withTaskGroup(of: Result<SharedCommandResult, SharedStateFailure>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { return .success(try await owner.execute(identical)) }
                    catch { return .failure(error as? SharedStateFailure ?? .serviceUnavailable) }
                }
            }
            var results: [Result<SharedCommandResult, SharedStateFailure>] = []
            for await result in group { results.append(result) }
            return results
        }
        let successes = identicalResults.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, 2)
        if successes.count == 2 {
            XCTAssertNotNil(successes[0].createdID)
            XCTAssertEqual(successes[0].createdID, successes[1].createdID)
            XCTAssertEqual(successes[0].snapshot.members, successes[1].snapshot.members)
        }
        shared = try await owner.currentSpace()
        XCTAssertEqual(shared.revision, beforeIdenticalRevision + 1)
        XCTAssertEqual(shared.state.runs.count, beforeIdenticalRuns + 1)
        if successes.count == 2 {
            XCTAssertEqual(successes[0].snapshot, shared)
            XCTAssertEqual(successes[1].snapshot, shared)
        }
        if let createdID = successes.first?.createdID {
            XCTAssertEqual(shared.state.runs.filter { $0.id == createdID }.count, 1)
        }

        // Two valid writes against one revision race; only one can commit.
        let conflictA = command(.saveRoutine(definition: Routine(title: "Race A",
                                      items: [RoutineItem(title: "A")]), expectedDefinitionVersion: nil),
                                snapshot: shared)
        let conflictB = command(.saveRoutine(definition: Routine(title: "Race B",
                                      items: [RoutineItem(title: "B")]), expectedDefinitionVersion: nil),
                                snapshot: shared)
        let race = await withTaskGroup(of: Result<SharedCommandResult, SharedStateFailure>.self) { group in
            group.addTask {
                do { return .success(try await owner.execute(conflictA)) }
                catch { return .failure(error as? SharedStateFailure ?? .serviceUnavailable) }
            }
            group.addTask {
                do { return .success(try await peer.execute(conflictB)) }
                catch { return .failure(error as? SharedStateFailure ?? .serviceUnavailable) }
            }
            var results: [Result<SharedCommandResult, SharedStateFailure>] = []
            for await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(race.filter { if case .success = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(race.filter { if case .failure(.staleState) = $0 { return true }; return false }.count, 1)
        shared = try await owner.currentSpace()
        let peerAfterRace = try await peer.currentSpace()
        XCTAssertEqual(shared, peerAfterRace)

        // Unknown actor fields are rejected at the HTTP boundary before command decoding.
        let forgedBody = try SharedWireCodec.encode(conflictA)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: forgedBody) as? [String: Any])
        object["actorID"] = f.outsider.id.uuidString
        let commandURL = f.serverURL.appendingPathComponent("v1/spaces/\(shared.spaceID.uuidString)/commands")
        let forgedCommand = try await raw(commandURL, method: "POST", token: refreshedOwner.access_token,
                                          body: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(forgedCommand.0, 400)

        // PostgREST functions and the private schema never accept client keys/tokens.
        let readRPC = f.providerURL.appendingPathComponent("rest/v1/rpc/sl_read")
        let commitRPC = f.providerURL.appendingPathComponent("rest/v1/rpc/sl_commit")
        let readBody = try JSONSerialization.data(withJSONObject: [
            "p_actor": f.owner.id.uuidString, "p_space": shared.spaceID.uuidString])
        let stateObject = try JSONSerialization.jsonObject(with: SharedWireCodec.encode(shared.state))
        let commitBody = try JSONSerialization.data(withJSONObject: [
            "p_actor": f.owner.id.uuidString, "p_space": shared.spaceID.uuidString,
            "p_expected_revision": shared.revision - 1, "p_command_id": UUID().uuidString,
            "p_digest": String(repeating: "0", count: 64), "p_state": stateObject,
            "p_created_id": NSNull()])
        for (url, body) in [(readRPC, readBody), (commitRPC, commitBody)] {
            let anonymous = try await raw(url, method: "POST", apiKey: f.publishableKey, body: body)
            XCTAssertTrue([401, 403, 404].contains(anonymous.0))
            let normal = try await raw(url, method: "POST", token: refreshedOwner.access_token,
                                       apiKey: f.publishableKey, body: body)
            XCTAssertTrue([401, 403, 404].contains(normal.0))
        }
        let privateTable = f.providerURL.appendingPathComponent("rest/v1/spaces")
        let deniedTable = try await raw(privateTable, token: refreshedOwner.access_token,
                                        apiKey: f.publishableKey, profile: "secondlook_private")
        XCTAssertTrue([401, 403, 404, 406].contains(deniedTable.0))

        if let path = ProcessInfo.processInfo.environment["SECONDLOOK_RESTART_EXPECTED"] {
            try SharedWireCodec.encode(shared).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testRestartDurability() async throws {
        guard ProcessInfo.processInfo.environment["SECONDLOOK_RESTART_CHECK"] == "1" else {
            throw XCTSkip("Restart check runs after the local server is restarted")
        }
        let f = try fixture()
        guard let path = ProcessInfo.processInfo.environment["SECONDLOOK_RESTART_EXPECTED"] else {
            throw SharedStateFailure.invalidResponse
        }
        let expected = try SharedWireCodec.decode(SharedSnapshot.self,
                                                  from: Data(contentsOf: URL(fileURLWithPath: path)))
        let auth = SharedAuthClient(authURL: f.providerURL,
                                    publishableKey: f.publishableKey, allowLocalHTTP: true)
        let ownerSession = try await signedIn(f.owner, auth: auth)
        let peerSession = try await signedIn(f.peer, auth: auth)
        let ownerSnapshot = try await client(f, token: ownerSession.access_token).currentSpace()
        let peerSnapshot = try await client(f, token: peerSession.access_token).currentSpace()
        XCTAssertEqual(ownerSnapshot, expected)
        XCTAssertEqual(peerSnapshot, expected)
        XCTAssertEqual(ownerSnapshot.state.archives.filter { $0.outcome == .completed }.count, 1)
    }
}

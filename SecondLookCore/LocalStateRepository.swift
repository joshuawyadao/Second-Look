import Foundation

public struct JSONStateStore: Sendable {
    public let url: URL
    private static let currentVersion = 1

    public init(url: URL) { self.url = url }

    public func load() throws -> SecondLookState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SecondLookState() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw SecondLookError.corruptDocument }
        guard header.schemaVersion == Self.currentVersion else {
            throw SecondLookError.unsupportedDocumentVersion(header.schemaVersion)
        }
        do {
            let state = try decoder.decode(Document.self, from: data).state
            try state.validateForLoad()
            return state
        }
        catch { throw SecondLookError.corruptDocument }
    }

    public func save(_ state: SecondLookState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: Self.currentVersion, state: state))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private struct Header: Decodable { let schemaVersion: Int }
    private struct Document: Codable {
        let schemaVersion: Int
        let state: SecondLookState
    }
}

/// A failed write leaves the published in-memory state unchanged.
@MainActor public final class LocalStateRepository {
    public private(set) var state: SecondLookState
    public let store: JSONStateStore

    public init(store: JSONStateStore) throws {
        self.store = store
        self.state = try store.load()
    }

    @discardableResult
    public func transact<Result>(_ change: (inout SecondLookState) throws -> Result) throws -> Result {
        var next = state
        let result = try change(&next)
        try store.save(next)
        state = next
        return result
    }
}

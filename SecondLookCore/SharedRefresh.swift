import Foundation

/// An opaque content validator issued with one fully validated server snapshot.
/// It is process memory only and never substitutes for authentication or membership.
public struct SharedSnapshotValidator: Codable, Equatable, Sendable {
    public let spaceID: UUID
    public let revision: Int
    public let token: String

    public init(spaceID: UUID, revision: Int, token: String) {
        self.spaceID = spaceID
        self.revision = revision
        self.token = token
    }

    public var isValid: Bool {
        revision >= 0 && token.utf8.count == 64 && token.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct SharedUnchangedReply: Codable, Equatable, Sendable {
    public let unchanged: SharedSnapshotValidator

    public init(unchanged: SharedSnapshotValidator) { self.unchanged = unchanged }
}

/// Legacy servers may return a full snapshot without a validator. Such responses
/// remain usable but cannot enable conditional polling.
public enum SharedSnapshotRefresh: Equatable, Sendable {
    case snapshot(SharedSnapshot, validator: SharedSnapshotValidator?)
    case unchanged(SharedSnapshotValidator)
}

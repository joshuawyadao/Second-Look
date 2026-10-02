import Foundation

public enum SecondLookError: Error, Equatable, Sendable {
    case notFound, invalidDefinition, unauthorized, reviewerRequired, wrongItemType
    case closed, staleVersion, invalidTransition, noteRequired, unsupportedDocumentVersion(Int)
    case corruptDocument
}

public enum ItemPriority: String, Codable, Equatable, Sendable { case standard, high }
public enum EvidenceSource: String, Codable, Equatable, Sendable { case simulatedCamera, simulatedLibrary }
public enum SubmissionStatus: String, Codable, Equatable, Sendable {
    case localDraft, sending, uploadFailed, waitingForReview, approved, needsAnotherLook
}
public enum ReviewVerdict: String, Codable, Equatable, Sendable { case approved, requestedAnother }
public enum RunOutcome: String, Codable, Equatable, Sendable { case completed, canceled }
public enum CleanupStatus: String, Codable, Equatable, Sendable { case notNeeded, pending, simulatedConfirmed }

public struct QuietHours: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

public struct ReminderPreferences: Codable, Equatable, Sendable {
    public var remindReviewer: Bool
    public var remindPerformer: Bool
    public var firstDelaySeconds: TimeInterval?
    public var repeatSeconds: TimeInterval?
    public var snoozedUntil: Date?
    public var muted: Bool
    public var quietHours: QuietHours?
    public init(remindReviewer: Bool = false, remindPerformer: Bool = false,
                firstDelaySeconds: TimeInterval? = nil, repeatSeconds: TimeInterval? = nil,
                snoozedUntil: Date? = nil, muted: Bool = false, quietHours: QuietHours? = nil) {
        self.remindReviewer = remindReviewer
        self.remindPerformer = remindPerformer
        self.firstDelaySeconds = firstDelaySeconds
        self.repeatSeconds = repeatSeconds
        self.snoozedUntil = snoozedUntil
        self.muted = muted
        self.quietHours = quietHours
    }
}

public struct RunSettings: Codable, Equatable, Sendable {
    public var reminders: ReminderPreferences
    /// Nil means Off. Scheduling and expiration are intentionally not implemented locally.
    public var unreviewedTimeoutSeconds: TimeInterval?
    public init(reminders: ReminderPreferences = .init(), unreviewedTimeoutSeconds: TimeInterval? = nil) {
        self.reminders = reminders
        self.unreviewedTimeoutSeconds = unreviewedTimeoutSeconds
    }
}

public struct RoutineItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var priority: ItemPriority
    public var photoInstructions: String
    public init(id: UUID = UUID(), title: String, priority: ItemPriority = .standard, photoInstructions: String = "") {
        self.id = id
        self.title = title
        self.priority = priority
        self.photoInstructions = photoInstructions
    }
}

public struct Routine: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var items: [RoutineItem]
    public var settings: RunSettings
    public var definitionVersion: Int
    public init(id: UUID = UUID(), title: String, items: [RoutineItem], settings: RunSettings = .init(), definitionVersion: Int = 1) {
        self.id = id
        self.title = title
        self.items = items
        self.settings = settings
        self.definitionVersion = definitionVersion
    }
}

public struct ReviewDecision: Codable, Equatable, Sendable {
    public var actorID: UUID
    public var submissionVersion: Int
    public var verdict: ReviewVerdict
    public var note: String?
    public var decidedAt: Date
}

/// fixtureID is a symbolic development token, never a path, URL, thumbnail, or image bytes.
public struct PhotoSubmission: Codable, Equatable, Sendable {
    public var version: Int
    public var fixtureID: String
    public var source: EvidenceSource
    public var status: SubmissionStatus
    public var preparedAt: Date
    public var acceptedAt: Date?
    public var decision: ReviewDecision?
}

public struct RunItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var priority: ItemPriority
    public var photoInstructions: String
    public var checkedAt: Date?
    public var submission: PhotoSubmission?
    /// Replacement preview is separate from the current evidence until explicitly sent.
    public var preview: PhotoSubmission?
    public var lastVersion: Int
    public var priorDecisions: [ReviewDecision]
    public init(definition: RoutineItem) {
        id = UUID()
        title = definition.title
        priority = definition.priority
        photoInstructions = definition.photoInstructions
        checkedAt = nil
        submission = nil
        preview = nil
        lastVersion = 0
        priorDecisions = []
    }
    public var isSatisfied: Bool {
        switch priority {
        case .standard: checkedAt != nil
        case .high: submission?.status == .approved && submission?.decision?.verdict == .approved
        }
    }
}

public struct ChecklistRun: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var routineID: UUID?
    public var routineVersion: Int?
    public var title: String
    public var items: [RunItem]
    public var settings: RunSettings
    public var performerID: UUID
    public var reviewerID: UUID?
    public var startedAt: Date
    public var outcome: RunOutcome?
    public var closedAt: Date?
    public var revision: Int
    public var cleanupStatus: CleanupStatus?
    public var isOpen: Bool { outcome == nil }
    public var isSatisfied: Bool { !items.isEmpty && items.allSatisfy(\.isSatisfied) }
}

/// Deliberately excludes fixture IDs, media references, and image data.
public struct ArchiveItem: Codable, Equatable, Sendable {
    public var title: String
    public var priority: ItemPriority
    public var checkedAt: Date?
    public var decisions: [ReviewDecision]
}
public struct TextArchive: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var routineID: UUID?
    public var performerID: UUID
    public var reviewerID: UUID?
    public var startedAt: Date
    public var closedAt: Date
    public var outcome: RunOutcome
    public var items: [ArchiveItem]
    public var cleanupStatus: CleanupStatus
}

public extension RoutineItem {
    var instructions: String {
        get { photoInstructions }
        set { photoInstructions = newValue }
    }
    init(id: UUID = UUID(), title: String, priority: ItemPriority = .standard, instructions: String) {
        self.init(id: id, title: title, priority: priority, photoInstructions: instructions)
    }
}

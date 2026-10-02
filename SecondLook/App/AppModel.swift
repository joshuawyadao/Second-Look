import Foundation
import Observation
import SecondLookCore

@MainActor @Observable
final class AppModel {
    private(set) var state = SecondLookState()
    var errorMessage: String?
    var sheetHandlesErrors = false
    var loadFailure: String?
    private var repository: LocalStateRepository?
    #if SECONDLOOK_DEMO
    var demoRole = DemoRole.performer
    #endif

    init() { load() }

    var actorID: UUID {
        #if SECONDLOOK_DEMO
        demoRole.id
        #else
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #endif
    }
    var otherPersonID: UUID? {
        #if SECONDLOOK_DEMO
        demoRole == .performer ? DemoRole.reviewer.id : DemoRole.performer.id
        #else
        nil
        #endif
    }
    var modeTitle: String {
        #if SECONDLOOK_DEMO
        "LOCAL DEMO · \(personName(actorID))"
        #else
        "LOCAL FOUNDATION"
        #endif
    }
    var modeDetail: String {
        #if SECONDLOOK_DEMO
        "Simulated people and evidence. Nothing is sent to anyone."
        #else
        "On this device only. Shared review is not connected."
        #endif
    }
    func personName(_ id: UUID) -> String {
        #if SECONDLOOK_DEMO
        return id == DemoRole.performer.id ? "Demo Alex" : (id == DemoRole.reviewer.id ? "Demo Sam" : "Unknown local participant")
        #else
        return id == actorID ? "This device" : "Unconnected participant"
        #endif
    }
    var openRuns: [ChecklistRun] { state.runs.filter(\.isOpen).sorted { $0.startedAt > $1.startedAt } }
    func run(_ id: UUID) -> ChecklistRun? { state.runs.first { $0.id == id } }
    func hasOpenRun(_ routineID: UUID) -> Bool { latestOpenRun(routineID) != nil }
    func latestOpenRun(_ routineID: UUID) -> ChecklistRun? { openRuns.first { $0.routineID == routineID } }

    func load() {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            #if SECONDLOOK_DEMO
            let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
            let directory = base.appendingPathComponent(testing ? "SecondLookUITests" : "SecondLookDemo", isDirectory: true)
            let url = directory.appendingPathComponent("state-v1.json")
            if testing && ProcessInfo.processInfo.arguments.contains("-reset-demo") && FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            #else
            let url = base.appendingPathComponent("SecondLookLocal", isDirectory: true).appendingPathComponent("state-v1.json")
            #endif
            let existed = FileManager.default.fileExists(atPath: url.path)
            let loaded = try LocalStateRepository(store: JSONStateStore(url: url))
            #if SECONDLOOK_DEMO
            if !existed { try loaded.transact { try $0.saveRoutine(DemoFixtures.packages) } }
            #else
            // Persist the empty local document on first launch; never read the demo store.
            if !existed { try loaded.transact { _ in } }
            #endif
            repository = loaded
            state = loaded.state
            loadFailure = nil
        } catch {
            repository = nil
            loadFailure = Self.message(error)
        }
    }

    @discardableResult
    func perform<T>(_ change: (inout SecondLookState) throws -> T) -> T? {
        guard let repository else {
            errorMessage = "Reopen the saved lists before making changes."
            return nil
        }
        do {
            let result = try repository.transact(change)
            state = repository.state
            return result
        } catch {
            errorMessage = Self.message(error)
            return nil
        }
    }

    @discardableResult func save(_ routine: Routine) -> Bool {
        perform { try $0.saveRoutine(routine); return true } ?? false
    }
    func deleteRoutine(_ id: UUID) { perform { try $0.deleteRoutine(id: id) } }
    func start(_ routine: Routine) -> UUID? {
        perform { try $0.startRun(routineID: routine.id, performerID: actorID, reviewerID: otherPersonID, now: Date()) }
    }
    func startOneOff(_ routine: Routine) -> UUID? {
        perform { try $0.startOneOff(title: routine.title, items: routine.items, settings: routine.settings, performerID: actorID, reviewerID: otherPersonID, now: Date()) }
    }
    func repeatRun(_ id: UUID) -> UUID? {
        perform { try $0.repeatRun(runID: id, performerID: actorID, reviewerID: otherPersonID, now: Date()) }
    }
    func check(_ run: ChecklistRun, _ item: RunItem) {
        perform { try $0.setStandardChecked(runID: run.id, itemID: item.id, checked: item.checkedAt == nil, actorID: actorID, now: Date()) }
    }
    func cancel(_ id: UUID) { perform { try $0.cancel(runID: id, actorID: actorID, now: Date()) } }
    func saveAsRoutine(_ id: UUID) -> Bool {
        perform { try $0.saveRunAsRoutine(runID: id); return true } ?? false
    }

    static func message(_ error: Error) -> String {
        guard let domain = error as? SecondLookError else {
            return "Local storage could not be updated. Your last saved progress is unchanged. Check available storage and try again."
        }
        switch domain {
        case .notFound: return "This item is no longer available. Return to the current list."
        case .invalidDefinition: return "Give the list and every step a name, and use positive timing values."
        case .unauthorized: return "Only the assigned person can perform this action."
        case .reviewerRequired: return "A distinct reviewer is required. Shared review is not connected in this build; high-priority routines can be saved as drafts."
        case .wrongItemType: return "This step requires its own completion method."
        case .closed: return "This checklist is already closed. Start a new run to repeat it."
        case .staleVersion: return "The evidence changed. Reopen the current submission before reviewing."
        case .invalidTransition: return "The state changed. Check the current status and try again."
        case .noteRequired: return "Add a short note explaining what another photo should show."
        case .unsupportedDocumentVersion: return "This data was saved by a different app version. Use a compatible version to open it."
        case .corruptDocument: return "The saved data is incomplete or unreadable. It has not been replaced."
        }
    }
}

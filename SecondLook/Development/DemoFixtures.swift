#if SECONDLOOK_DEMO
import Foundation
import SecondLookCore

enum DemoRole: String, CaseIterable {
    case performer, reviewer
    var id: UUID {
        UUID(uuidString: self == .performer ? "00000000-0000-0000-0000-0000000000A1" : "00000000-0000-0000-0000-0000000000B2")!
    }
}

enum DemoFixtures {
    static var packages: Routine {
        Routine(title: "Packages brought inside", items: [
            RoutineItem(title: "Bring packages inside"),
            RoutineItem(title: "Lock the front door", priority: .high, photoInstructions: "Show the inside deadbolt in its locked position."),
            RoutineItem(title: "Put keys away")
        ])
    }
}

@MainActor
extension AppModel {
    func prepareSample(runID: UUID, itemID: UUID, source: EvidenceSource) -> Bool {
        perform {
            try $0.prepareDraft(runID: runID, itemID: itemID, actorID: actorID, fixtureID: "sample-lock-illustration", source: source, now: Date())
            return true
        } ?? false
    }
    func discardSample(runID: UUID, itemID: UUID) {
        perform { try $0.discardDraft(runID: runID, itemID: itemID, actorID: actorID, now: Date()) }
    }
    func sendSample(runID: UUID, itemID: UUID) -> Bool {
        perform { try $0.beginSend(runID: runID, itemID: itemID, actorID: actorID, now: Date()) } != nil
    }
    func resolveSample(runID: UUID, itemID: UUID, version: Int, fail: Bool) {
        perform {
            if fail { try $0.failSend(runID: runID, itemID: itemID, actorID: actorID, expectedVersion: version, now: Date()) }
            else { try $0.acceptSend(runID: runID, itemID: itemID, actorID: actorID, expectedVersion: version, now: Date()) }
        }
    }
    func retrySample(runID: UUID, itemID: UUID, version: Int) {
        perform { try $0.retrySend(runID: runID, itemID: itemID, actorID: actorID, expectedVersion: version, now: Date()) }
    }
    func withdrawSample(runID: UUID, itemID: UUID) {
        perform { try $0.withdraw(runID: runID, itemID: itemID, actorID: actorID, now: Date()) }
    }
    func reviewSample(runID: UUID, itemID: UUID, version: Int, note: String?) -> Bool {
        perform {
            if let note { try $0.requestAnother(runID: runID, itemID: itemID, actorID: actorID, expectedVersion: version, note: note, now: Date()) }
            else { try $0.approve(runID: runID, itemID: itemID, actorID: actorID, expectedVersion: version, now: Date()) }
            return true
        } ?? false
    }
    func confirmSampleCleanup(_ id: UUID) { perform { try $0.confirmSimulatedCleanup(runID: id) } }
}
#endif

import SwiftUI
import SecondLookCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if model.state.archives.isEmpty {
                ContentUnavailableView("History starts here", systemImage: "clock", description: Text("Completed and canceled checklists will appear as text-only records."))
            } else {
                List(model.state.archives.sorted { $0.closedAt > $1.closedAt }) { archive in
                    NavigationLink { ArchiveDetailView(archiveID: archive.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(archive.title).font(.headline)
                            Text(archive.outcome == .completed ? "Completed" : "Canceled")
                                .font(.subheadline)
                            Text(archive.closedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text(archive.cleanupStatus.title).font(.caption)
                        }
                    }
                    .accessibilityIdentifier("history-\(archive.title)")
                }
            }
        }
        .navigationTitle("History")
    }
}

struct ArchiveDetailView: View {
    @Environment(AppModel.self) private var model
    let archiveID: UUID
    @State private var newRun: UUID?
    @State private var savedRoutine = false

    var body: some View {
        Group {
            if let archive = model.state.archives.first(where: { $0.id == archiveID }) {
                List {
                    Section {
                        Text(archive.title).font(.title2.bold())
                        Label(archive.outcome == .completed ? "Completed" : "Canceled", systemImage: archive.outcome == .completed ? "checkmark.circle" : "xmark.circle")
                            .font(.headline).accessibilityIdentifier("archiveOutcome")
                        LabeledContent("Performer", value: model.personName(archive.performerID))
                        if let reviewer = archive.reviewerID { LabeledContent("Reviewer", value: model.personName(reviewer)) }
                        Text("Started \(archive.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("Closed \(archive.closedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Section("Text-only record") {
                        ForEach(Array(archive.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline)
                                Text(item.priority == .high ? "High priority" : "Standard").font(.caption)
                                if let checked = item.checkedAt {
                                    Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                } else if item.priority == .standard {
                                    Text("Not checked").font(.caption)
                                }
                                ForEach(Array(item.decisions.enumerated()), id: \.offset) { _, decision in
                                    Text("\(model.personName(decision.actorID)): \(decision.verdict == .approved ? "Approved" : "Requested another photo") · version \(decision.submissionVersion)")
                                        .font(.subheadline)
                                    if let note = decision.note { Text(note).font(.caption) }
                                    Text(decision.decidedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("Cleanup") {
                        Text(archive.cleanupStatus.title)
                        Text("History contains no images, thumbnails, or live photo links.").font(.footnote)
                        #if SECONDLOOK_DEMO
                        Text("Only synthetic evidence was used. No real media deletion is claimed.").font(.footnote)
                        if archive.cleanupStatus == .pending {
                            Button("Simulate cleanup acknowledgment") { model.confirmSampleCleanup(archiveID) }
                        }
                        #endif
                    }
                    Section {
                        Button("Start new run") { newRun = model.repeatRun(archiveID) }
                        Button(savedRoutine ? "Saved as a routine" : "Save structure as a routine") {
                            savedRoutine = model.saveAsRoutine(archiveID)
                        }.disabled(savedRoutine)
                    } footer: { Text("A new run copies the steps and settings only. This record never reopens.") }
                }
                .navigationTitle("History record")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $newRun) { ChecklistView(runID: $0) }
            } else { ContentUnavailableView("Record unavailable", systemImage: "clock") }
        }
    }
}

extension CleanupStatus {
    var title: String {
        switch self {
        case .notNeeded: "No evidence cleanup needed"
        case .pending: "Cleanup pending (simulated)"
        case .simulatedConfirmed: "Cleanup acknowledged (simulated)"
        }
    }
}

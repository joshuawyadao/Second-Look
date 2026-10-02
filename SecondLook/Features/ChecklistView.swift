import SwiftUI
import SecondLookCore

struct ChecklistView: View {
    @Environment(AppModel.self) private var model
    let runID: UUID
    @State private var cancelConfirmation = false
    @State private var showingPreferences = false
    @State private var savedRoutine = false
    #if SECONDLOOK_DEMO
    @State private var previewItem: RunItem?
    @State private var withdrawing: RunItem?
    #endif

    var body: some View {
        Group {
            if let run = model.run(runID) {
                if !run.isOpen {
                    ArchiveDetailView(archiveID: runID)
                } else {
                    List {
                        Section {
                            Text(run.title).font(.title2.bold())
                            LabeledContent("Performer", value: model.personName(run.performerID))
                            if let reviewer = run.reviewerID {
                                LabeledContent("Reviewer", value: model.personName(reviewer))
                            }
                            Text("\(run.items.filter(\.isSatisfied).count) of \(run.items.count) steps ready")
                                .accessibilityIdentifier("progressSummary")
                            Text("Started \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(run.items) { item in
                            Section {
                                if item.priority == .standard {
                                    Button { model.check(run, item) } label: {
                                        Label(item.title, systemImage: item.checkedAt == nil ? "circle" : "checkmark.circle.fill")
                                            .foregroundStyle(.primary)
                                    }
                                    .disabled(model.actorID != run.performerID)
                                    .accessibilityValue(item.checkedAt == nil ? "Not checked" : "Checked")
                                    .accessibilityHint("Only the performer can change this step")
                                    .accessibilityIdentifier("check-\(item.title)")
                                } else {
                                    highPriorityItem(item, run: run)
                                }
                            }
                        }
                        Section {
                            Button("Checklist settings", systemImage: "slider.horizontal.3") { showingPreferences = true }
                                .disabled(model.actorID != run.performerID)
                            if run.routineID == nil {
                                Button(savedRoutine ? "Saved as a routine" : "Save structure as a routine") {
                                    savedRoutine = model.saveAsRoutine(runID)
                                }.disabled(savedRoutine)
                            }
                            Button("Cancel checklist", role: .destructive) { cancelConfirmation = true }
                                .disabled(model.actorID != run.performerID)
                        } footer: {
                            Text("Requirements and roles stay fixed for this run. To correct them, cancel and start a revised checklist. Standard checkmarks can be undone until the checklist closes.")
                        }
                    }
                    .navigationTitle("Checklist")
                    .navigationBarTitleDisplayMode(.inline)
                    .sheet(isPresented: $showingPreferences) { RunPreferencesView(runID: runID, settings: run.settings).sheetErrorAlert() }
                    .confirmationDialog("Cancel this checklist?", isPresented: $cancelConfirmation, titleVisibility: .visible) {
                        Button("Cancel checklist", role: .destructive) { model.cancel(runID) }
                    } message: { Text("It will be archived as Canceled, not Completed. It cannot reopen. A new run starts fresh.") }
                    #if SECONDLOOK_DEMO
                    .sheet(item: $previewItem) { item in SamplePreviewView(runID: runID, itemID: item.id, title: item.title).sheetErrorAlert() }
                    .confirmationDialog("Withdraw this evidence?", isPresented: Binding(
                        get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }
                    ), titleVisibility: .visible) {
                        if let item = withdrawing {
                            Button("Withdraw evidence", role: .destructive) { model.withdrawSample(runID: runID, itemID: item.id) }
                        }
                    } message: { Text("Its approval will no longer count. Another submission and review will be needed.") }
                    #endif
                }
            } else { ContentUnavailableView("Checklist unavailable", systemImage: "checklist") }
        }
    }

    @ViewBuilder private func highPriorityItem(_ item: RunItem, run: ChecklistRun) -> some View {
        Label(item.title, systemImage: "exclamationmark.circle").font(.headline)
        Text("High priority · photo and another person's approval").font(.caption).foregroundStyle(.secondary)
        if !item.photoInstructions.isEmpty { Text(item.photoInstructions) }
        Label(item.submission?.status.title ?? "Photo needed", systemImage: item.isSatisfied ? "checkmark.seal" : "photo")
            .font(.subheadline.bold())
        if let note = item.submission?.decision?.note {
            Text("Reviewer note: \(note)")
        }
        #if SECONDLOOK_DEMO
        if let submitted = item.submission {
            Text("Version \(submitted.version) · simulated evidence")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.actorID == run.performerID {
            if item.preview != nil {
                Text("Local draft saved · not sent").font(.caption.bold())
                Button("Resume sample preview") { previewItem = item }
                Button("Discard local draft", role: .destructive) { model.discardSample(runID: runID, itemID: item.id) }
            } else {
                Button(item.submission == nil ? "Preview sample evidence" : "Preview replacement sample", systemImage: "photo.badge.plus") { previewItem = item }
            }
            if let submission = item.submission {
                switch submission.status {
                case .sending:
                    Text("This send is paused in the local simulator. Choose a response below; no network request exists.").font(.caption)
                    Button("Simulate delivery") { model.resolveSample(runID: runID, itemID: item.id, version: submission.version, fail: false) }
                    Button("Simulate upload failure") { model.resolveSample(runID: runID, itemID: item.id, version: submission.version, fail: true) }
                case .uploadFailed:
                    Button("Retry sending (simulated)") { model.retrySample(runID: runID, itemID: item.id, version: submission.version) }
                default: EmptyView()
                }
                Button("Withdraw evidence", role: .destructive) { withdrawing = item }
            }
        }
        if item.submission?.status == .waitingForReview {
            Text("Use Local settings to preview the assigned reviewer, then open Review. Looking at evidence does not approve it.").font(.caption)
        }
        #else
        Text("Camera, library import, and connected review arrive in later milestones.").font(.footnote)
        #endif
    }
}

extension SubmissionStatus {
    var title: String {
        switch self {
        case .localDraft: "Local draft · not sent"
        case .sending: "Sending (simulated)"
        case .uploadFailed: "Upload failed (simulated)"
        case .waitingForReview: "Waiting for review (simulated)"
        case .approved: "Approved (simulated)"
        case .needsAnotherLook: "Needs another look (simulated)"
        }
    }
}

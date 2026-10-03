#if SECONDLOOK_DEMO
import SwiftUI
import SecondLookCore

struct SampleEvidenceCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72)).foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text("Synthetic lock illustration").font(.headline)
            Text("Development sample · not a real photo")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

struct SamplePreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    let itemID: UUID
    let title: String
    @State private var source: EvidenceSource = .simulatedCamera

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline)
                    SampleEvidenceCard()
                    Picker("Sample source", selection: $source) {
                        Text("Simulated camera").tag(EvidenceSource.simulatedCamera)
                        Text("Simulated library").tag(EvidenceSource.simulatedLibrary)
                    }
                    Text("Camera capture and library selection are not connected. No photo is taken, read, saved to Photos, or sent to anyone.")
                        .font(.footnote)
                }
                Section {
                    Button("Save local draft") {
                        if model.prepareSample(runID: runID, itemID: itemID, source: source) { dismiss() }
                    }
                    Button("Send sample (simulated)") {
                        if model.prepareSample(runID: runID, itemID: itemID, source: source),
                           model.sendSample(runID: runID, itemID: itemID) { dismiss() }
                    }
                    .accessibilityIdentifier("sendSample")
                } footer: {
                    Text("Saving a draft or canceling this preview preserves the previous submission and approval. Send commits the replacement and invalidates its previous approval. Then choose a simulated delivery response on the checklist.")
                }
            }
            .navigationTitle("Sample preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if let preview = model.run(runID)?.items.first(where: { $0.id == itemID })?.preview { source = preview.source }
            }
        }
    }
}

struct ReviewRequest: Identifiable {
    let runID: UUID
    let itemID: UUID
    let title: String
    let instructions: String
    let submission: PhotoSubmission
    var id: String { "\(runID)-\(itemID)-\(submission.version)" }
}

struct SampleReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ReviewRequest
    @State private var note = ""

    var isCurrent: Bool {
        guard let run = model.run(request.runID), run.isOpen,
              run.reviewerID == model.actorID,
              let current = run.items.first(where: { $0.id == request.itemID })?.submission else { return false }
        return current.version == request.submission.version && current.status == .waitingForReview
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.title).font(.headline)
                    Text(request.instructions)
                    SampleEvidenceCard()
                    Text(request.submission.source == .simulatedCamera ? "Source: simulated camera" : "Source: simulated library; original capture time unknown")
                        .font(.caption)
                    if let accepted = request.submission.acceptedAt {
                        Text("Accepted by local demo: \(accepted.formatted(date: .abbreviated, time: .standard))").font(.caption)
                    }
                    Text("Submission version \(request.submission.version). This is not proof that a physical task happened or remains done.")
                        .font(.caption)
                }
                if isCurrent {
                    Section {
                        Button("Approve sample (simulated)") {
                            if model.reviewSample(runID: request.runID, itemID: request.itemID, version: request.submission.version, note: nil) { dismiss() }
                        }
                        .accessibilityIdentifier("approveSample")
                        TextField("What should another photo show?", text: $note, axis: .vertical)
                            .accessibilityIdentifier("reviewNote")
                        Button("Request another photo (simulated)") {
                            if model.reviewSample(runID: request.runID, itemID: request.itemID, version: request.submission.version, note: note) { dismiss() }
                        }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: { Text("Looking at the sample does not approve it. A replacement request requires a short note.") }
                } else {
                    Section { Text("This submission changed or the checklist closed. Return to Review to open the current state.") }
                }
            }
            .navigationTitle("Review sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
#endif

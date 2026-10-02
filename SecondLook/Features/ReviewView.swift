import SwiftUI
import SecondLookCore

struct ReviewView: View {
    @Environment(AppModel.self) private var model
    #if SECONDLOOK_DEMO
    @State private var selected: ReviewRequest?
    var queue: [ReviewRequest] {
        model.openRuns.filter { $0.reviewerID == model.actorID }.flatMap { run in
            run.items.compactMap { item in
                guard let submission = item.submission, submission.status == .waitingForReview else { return nil }
                return ReviewRequest(runID: run.id, itemID: item.id, title: item.title, instructions: item.photoInstructions, submission: submission)
            }
        }
    }
    #endif

    var body: some View {
        Group {
            #if SECONDLOOK_DEMO
            if queue.isEmpty {
                ContentUnavailableView("No reviews waiting", systemImage: "eye", description: Text("Only accepted submissions assigned to this demo role appear here. Switch roles in Local settings to preview the other person."))
            } else {
                List(queue) { request in
                    Button { selected = request } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(request.title).font(.headline).foregroundStyle(.primary)
                            Text(model.run(request.runID)?.title ?? "Checklist").font(.subheadline)
                            Text("Waiting for review · simulated version \(request.submission.version)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("review-\(request.title)")
                }
            }
            #else
            ContentUnavailableView("Shared review is not connected", systemImage: "person.2", description: Text("This foundation stores local lists only. Private identities and shared review are later milestones."))
            #endif
        }
        .navigationTitle("Review")
        #if SECONDLOOK_DEMO
        .sheet(item: $selected) { SampleReviewView(request: $0).sheetErrorAlert() }
        #endif
    }
}

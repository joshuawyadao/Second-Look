import SwiftUI
import UIKit
import SecondLookCore

struct ConnectedRootView: View {
    @Environment(ConnectedAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("PRIVATE SHARED SPACE").font(.caption.bold())
                    Text(model.status).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().accessibilityLabel("Synchronizing") }
                Button { settings = true } label: { Image(systemName: "gearshape").padding(8) }
                    .accessibilityLabel("Account settings")
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.thinMaterial)

            if model.accountID == nil {
                ConnectedSignInView()
            } else if model.snapshot == nil {
                ConnectedPairingView()
            } else {
                TabView {
                    NavigationStack { ConnectedRoutinesView() }
                        .tabItem { Label("Routines", systemImage: "checklist") }
                    NavigationStack { ConnectedReviewView() }
                        .tabItem { Label("Review", systemImage: "eye") }
                    NavigationStack { ConnectedHistoryView() }
                        .tabItem { Label("History", systemImage: "clock") }
                }
            }
        }
        .sheet(isPresented: $settings) { ConnectedAccountSettingsView() }
        .alert("Shared action not completed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK") { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
        .tint(.teal)
        .onAppear {
            if scenePhase == .active {
                model.markForegroundActive()
                Task { await model.revalidateAfterActivation() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.markForegroundActive()
                Task { await model.revalidateAfterActivation() }
            } else if phase == .inactive || phase == .background {
                model.holdForValidation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.markForegroundActive()
            Task { await model.revalidateAfterActivation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.holdForValidation()
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await model.revalidateAfterActivation() }
            // Poll only a known, authenticated space while the scene is active. The root's
            // generation identity cancels this task when the account or environment changes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                if scenePhase == .active && model.selected && model.accountID != nil &&
                    (model.snapshot != nil || model.retryMembership) && !model.busy {
                    await model.refresh(quietly: true)
                }
            }
        }
    }
}

private struct ConnectedSignInView: View {
    @Environment(ConnectedAppModel.self) private var model
    @State private var authURL = ""
    @State private var serverURL = ""
    @State private var publishableKey = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Auth project URL", text: $authURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL)
                        .accessibilityIdentifier("sharedAuthURL")
                    TextField("Publishable key", text: $publishableKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("sharedPublishableKey")
                    TextField("Private service URL", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL)
                        .accessibilityIdentifier("sharedServerURL")
                    Text("Only public connection settings are stored here. Passwords and tokens are not stored in app preferences.")
                        .font(.footnote)
                    if model.configuration != nil {
                        Button("Reconnect saved account") { model.enqueue { await model.restore() } }
                            .disabled(model.busy)
                            .accessibilityIdentifier("reconnectSharedAccount")
                    }
                }
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("sharedEmail")
                    SecureField("Password", text: $password).textContentType(.password)
                        .accessibilityIdentifier("sharedPassword")
                    Button("Sign in") {
                        do {
                            let submittedEmail = email
                            let submittedPassword = password
                            try model.setConfiguration(authURL: authURL,
                                                       publishableKey: publishableKey,
                                                       serverURL: serverURL)
                            password = ""
                            model.enqueue { await model.signIn(email: submittedEmail, password: submittedPassword) }
                        } catch {
                            model.errorMessage = "Enter valid project and service URLs with a publishable key."
                        }
                    }
                    .disabled(model.busy || email.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("sharedSignIn")
                } header: {
                    Text("Existing invited account")
                } footer: {
                    Text("Accounts are provisioned privately. Public sign-up is unavailable.")
                }
                Section {
                    Button("Use local lists") { model.useLocal() }
                } footer: {
                    Text("Local demo lists are separate and never uploaded to a private space.")
                }
            }
            .navigationTitle("Connect Second Look")
            .onAppear { loadConfiguration() }
        }
    }

    private func loadConfiguration() {
        authURL = model.configuration?.authURL.absoluteString ?? ""
        serverURL = model.configuration?.serverURL.absoluteString ?? ""
        publishableKey = model.configuration?.publishableKey ?? ""
        #if SECONDLOOK_DEMO
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-ui-testing") && process.arguments.contains("-shared-testing") {
            authURL = process.environment["SECONDLOOK_TEST_AUTH_URL"] ?? authURL
            serverURL = process.environment["SECONDLOOK_TEST_SERVER_URL"] ?? serverURL
            publishableKey = process.environment["SECONDLOOK_TEST_PUBLISHABLE_KEY"] ?? publishableKey
        }
        #endif
    }
}

private struct ConnectedPairingView: View {
    @Environment(ConnectedAppModel.self) private var model
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Your private space") {
                    Text("Each private space has exactly two authorized accounts. The invitation is restricted to the other provisioned account and expires.")
                    Button("Create private space") { model.enqueue { await model.createSpace() } }
                        .disabled(model.busy)
                        .accessibilityIdentifier("createPrivateSpace")
                    if let invitation = model.invitation {
                        Text("Invitation for the other account")
                        Text(invitation.inviteToken)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pairingInvitation")
                        Text("Expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                    }
                }
                Section("Join an invitation") {
                    TextField("Invitation code", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("invitationCode")
                    Button("Join private space") { model.enqueue { await model.joinSpace(token: token) } }
                        .disabled(model.busy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("joinPrivateSpace")
                }
                Section {
                    Button("Check for pairing") { model.enqueue { await model.refresh() } }
                }
            }
            .navigationTitle("Pair accounts")
        }
    }
}

private struct ConnectedAccountSettingsView: View {
    @Environment(ConnectedAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let id = model.accountID { LabeledContent("Signed in", value: id.uuidString) }
                    if let snapshot = model.snapshot {
                        LabeledContent("Space", value: snapshot.spaceID.uuidString)
                        LabeledContent("Members", value: "\(snapshot.members.count) of 2")
                    }
                    if let invitation = model.invitation {
                        Text("Invitation for the other account")
                        Text(invitation.inviteToken)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("pairingInvitation")
                        Text("Expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                    }
                    if let snapshot = model.snapshot, snapshot.members.count == 1,
                       snapshot.members.first == model.accountID {
                        Button("New invitation for reviewer") { model.enqueue { await model.createSpace() } }
                            .disabled(model.busy)
                            .accessibilityIdentifier("newPairingInvitation")
                    }
                    Button("Refresh shared state") { model.enqueue { await model.refresh() } }
                        .disabled(model.accountID == nil || model.busy)
                    Button("Sign out", role: .destructive) { model.signOut(); dismiss() }
                        .disabled(model.accountID == nil)
                        .accessibilityIdentifier("sharedSignOut")
                }
                Section("Storage") {
                    Text("Shared lists live on the private service. This app keeps connected lists in memory and verifies the account and membership again after relaunch.")
                    Text("No local lists or synthetic demo evidence are uploaded. Real photo capture and notifications are not available yet.")
                }
                Section {
                    Button("Use local lists") { model.useLocal(); dismiss() }
                        .accessibilityIdentifier("returnToLocal")
                }
            }
            .navigationTitle("Account settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct ConnectedRoutinesView: View {
    @Environment(ConnectedAppModel.self) private var model
    @State private var editor: ConnectedEditorRequest?
    @State private var destination: UUID?
    @State private var startChoice: Routine?
    @State private var deleteChoice: Routine?

    var body: some View {
        List {
            Section {
                Button("Create routine", systemImage: "plus.circle") {
                    editor = ConnectedEditorRequest(routine: nil, oneOff: false)
                }.accessibilityIdentifier("sharedCreateRoutine")
                Button("Create one-off checklist", systemImage: "plus.rectangle.on.folder") {
                    editor = ConnectedEditorRequest(routine: nil, oneOff: true)
                }
                Button("Refresh") { model.enqueue { await model.refresh() } }
            }
            if !model.openRuns.isEmpty {
                Section("Open checklists") {
                    ForEach(model.openRuns) { run in
                        NavigationLink(value: run.id) {
                            VStack(alignment: .leading) {
                                Text(run.title).font(.headline)
                                Text("\(run.items.filter(\.isSatisfied).count) of \(run.items.count) ready · \(model.personName(run.performerID))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Saved routines") {
                if model.state.routines.isEmpty { Text("No shared routines yet.") }
                ForEach(model.state.routines) { routine in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(routine.title).font(.headline)
                            .accessibilityIdentifier("sharedRoutine-\(routine.title)")
                        Text("\(routine.items.count) steps · \(routine.items.filter { $0.priority == .high }.count) high priority")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(model.latestOpenRun(routine.id) == nil ? "Start" : "Resume or start") {
                                if model.latestOpenRun(routine.id) != nil { startChoice = routine }
                                else { start(routine) }
                            }.buttonStyle(.borderedProminent)
                            Button("Edit") { editor = ConnectedEditorRequest(routine: routine, oneOff: false) }
                                .buttonStyle(.bordered)
                            Button(role: .destructive) { deleteChoice = routine } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless).accessibilityLabel("Delete \(routine.title)")
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("Routines")
        .navigationDestination(for: UUID.self) { ConnectedChecklistView(runID: $0) }
        .navigationDestination(item: $destination) { ConnectedChecklistView(runID: $0) }
        .sheet(item: $editor) { ConnectedRoutineEditorView(request: $0) { destination = $0 } }
        .confirmationDialog("A checklist is already open", isPresented: Binding(
            get: { startChoice != nil }, set: { if !$0 { startChoice = nil } }
        )) {
            if let routine = startChoice {
                Button("Resume most recent") { destination = model.latestOpenRun(routine.id)?.id }
                Button("Start another run") { start(routine) }
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: Binding(
            get: { deleteChoice != nil }, set: { if !$0 { deleteChoice = nil } }
        )) {
            if let routine = deleteChoice {
                Button("Delete routine", role: .destructive) {
                    model.enqueue { _ = await model.execute(.deleteRoutine(routineID: routine.id,
                                           expectedDefinitionVersion: routine.definitionVersion)) }
                }
            }
        }
    }

    private func start(_ routine: Routine) {
        let epoch = model.generation
        model.enqueue {
            let result = await model.execute(.startRun(routineID: routine.id,
                                  expectedDefinitionVersion: routine.definitionVersion))
            if model.generation == epoch { destination = result?.createdID }
        }
    }
}

private struct ConnectedEditorRequest: Identifiable {
    let id = UUID()
    let routine: Routine?
    let oneOff: Bool
}

private struct ConnectedRoutineEditorView: View {
    @Environment(ConnectedAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ConnectedEditorRequest
    let onStart: (UUID) -> Void
    @State private var title: String
    @State private var items: [RoutineItem]
    @State private var settings: RunSettings
    @State private var saving = false

    init(request: ConnectedEditorRequest, onStart: @escaping (UUID) -> Void) {
        self.request = request; self.onStart = onStart
        _title = State(initialValue: request.routine?.title ?? "")
        _items = State(initialValue: request.routine?.items ?? [RoutineItem(title: "")])
        _settings = State(initialValue: request.routine?.settings ?? RunSettings())
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty &&
        items.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Checklist name", text: $title)
                        .accessibilityIdentifier("sharedRoutineTitle")
                }
                Section("Ordered steps") {
                    ForEach($items) { $item in
                        VStack {
                            TextField("Step description", text: $item.title, axis: .vertical)
                                .accessibilityIdentifier("sharedStepTitle-\(items.firstIndex(where: { $0.id == item.id }) ?? 0)")
                            Toggle("High priority · photo and review", isOn: Binding(
                                get: { item.priority == .high },
                                set: { item.priority = $0 ? .high : .standard }
                            ))
                            if item.priority == .high {
                                TextField("What should the photo show?", text: $item.photoInstructions, axis: .vertical)
                            }
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    Button("Add step", systemImage: "plus") { items.append(RoutineItem(title: "")) }
                }
                PreferencesFields(settings: $settings, connected: true)
                if items.contains(where: { $0.priority == .high }) {
                    Section { Text("High-priority runs need the joined reviewer. Photo capture and sending are not available yet.") }
                }
            }
            .navigationTitle(request.oneOff ? "One-off checklist" : request.routine == nil ? "New routine" : "Edit routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.oneOff ? "Start" : "Save") { save() }
                        .disabled(!valid || saving)
                        .accessibilityIdentifier("sharedSaveRoutine")
                }
                ToolbarItem(placement: .bottomBar) { EditButton() }
            }
        }
    }

    private func save() {
        let epoch = model.generation
        let routine = Routine(id: request.routine?.id ?? UUID(), title: title, items: items,
                              settings: settings,
                              definitionVersion: request.routine?.definitionVersion ?? 1)
        saving = true
        model.enqueue {
            let command: SharedCommand = request.oneOff
                ? .startOneOff(title: routine.title, items: routine.items, settings: routine.settings)
                : .saveRoutine(definition: routine,
                               expectedDefinitionVersion: request.routine?.definitionVersion)
            let result = await model.execute(command)
            guard model.generation == epoch else { return }
            saving = false
            if let result {
                dismiss()
                if let id = result.createdID { onStart(id) }
            }
        }
    }
}

private struct ConnectedChecklistView: View {
    @Environment(ConnectedAppModel.self) private var model
    let runID: UUID
    @State private var cancelConfirmation = false
    @State private var preferences = false
    @State private var savedRoutine = false
    @State private var withdrawing: ConnectedWithdrawal?

    var body: some View {
        Group {
            if let run = model.run(runID) {
                if run.isOpen {
                    List {
                        Section {
                            Text(run.title).font(.title2.bold())
                            LabeledContent("Performer", value: model.personName(run.performerID))
                            if let reviewerID = run.reviewerID {
                                LabeledContent("Reviewer", value: model.personName(reviewerID))
                            }
                            Text("\(run.items.filter(\.isSatisfied).count) of \(run.items.count) steps ready")
                            Text("Started \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                        }
                        ForEach(run.items) { item in
                            Section {
                                if item.priority == .standard {
                                    Button {
                                        model.enqueue { _ = await model.execute(.setStandardChecked(
                                            runID: run.id, itemID: item.id,
                                            checked: item.checkedAt == nil,
                                            expectedRunRevision: run.revision)) }
                                    } label: {
                                        Label(item.title, systemImage: item.checkedAt == nil ? "circle" : "checkmark.circle.fill")
                                    }
                                    .disabled(model.accountID != run.performerID || model.busy)
                                    .accessibilityValue(item.checkedAt == nil ? "Not checked" : "Checked")
                                } else {
                                    Text(item.title).font(.headline)
                                    if !item.photoInstructions.isEmpty { Text(item.photoInstructions) }
                                    if let submission = item.submission {
                                        Text("\(submission.status == .approved ? "Approved" : submission.status == .waitingForReview ? "Waiting for review" : "Needs another look") · synthetic test evidence")
                                            .font(.caption.bold())
                                        if let note = submission.decision?.note { Text("Reviewer note: \(note)") }
                                        if model.accountID == run.performerID {
                                            Button("Withdraw current synthetic submission", role: .destructive) {
                                                withdrawing = ConnectedWithdrawal(runID: run.id,
                                                    itemID: item.id, version: submission.version,
                                                    runRevision: run.revision)
                                            }
                                        }
                                    } else {
                                        Text("Photo needed · capture and upload are not available yet.")
                                    }
                                }
                            }
                        }
                        if model.accountID == run.performerID {
                            Section {
                                Button("Checklist settings") { preferences = true }
                                if run.routineID == nil {
                                    Button(savedRoutine ? "Saved as a routine" : "Save structure as a routine") {
                                        let epoch = model.generation
                                        model.enqueue {
                                            if await model.execute(.saveRunAsRoutine(
                                                runID: run.id, expectedRunRevision: run.revision,
                                                title: nil)) != nil,
                                               model.generation == epoch { savedRoutine = true }
                                        }
                                    }.disabled(savedRoutine)
                                }
                                Button("Cancel checklist", role: .destructive) { cancelConfirmation = true }
                            }
                        }
                    }
                    .navigationTitle("Checklist")
                    .sheet(isPresented: $preferences) {
                        ConnectedRunPreferencesView(runID: run.id, revision: run.revision,
                                                    settings: run.settings)
                    }
                    .confirmationDialog("Cancel this checklist?", isPresented: $cancelConfirmation) {
                        Button("Cancel checklist", role: .destructive) {
                            model.enqueue { _ = await model.execute(.cancel(runID: run.id,
                                                           expectedRunRevision: run.revision)) }
                        }
                    } message: { Text("Cancellation is terminal and archives this run separately from completion.") }
                    .confirmationDialog("Withdraw this submission?", isPresented: Binding(
                        get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } }
                    )) {
                        if let withdrawing {
                            Button("Withdraw version \(withdrawing.version)", role: .destructive) {
                                model.enqueue { _ = await model.execute(.withdraw(
                                    runID: withdrawing.runID, itemID: withdrawing.itemID,
                                    expectedVersion: withdrawing.version,
                                    expectedRunRevision: withdrawing.runRevision)) }
                            }
                        }
                    } message: { Text("The current approval will no longer count. The server checks the exact version before removal.") }
                } else { ConnectedArchiveDetailView(archiveID: runID) }
            } else { ContentUnavailableView("Checklist unavailable", systemImage: "checklist") }
        }
    }
}

private struct ConnectedWithdrawal {
    let runID: UUID
    let itemID: UUID
    let version: Int
    let runRevision: Int
}

private struct ConnectedRunPreferencesView: View {
    @Environment(ConnectedAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let runID: UUID
    let revision: Int
    @State var settings: RunSettings
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form { PreferencesFields(settings: $settings, connected: true) }
                .navigationTitle("Checklist settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let epoch = model.generation
                            saving = true
                            model.enqueue {
                                let result = await model.execute(.updateRunSettings(
                                    runID: runID, settings: settings,
                                    expectedRunRevision: revision))
                                if model.generation == epoch {
                                    saving = false
                                    if result != nil { dismiss() }
                                }
                            }
                        }.disabled(saving)
                    }
                }
        }
    }
}

private struct ConnectedReviewRequest: Identifiable {
    let run: ChecklistRun
    let item: RunItem
    let version: Int
    var id: String { "\(run.id)-\(item.id)-\(version)" }
}

private struct ConnectedReviewView: View {
    @Environment(ConnectedAppModel.self) private var model
    @State private var selected: ConnectedReviewRequest?

    private var queue: [ConnectedReviewRequest] {
        model.openRuns.filter { $0.reviewerID == model.accountID }.flatMap { run in
            run.items.compactMap { item in
                guard let submission = item.submission,
                      submission.status == .waitingForReview else { return nil }
                return ConnectedReviewRequest(run: run, item: item, version: submission.version)
            }
        }
    }

    var body: some View {
        Group {
            if queue.isEmpty {
                ContentUnavailableView("No reviews waiting", systemImage: "eye",
                                       description: Text("Accepted evidence assigned to this account appears here after refresh."))
            } else {
                List(queue) { request in
                    Button { selected = request } label: {
                        VStack(alignment: .leading) {
                            Text(request.item.title).font(.headline)
                            Text(request.run.title)
                            Text("Waiting for review · version \(request.version)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .toolbar { Button("Refresh") { model.enqueue { await model.refresh() } } }
        .sheet(item: $selected) { ConnectedReviewDetailView(request: $0) }
    }
}

private struct ConnectedReviewDetailView: View {
    @Environment(ConnectedAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ConnectedReviewRequest
    @State private var note = ""
    @State private var saving = false

    private var current: (ChecklistRun, RunItem)? {
        guard let run = model.run(request.run.id), run.isOpen,
              run.reviewerID == model.accountID,
              let item = run.items.first(where: { $0.id == request.item.id }),
              item.submission?.status == .waitingForReview,
              item.submission?.version == request.version else { return nil }
        return (run, item)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Submission") {
                    Text(request.item.title).font(.headline)
                    Text(request.item.photoInstructions)
                    Text("Version \(request.version) · synthetic test evidence. No real photo is connected in this milestone.")
                    if let accepted = request.item.submission?.acceptedAt {
                        Text("Accepted \(accepted.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text("Viewing evidence does not approve it or prove the physical task happened.")
                        .font(.footnote)
                }
                if let (run, item) = current {
                    Section("Decision") {
                        Button("Approve version \(request.version)") {
                            decide(.approve(runID: run.id, itemID: item.id,
                                            expectedVersion: request.version,
                                            expectedRunRevision: run.revision))
                        }.disabled(saving)
                        TextField("What should another photo show?", text: $note, axis: .vertical)
                        Button("Request another photo") {
                            decide(.requestAnother(runID: run.id, itemID: item.id,
                                                   expectedVersion: request.version, note: note,
                                                   expectedRunRevision: run.revision))
                        }
                        .disabled(saving || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Section { Text("This submission changed or the checklist closed. Return to the current queue.") }
                }
            }
            .navigationTitle("Review step")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func decide(_ command: SharedCommand) {
        let epoch = model.generation
        saving = true
        model.enqueue {
            let accepted = await model.execute(command) != nil
            if model.generation == epoch {
                saving = false
                if accepted { dismiss() }
            }
        }
    }
}

private struct ConnectedHistoryView: View {
    @Environment(ConnectedAppModel.self) private var model
    var body: some View {
        Group {
            if model.state.archives.isEmpty {
                ContentUnavailableView("History starts here", systemImage: "clock")
            } else {
                List(model.state.archives.sorted { $0.closedAt > $1.closedAt }) { archive in
                    NavigationLink {
                        ConnectedArchiveDetailView(archiveID: archive.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(archive.title).font(.headline)
                            Text(archive.outcome == .completed ? "Completed" : "Canceled")
                            Text(archive.closedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar { Button("Refresh") { model.enqueue { await model.refresh() } } }
    }
}

private struct ConnectedArchiveDetailView: View {
    @Environment(ConnectedAppModel.self) private var model
    let archiveID: UUID
    @State private var newRun: UUID?
    @State private var savedRoutine = false

    var body: some View {
        Group {
            if let archive = model.state.archives.first(where: { $0.id == archiveID }) {
                List {
                    Section {
                        Text(archive.title).font(.title2.bold())
                        Text(archive.outcome == .completed ? "Completed" : "Canceled")
                        LabeledContent("Performer", value: model.personName(archive.performerID))
                        if let reviewer = archive.reviewerID {
                            LabeledContent("Reviewer", value: model.personName(reviewer))
                        }
                    }
                    Section("Text-only record") {
                        ForEach(Array(archive.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline)
                                if let checked = item.checkedAt { Text("Checked \(checked.formatted())") }
                                ForEach(Array(item.decisions.enumerated()), id: \.offset) { _, decision in
                                    Text("\(model.personName(decision.actorID)): \(decision.verdict == .approved ? "Approved" : "Requested another photo") · version \(decision.submissionVersion)")
                                    if let note = decision.note { Text(note).font(.caption) }
                                }
                            }
                        }
                    }
                    Section {
                        Text("No image, thumbnail, or live photo link is kept in history.")
                        Text("Any cleanup status here refers to synthetic test evidence. Real media deletion is not available yet.")
                        Button("Start new run") {
                            let epoch = model.generation
                            guard let source = model.state.runs.first(where: { $0.id == archive.id }) else {
                                model.errorMessage = "The original run is unavailable. Refresh shared history."
                                return
                            }
                            model.enqueue {
                                let result = await model.execute(.repeatRun(runID: archive.id,
                                                                            expectedRunRevision: source.revision))
                                if model.generation == epoch { newRun = result?.createdID }
                            }
                        }
                        Button(savedRoutine ? "Saved as a routine" : "Save structure as a routine") {
                            guard let source = model.state.runs.first(where: { $0.id == archive.id }) else {
                                model.errorMessage = "The original run is unavailable. Refresh shared history."
                                return
                            }
                            let epoch = model.generation
                            model.enqueue {
                                let result = await model.execute(.saveRunAsRoutine(
                                    runID: source.id, expectedRunRevision: source.revision,
                                    title: nil))
                                if model.generation == epoch && result != nil { savedRoutine = true }
                            }
                        }.disabled(savedRoutine)
                    }
                }
                .navigationTitle("History record")
                .navigationDestination(item: $newRun) { ConnectedChecklistView(runID: $0) }
            } else { ContentUnavailableView("Record unavailable", systemImage: "clock") }
        }
    }
}

import SwiftUI
import UIKit
import SecondLookCore

private struct ConnectedPollingTaskID: Equatable {
    let phase: ScenePhase
    let scheduleEpoch: UInt64
}

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
                        .accessibilityIdentifier("sharedConnectionStatus")
                }
                Spacer()
                if model.busy { ProgressView().accessibilityLabel("Synchronizing") }
                Button { settings = true } label: { Image(systemName: "gearshape").padding(8) }
                    .accessibilityLabel("Account settings")
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.thinMaterial)

            #if SECONDLOOK_DEMO
            if model.refreshMismatchChecksRequested {
                Text("Refresh account mismatch (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedRefreshIdentityMismatch")
            }
            SharedRefreshAcceptanceControls()
            if ProcessInfo.processInfo.arguments.contains("-ui-testing") &&
               ProcessInfo.processInfo.arguments.contains("-shared-testing") &&
               (ProcessInfo.processInfo.arguments.contains("-shared-test-draft-lifecycle") ||
                ProcessInfo.processInfo.arguments.contains("-shared-test-draft-access-loss")) {
                if model.snapshot != nil {
                    Button("Pause next draft revalidation for test") {
                        model.armDraftRevalidationPauseForAcceptance()
                    }
                    .accessibilityIdentifier("armSharedDraftRevalidation")
                    .disabled(model.busy)
                    Button("Prepare synthetic review draft for test") {
                        model.enqueue { await model.prepareSharedReviewDraftProbe() }
                    }
                    .accessibilityIdentifier("prepareSharedReviewDraftProbe")
                    .disabled(model.busy || model.snapshot?.members.count != 2)
                }
                if model.simulatedDraftRevalidationPause {
                    Text("Foreground draft revalidation paused (simulated for acceptance)")
                        .font(.caption)
                        .accessibilityIdentifier("sharedSimulatedDraftRevalidationPause")
                    Button("Resume verified draft presentation") {
                        model.resumeDraftRevalidationForAcceptance()
                    }
                    .accessibilityIdentifier("resumeSharedDraftRevalidation")
                }
                if let result = model.sharedReviewDraftProbeStatus {
                    Text(result).font(.caption)
                        .accessibilityIdentifier("sharedReviewDraftProbeStatus")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing") &&
               ProcessInfo.processInfo.arguments.contains("-shared-testing") &&
               ProcessInfo.processInfo.arguments.contains("-shared-test-cleanup-status") &&
               model.snapshot?.members.count == 2 {
                Button("Check synthetic archive cleanup statuses") {
                    model.enqueue { await model.runSharedCleanupProbe() }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("runSharedCleanupProbe")
                if let result = model.sharedCleanupProbeStatus {
                    Text(result).font(.caption)
                        .accessibilityIdentifier("sharedCleanupProbeStatus")
                }
            }
            if model.simulatedPairingReplyLoss {
                Text("Pairing reply loss (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedPairingReplyLoss")
            }
            if model.simulatedCommandReplyLoss {
                Text("Command reply loss (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedCommandReplyLoss")
            }
            if model.simulatedCreationReplyLoss {
                Text("Creation reply loss (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedCreationReplyLoss")
            }
            if model.simulatedCommandScopeLoss {
                Text("Command scope loss after commit (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedCommandScopeLoss")
            }
            if let result = model.creationReceiptAcceptanceStatus {
                Text(result).font(.caption)
                    .accessibilityIdentifier("sharedCreationReceiptResult")
            }
            if model.simulatedForbiddenRestore {
                Text("Saved-session rejection (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedForbiddenRestore")
            }
            if let result = model.forbiddenRestoreCredentialStatus {
                Text(result).font(.caption)
                    .accessibilityIdentifier("sharedForbiddenRestoreCredentialStatus")
            }
            if let result = model.invitationReceiptAcceptanceStatus {
                Text(result).font(.caption)
                    .accessibilityIdentifier("sharedInvitationReceiptResult")
            }
            if model.lifecycleReceiptChecksRequested && model.simulatedLifecycleRevalidationPause {
                Text("Foreground membership publication paused (simulated for acceptance)")
                    .font(.caption)
                    .accessibilityIdentifier(model.lifecycleRevalidationPauseCount > 1
                        ? "sharedSimulatedSecondLifecycleRevalidationPause"
                        : "sharedSimulatedLifecycleRevalidationPause")
                Button("Resume verified membership") {
                    model.resumeLifecycleRevalidationForAcceptance()
                }
                .accessibilityIdentifier("resumeSharedLifecycleRevalidation")
            }
            if model.restoreRaceChecksRequested {
                VStack {
                    Text("Concurrent reconnect triggers (simulated for acceptance)").font(.caption)
                    Text("\(model.restoreCandidateCount)")
                        .accessibilityIdentifier("sharedRestoreCandidateCount")
                }
            }
            if model.simulatedMembershipFailure {
                Text("Membership lookup failure (simulated for acceptance)").font(.caption)
                    .accessibilityIdentifier("sharedSimulatedMembershipFailure")
            }
            if let result = model.commandAcceptanceStatus {
                Text(result).font(.caption)
                    .accessibilityIdentifier("sharedCommandAcceptanceResult")
            }
            #endif

            if !model.unconfirmedActions.isEmpty {
                Menu("Retry unconfirmed action") {
                    ForEach(model.unconfirmedActions) { action in
                        Button(action.title) { model.enqueue { _ = await model.retryUnconfirmedAction(action.id) } }
                            .disabled(!model.canRetryUnconfirmedAction(action.id))
                    }
                }
                .disabled(model.busy)
                .accessibilityIdentifier("retryUnconfirmedAction")
            }

            if model.accountID == nil {
                ConnectedSignInView()
            } else if !model.hasContentForPresentation {
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
                .connectedRevalidationGate()
            }
        }
        .sheet(isPresented: $settings) {
            ConnectedAccountSettingsView()
                .connectedRevalidationGate()
                .connectedActionErrors(inSheet: true)
        }
        .connectedActionErrors()
        .tint(.teal)
        .onChange(of: model.accountID) { _, account in
            if account == nil { settings = false }
        }
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
        .task(id: ConnectedPollingTaskID(phase: scenePhase, scheduleEpoch: model.pollingScheduleEpoch)) {
            // Lifecycle callbacks above own full revalidation. This task owns only
            // periodic polling, so resetting its sleep cannot cancel revalidation.
            guard scenePhase == .active else { return }
            #if SECONDLOOK_DEMO
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ui-testing") && arguments.contains("-shared-testing") &&
                arguments.contains("-shared-no-periodic-poll") { return }
            #endif
            // Poll only a known, authenticated space while the scene is active. The root's
            // generation identity cancels this task when the account or environment changes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(model.nextPollDelay * 1_000_000_000))
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
                        .disabled(model.busy)
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
                        .disabled(model.busy || !model.canCreatePrivateSpace)
                        .accessibilityIdentifier("createPrivateSpace")
                    if !model.confirmedNoSpace {
                        Text("Check private-space membership before creating or joining a space.")
                    }
                    if let invitation = model.visibleInvitation {
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
                        .disabled(model.busy || !model.canJoinPrivateSpace || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("joinPrivateSpace")
                }
                Section {
                    Button("Check for pairing") { model.enqueue { await model.refresh() } }
                        .disabled(model.busy)
                        .accessibilityIdentifier("sharedCheckPairing")
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
                    if let invitation = model.visibleInvitation {
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
                #if SECONDLOOK_DEMO
                if model.invitationExpiryChecksRequested {
                    Section("Synthetic local acceptance") {
                        Button("Arm short display deadline for test") {
                            model.armShortInvitationDisplayDeadlineForAcceptance()
                        }
                        .accessibilityIdentifier("testArmShortInvitationDisplayDeadline")
                        if model.simulatedInvitationDisplayDeadline {
                            Text("Short invitation display deadline (simulated for acceptance)")
                                .accessibilityIdentifier("sharedSimulatedInvitationDisplayDeadline")
                        }
                        Button("Pause next genuine refresh for test") {
                            model.beginDelayedRefreshForAcceptance()
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("testDelayInvitationRefresh")
                        if model.simulatedRefreshDelay {
                            Text("Genuine refresh publication paused (simulated for acceptance)")
                                .accessibilityIdentifier("sharedSimulatedInvitationRefreshDelay")
                        }
                        Button("Resume genuine refresh for test") {
                            model.resumeRefreshForAcceptance()
                        }
                        .disabled(!model.simulatedRefreshDelay)
                        .accessibilityIdentifier("testResumeInvitationRefresh")
                        Button("Deliver old expiry callback for test") {
                            model.deliverOldInvitationExpiryForAcceptance()
                        }
                        .accessibilityIdentifier("testDeliverOldInvitationExpiry")
                        if model.simulatedOldInvitationExpiryDelivered {
                            Text("Old invitation expiry callback delivered (simulated for acceptance)")
                                .accessibilityIdentifier("sharedSimulatedOldInvitationExpiryDelivered")
                        }
                    }
                }
                if model.refreshMismatchChecksRequested, model.accountID != nil {
                    Section("Synthetic local acceptance") {
                        Button("Test refresh account mismatch") {
                            model.enqueue { await model.refreshWithMismatchedAccountForAcceptance() }
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("testSharedRefreshMismatch")
                        Text("Refresh account mismatch (simulated for acceptance)")
                    }
                }
                if model.canInvalidateAccessForAcceptance {
                    Section("Synthetic local acceptance") {
                        Button(model.accessInvalidatedForAcceptance ? "Test access token invalidated" :
                               "Invalidate access token for test") {
                            model.enqueue { await model.invalidateAccessForAcceptance() }
                        }
                        .accessibilityIdentifier("testSharedInvalidateAccess")
                        .disabled(model.busy || model.accessInvalidatedForAcceptance)
                        Text("For the isolated localhost access-denial test.")
                    }
                }
                #endif
                Section("Storage") {
                    Text("Shared lists live on the private service. This app keeps connected lists in memory and verifies the account and membership again after relaunch.")
                    Text("No local lists or synthetic demo evidence are uploaded. Real photo capture and notifications are not available yet.")
                }
                Section {
                    Button("Use local lists") {
                        guard !model.busy else { return }
                        model.useLocal()
                        dismiss()
                    }
                        .disabled(model.busy)
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
    @State private var completionOwner = UUID()

    var body: some View {
        List {
            Section {
                Button("Create routine", systemImage: "plus.circle") {
                    openEditor(routine: nil, oneOff: false)
                }.accessibilityIdentifier("sharedCreateRoutine")
                Button("Create one-off checklist", systemImage: "plus.rectangle.on.folder") {
                    openEditor(routine: nil, oneOff: true)
                }
                Button("Refresh") { model.enqueue { await model.refresh() } }.disabled(model.busy)
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
                        .accessibilityIdentifier("sharedOpenRun-\(run.id)")
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
                                .accessibilityIdentifier("sharedStartRoutine-\(routine.title)")
                                .disabled(model.busy || model.hasUnconfirmedCreation(owner: completionOwner))
                            Button("Edit") { openEditor(routine: routine, oneOff: false) }
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
        .sheet(item: $editor) {
            ConnectedRoutineEditorView(request: $0,
                retainedDraft: model.pendingEditorDraft(routine: $0.routine, oneOff: $0.oneOff)) {
                destination = $0
            }
                .connectedRevalidationGate()
                .connectedActionErrors(inSheet: true)
        }
        .confirmationDialog("A checklist is already open", isPresented: Binding(
            get: { startChoice != nil }, set: { if !$0 { startChoice = nil } }
        )) {
            if let routine = startChoice {
                Button("Resume most recent") { destination = model.latestOpenRun(routine.id)?.id }
                Button("Start another run") { start(routine) }
                    .disabled(model.busy || model.hasUnconfirmedCreation(owner: completionOwner))
            }
        }
        .confirmationDialog("Delete this routine?", isPresented: Binding(
            get: { deleteChoice != nil }, set: { if !$0 { deleteChoice = nil } }
        )) {
            if let routine = deleteChoice {
                Button("Delete routine", role: .destructive) {
                    model.enqueue { _ = await model.execute(.deleteRoutine(routineID: routine.id,
                                           expectedDefinitionVersion: routine.definitionVersion)) }
                }.disabled(model.busy)
            }
        }
    }

    private func start(_ routine: Routine) {
        guard !model.hasUnconfirmedCreation(owner: completionOwner) else { return }
        let commandID = UUID()
        model.registerCreationCompletion(commandID: commandID, owner: completionOwner) { receipt in
            if let createdID = receipt.createdID { destination = createdID }
        }
        model.enqueue {
            _ = await model.execute(.startRun(routineID: routine.id,
                                  expectedDefinitionVersion: routine.definitionVersion),
                                  commandID: commandID)
        }
    }

    private func openEditor(routine: Routine?, oneOff: Bool) {
        if let pending = model.pendingEditorDraft(routine: routine, oneOff: oneOff) {
            editor = ConnectedEditorRequest(id: pending.requestID, routine: pending.routine,
                                            oneOff: pending.oneOff)
        } else {
            editor = ConnectedEditorRequest(routine: routine, oneOff: oneOff)
        }
    }
}

private struct ConnectedEditorRequest: Identifiable {
    let id: UUID
    let routine: Routine?
    let oneOff: Bool

    init(id: UUID = UUID(), routine: Routine?, oneOff: Bool) {
        self.id = id; self.routine = routine; self.oneOff = oneOff
    }
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
    @State private var bindingID = UUID()

    private var creationIntent: ConnectedAppModel.CreationIntent { .editor(request.id) }

    init(request: ConnectedEditorRequest, retainedDraft: ConnectedAppModel.PendingEditorDraft?,
         onStart: @escaping (UUID) -> Void) {
        self.request = request; self.onStart = onStart
        let retained = retainedDraft?.requestID == request.id ? retainedDraft : nil
        _title = State(initialValue: retained?.title ?? request.routine?.title ?? "")
        _items = State(initialValue: retained?.items ?? request.routine?.items ?? [RoutineItem(title: "")])
        _settings = State(initialValue: retained?.settings ?? request.routine?.settings ?? RunSettings())
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty &&
        items.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                #if SECONDLOOK_DEMO
                if model.simulatedConfirmedCreationConsumptionPause {
                    Text("Confirmed creation consumption paused (simulated for acceptance)")
                        .font(.caption)
                        .accessibilityIdentifier("sharedSimulatedConfirmedCreationPause")
                }
                SharedRefreshAcceptanceControls(inEditor: true)
                #endif
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
                if model.hasPendingCreation(creationIntent) {
                    Section("Unconfirmed creation") {
                        Button("Retry original creation") {
                            model.enqueue { _ = await model.retryCreationAction(creationIntent) }
                        }
                        .accessibilityIdentifier("retryCreationAction")
                        .disabled(model.busy || !model.canRetryCreation(creationIntent))
                        Text("The original action may already be saved. Retry checks its receipt before creating anything new.")
                            .font(.footnote)
                    }
                }
                if items.contains(where: { $0.priority == .high }) {
                    Section { Text("High-priority runs need the joined reviewer. Photo capture and sending are not available yet.") }
                }
            }
            .navigationTitle(request.oneOff ? "One-off checklist" : request.routine == nil ? "New routine" : "Edit routine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.oneOff ? "Start" : "Save") { save() }
                        .disabled(!valid || saving || model.busy ||
                                  model.hasPendingCreation(creationIntent))
                        .accessibilityIdentifier("sharedSaveRoutine")
                }
                ToolbarItem(placement: .bottomBar) { EditButton() }
            }
        }
        .onChange(of: model.generation) { _, _ in saving = false }
        .onAppear { bindPendingCreation() }
        .onDisappear { model.detachCreation(bindingID: bindingID) }
    }

    private func save() {
        guard !model.hasPendingCreation(creationIntent) else { return }
        let epoch = model.generation
        let routine = Routine(id: request.routine?.id ?? request.id, title: title, items: items,
                              settings: settings,
                              definitionVersion: request.routine?.definitionVersion ?? 1)
        let commandID = UUID()
        let command: SharedCommand = request.oneOff
            ? .startOneOff(title: routine.title, items: routine.items, settings: routine.settings)
            : .saveRoutine(definition: routine,
                           expectedDefinitionVersion: request.routine?.definitionVersion)
        let draft = ConnectedAppModel.PendingEditorDraft(requestID: request.id,
            routine: request.routine, oneOff: request.oneOff, title: title, items: items,
            settings: settings)
        guard model.beginCreation(creationIntent, commandID: commandID,
                                  bindingID: bindingID, editorDraft: draft, completion: { receipt in
            saving = false
            dismiss()
            if let createdID = receipt.createdID { onStart(createdID) }
        }) else { return }
        saving = true
        model.enqueueCreation(commandID: commandID) {
            let result = await model.execute(command, commandID: commandID)
            guard model.generation == epoch else { return }
            if result == nil { saving = false }
        }
    }

    private func bindPendingCreation() {
        model.bindCreation(creationIntent, bindingID: bindingID) { receipt in
            saving = false
            dismiss()
            if let createdID = receipt.createdID { onStart(createdID) }
        }
    }
}

#if SECONDLOOK_DEMO
private struct SharedRefreshAcceptanceControls: View {
    @Environment(ConnectedAppModel.self) private var model
    var inEditor = false

    var body: some View {
        if model.refreshDelayChecksRequested && model.snapshot != nil {
            VStack {
                if model.simulatedRefreshDelay {
                    Text("Shared refresh delay (simulated for acceptance)").font(.caption)
                        .accessibilityIdentifier(inEditor ? "sharedSimulatedRefreshDelayInEditor" : "sharedSimulatedRefreshDelay")
                    Button("Attempt overlapping refresh for test") {
                        model.enqueue { await model.attemptOverlappingRefreshForAcceptance() }
                    }
                    .accessibilityIdentifier(inEditor ? "testOverlapSharedRefreshInEditor" : "testOverlapSharedRefresh")
                    if let result = model.overlappingRefreshAcceptanceResult {
                        Text(result ? "Overlapping refresh admitted (simulated trigger)" : "Overlapping refresh rejected (simulated trigger)")
                            .accessibilityIdentifier(inEditor ? "sharedOverlapRefreshResultInEditor" : "sharedOverlapRefreshResult")
                    }
                    Button("Complete delayed refresh") { model.resumeRefreshForAcceptance() }
                        .accessibilityIdentifier(inEditor ? "testResumeSharedRefreshInEditor" : "testResumeSharedRefresh")
                } else {
                    Button("Delay next refresh for test") { model.beginDelayedRefreshForAcceptance() }
                        .disabled(model.busy)
                        .accessibilityIdentifier(inEditor ? "testDelaySharedRefreshInEditor" : "testDelaySharedRefresh")
                }
            }
        }
    }
}
#endif

private struct ConnectedChecklistView: View {
    @Environment(ConnectedAppModel.self) private var model
    let runID: UUID
    @State private var cancelConfirmation = false
    @State private var preferences = false
    @State private var savedRoutine = false
    @State private var withdrawing: ConnectedWithdrawal?
    @State private var creationBindingID = UUID()

    private var saveAsIntent: ConnectedAppModel.CreationIntent { .saveAs(runID) }

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
                                        guard !model.hasPendingCreation(saveAsIntent) else { return }
                                        let commandID = UUID()
                                        guard model.beginCreation(saveAsIntent, commandID: commandID,
                                            bindingID: creationBindingID, completion: { _ in
                                            savedRoutine = true
                                        }) else { return }
                                        model.enqueueCreation(commandID: commandID) {
                                            _ = await model.execute(.saveRunAsRoutine(
                                                runID: run.id, expectedRunRevision: run.revision,
                                                title: nil), commandID: commandID)
                                        }
                                    }.disabled(savedRoutine || model.busy ||
                                               model.hasPendingCreation(saveAsIntent))
                                }
                                Button("Cancel checklist", role: .destructive) { cancelConfirmation = true }
                            }
                        }
                    }
                    .navigationTitle("Checklist")
                    .sheet(isPresented: $preferences) {
                        ConnectedRunPreferencesView(runID: run.id, revision: run.revision,
                                                    settings: run.settings)
                            .connectedRevalidationGate()
                            .connectedActionErrors(inSheet: true)
                    }
                    .confirmationDialog("Cancel this checklist?", isPresented: $cancelConfirmation) {
                        Button("Cancel checklist", role: .destructive) {
                            model.enqueue { _ = await model.execute(.cancel(runID: run.id,
                                                           expectedRunRevision: run.revision)) }
                        }.disabled(model.busy)
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
                            }.disabled(model.busy)
                        }
                    } message: { Text("The current approval will no longer count. The server checks the exact version before removal.") }
                } else { ConnectedArchiveDetailView(archiveID: runID) }
            } else { ContentUnavailableView("Checklist unavailable", systemImage: "checklist") }
        }
        .onAppear {
            model.bindCreation(saveAsIntent, bindingID: creationBindingID) { _ in
                savedRoutine = true
            }
        }
        .onDisappear { model.detachCreation(bindingID: creationBindingID) }
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
                        }.disabled(saving || model.busy)
                    }
                }
        }
        .onChange(of: model.generation) { _, _ in saving = false }
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
        .toolbar { Button("Refresh") { model.enqueue { await model.refresh() } }.disabled(model.busy) }
        .sheet(item: $selected) {
            ConnectedReviewDetailView(request: $0)
                .connectedRevalidationGate()
                .connectedActionErrors(inSheet: true)
        }
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
                        }.disabled(saving || model.busy)
                        TextField("What should another photo show?", text: $note, axis: .vertical)
                            .accessibilityIdentifier("sharedReviewNote")
                        Button("Request another photo") {
                            decide(.requestAnother(runID: run.id, itemID: item.id,
                                                   expectedVersion: request.version, note: note,
                                                   expectedRunRevision: run.revision))
                        }
                        .disabled(saving || model.busy || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Section { Text("This submission changed or the checklist closed. Return to the current queue.") }
                }
            }
            .navigationTitle("Review step")
            .toolbar { Button("Done") { dismiss() } }
        }
        .onChange(of: model.generation) { _, _ in saving = false }
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
                            Text(archive.cleanupStatus.title).font(.caption)
                            Text(archive.closedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar { Button("Refresh") { model.enqueue { await model.refresh() } }.disabled(model.busy) }
    }
}

private struct ConnectedArchiveDetailView: View {
    @Environment(ConnectedAppModel.self) private var model
    let archiveID: UUID
    @State private var newRun: UUID?
    @State private var savedRoutine = false
    @State private var creationBindingID = UUID()

    private var repeatIntent: ConnectedAppModel.CreationIntent { .repeatRun(archiveID) }
    private var saveAsIntent: ConnectedAppModel.CreationIntent { .saveAs(archiveID) }
    private var pendingCreation: Bool {
        model.hasPendingCreation(repeatIntent) || model.hasPendingCreation(saveAsIntent)
    }

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
                    Section("Cleanup") {
                        Text(archive.cleanupStatus.title)
                            .accessibilityIdentifier("sharedArchiveCleanupStatus")
                        Text("This status describes synthetic test metadata only. No real photo is stored or deleted; connected cleanup jobs are not available yet.")
                            .font(.footnote)
                            .accessibilityIdentifier("sharedArchiveCleanupExplanation")
                        Text("History contains no image, thumbnail, or live photo link.")
                            .font(.footnote)
                            .accessibilityIdentifier("sharedArchiveMediaExplanation")
                    }
                    Section {
                        Button("Start new run") {
                            guard !pendingCreation else { return }
                            guard let source = model.state.runs.first(where: { $0.id == archive.id }) else {
                                model.errorMessage = "The original run is unavailable. Refresh shared history."
                                return
                            }
                            let commandID = UUID()
                            guard model.beginCreation(repeatIntent, commandID: commandID,
                                bindingID: creationBindingID, completion: { receipt in
                                newRun = receipt.createdID
                            }) else { return }
                            model.enqueueCreation(commandID: commandID) {
                                _ = await model.execute(.repeatRun(runID: archive.id,
                                                                   expectedRunRevision: source.revision),
                                                        commandID: commandID)
                            }
                        }.disabled(model.busy || pendingCreation)
                        Button(savedRoutine ? "Saved as a routine" : "Save structure as a routine") {
                            guard !pendingCreation else { return }
                            guard let source = model.state.runs.first(where: { $0.id == archive.id }) else {
                                model.errorMessage = "The original run is unavailable. Refresh shared history."
                                return
                            }
                            let commandID = UUID()
                            guard model.beginCreation(saveAsIntent, commandID: commandID,
                                bindingID: creationBindingID, completion: { _ in
                                savedRoutine = true
                            }) else { return }
                            model.enqueueCreation(commandID: commandID) {
                                _ = await model.execute(.saveRunAsRoutine(
                                    runID: source.id, expectedRunRevision: source.revision,
                                    title: nil), commandID: commandID)
                            }
                        }.disabled(savedRoutine || model.busy ||
                                   pendingCreation)
                    }
                }
                .navigationTitle("History record")
                .navigationDestination(item: $newRun) { ConnectedChecklistView(runID: $0) }
            } else { ContentUnavailableView("Record unavailable", systemImage: "clock") }
        }
        .onAppear {
            model.bindCreation(repeatIntent, bindingID: creationBindingID) { receipt in
                newRun = receipt.createdID
            }
            model.bindCreation(saveAsIntent, bindingID: creationBindingID) { _ in
                savedRoutine = true
            }
        }
        .onDisappear { model.detachCreation(bindingID: creationBindingID) }
    }
}

import Foundation
import Observation
import SecondLookCore
import UIKit

@MainActor @Observable
final class ConnectedAppModel {
    private(set) var selected: Bool
    private(set) var configuration: ConnectedConfiguration?
    private(set) var generation: UInt64 = 0
    private(set) var presentationGeneration: UInt64 = 0
    // Frozen render data is private session memory, never authorization or a command snapshot.
    private var heldSnapshot: SharedSnapshot?
    var hasContentForPresentation: Bool { snapshot != nil || heldSnapshot != nil }
    var needsPresentationRevalidation: Bool { snapshot == nil && heldSnapshot != nil }
    private(set) var accountID: UUID?
    private(set) var snapshot: SharedSnapshot? {
        didSet {
            if snapshot != nil { heldSnapshot = nil }
            if let invitation,
               snapshot?.spaceID != invitation.snapshot.spaceID ||
               (snapshot?.revision ?? -1) > invitation.snapshot.revision {
                self.invitation = nil
            }
        }
    }
    private(set) var invitation: PairingInvitation?
    private(set) var retryMembership = false
    private(set) var confirmedNoSpace = false
    private(set) var status = "Sign in to connect a private space."
    var errorMessage: String? {
        didSet { retryActionForError = nil }
    }
    private(set) var retryActionForError: UUID?
    private(set) var unconfirmedActions: [UnconfirmedAction] = []
    @ObservationIgnored private var issuedActions: [UnconfirmedAction] = []
    @ObservationIgnored private var suspendedScope: SharedAccountScope?
    private struct SuspendedSharedAlert {
        let scope: SharedAccountScope
        let minimumRevision: Int
        let message: String
        let retryActionID: UUID?
        let sheetID: UUID?
    }
    @ObservationIgnored private var suspendedSharedAlert: SuspendedSharedAlert?
    @ObservationIgnored private var creationCompletions: [UUID: CreationCompletion] = [:]
    private var errorSheetIDs: [UUID] = []
    var busy = false

    func registerErrorSheet(_ id: UUID) {
        if !errorSheetIDs.contains(id) { errorSheetIDs.append(id) }
    }

    func unregisterErrorSheet(_ id: UUID) {
        errorSheetIDs.removeAll { $0 == id }
    }

    func canPresentSharedError(sheetID: UUID?) -> Bool {
        guard errorMessage != nil else { return false }
        return sheetID.map { errorSheetIDs.last == $0 } ?? errorSheetIDs.isEmpty
    }

    #if SECONDLOOK_DEMO
    private(set) var sharedCleanupProbeStatus: String?
    private(set) var sharedReviewDraftProbeStatus: String?
    private(set) var simulatedDraftRevalidationPause = false
    private(set) var simulatedDraftAccessLoss = false
    @ObservationIgnored private var pauseNextDraftRevalidation = false
    @ObservationIgnored private var draftRevalidationContinuation: CheckedContinuation<Void, Never>?
    private(set) var commandAcceptanceStatus: String?
    private(set) var accessInvalidatedForAcceptance = false
    private(set) var simulatedMembershipFailure = false
    private(set) var simulatedForbiddenRestore = false
    private(set) var forbiddenRestoreCredentialStatus: String?
    private(set) var simulatedCreationReplyLoss = false
    private(set) var simulatedCommandScopeLoss = false
    private(set) var creationReceiptAcceptanceStatus: String?
    private(set) var simulatedConfirmedCreationConsumptionPause = false
    @ObservationIgnored private var confirmedCreationConsumptionContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var didPauseConfirmedCreationConsumption = false
    @ObservationIgnored private var creationReceiptActionID: UUID?
    @ObservationIgnored private var creationReceiptCreatedID: UUID?
    @ObservationIgnored private var creationReceiptCommand: SharedCommand?
    @ObservationIgnored private var creationReceiptLossClient: SharedInvitationReceiptLossClient?
    @ObservationIgnored private var scopeLossActionID: UUID?
    @ObservationIgnored private var didDropCreationReply = false
    @ObservationIgnored private var didSimulateMembershipFailure = false
    @ObservationIgnored private var commandAcceptanceTask: Task<Void, Never>?
    @ObservationIgnored private var commandAcceptanceStarted = false
    private(set) var simulatedPairingReplyLoss = false
    private(set) var simulatedCommandReplyLoss = false
    private(set) var invitationReceiptAcceptanceStatus: String?
    @ObservationIgnored private var invitationReceiptAcceptanceStarted = false
    @ObservationIgnored private var invitationReceiptAcceptanceTask: Task<Void, Never>?
    @ObservationIgnored private var invitationReceiptActionID: UUID?
    @ObservationIgnored private var invitationReceiptCreatedID: UUID?
    private(set) var simulatedLifecycleRevalidationPause = false
    private(set) var lifecycleRevalidationPauseCount = 0
    @ObservationIgnored private var pauseNextLifecycleRevalidation = false
    @ObservationIgnored private var lifecycleRevalidationContinuation: CheckedContinuation<Void, Never>?
    private(set) var restoreCandidateCount = 0
    @ObservationIgnored private var didDropRenewalReply = false
    @ObservationIgnored private var didDropCreateReply = false
    @ObservationIgnored private var didDropJoinReply = false
    @ObservationIgnored private var didTriggerRestoreRace = false
    private(set) var simulatedRefreshDelay = false
    private(set) var overlappingRefreshAcceptanceResult: Bool?
    @ObservationIgnored private var delayNextRefreshForAcceptance = false
    @ObservationIgnored private var refreshContinuationForAcceptance: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var initialRevisionFloorForAcceptance: Int?
    #endif

    @ObservationIgnored private let coordinator = SharedStateCoordinator()
    @ObservationIgnored private var vault: AuthSessionVault?
    @ObservationIgnored private var client: SharedHTTPClient?
    @ObservationIgnored private var activeRefreshEpoch: UInt64?
    @ObservationIgnored private var foregroundRevalidationPending = false
    @ObservationIgnored private var foregroundEligible = UIApplication.shared.applicationState == .active
    private static var testPreferenceSuffix: String {
        #if SECONDLOOK_DEMO
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing") else { return "" }
        return arguments.contains("-shared-testing") ? ".shared-ui-test" : ".local-ui-test"
        #else
        return ""
        #endif
    }
    private static var selectedKey: String { "secondlook.connected.selected.v1" + testPreferenceSuffix }
    private static var configKey: String { "secondlook.connected.config.v1" + testPreferenceSuffix }

    init() {
        #if SECONDLOOK_DEMO
        let arguments = ProcessInfo.processInfo.arguments
        let resetForLocalUITest = arguments.contains("-ui-testing") && arguments.contains("-reset-demo")
        #else
        let resetForLocalUITest = false
        #endif
        if resetForLocalUITest {
            UserDefaults.standard.set(false, forKey: Self.selectedKey)
            selected = false
        } else {
            selected = UserDefaults.standard.bool(forKey: Self.selectedKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.configKey) {
            configuration = try? JSONDecoder().decode(ConnectedConfiguration.self, from: data)
        }
        #if SECONDLOOK_DEMO
        if arguments.contains("-ui-testing") && arguments.contains("-shared-testing") &&
            arguments.contains("-reset-demo") {
            if let configuration { try? ConnectedKeychain.delete(configuration: configuration) }
            let environment = ProcessInfo.processInfo.environment
            if let auth = environment["SECONDLOOK_TEST_AUTH_URL"].flatMap({ URL(string: $0) }),
               let server = environment["SECONDLOOK_TEST_SERVER_URL"].flatMap({ URL(string: $0) }) {
                let testConfiguration = ConnectedConfiguration(authURL: auth,
                    publishableKey: environment["SECONDLOOK_TEST_PUBLISHABLE_KEY"] ?? "",
                    serverURL: server)
                try? ConnectedKeychain.delete(configuration: testConfiguration)
            }
        }
        #endif
        if resetForLocalUITest {
            UserDefaults.standard.removeObject(forKey: Self.configKey)
            configuration = nil
        }
        if selected { Task { await restore() } }
    }

    var state: SecondLookState { snapshot?.state ?? heldSnapshot?.state ?? SecondLookState() }
    var isPaired: Bool { snapshot != nil }
    var peerJoined: Bool { snapshot?.members.count == 2 }
    var canConnect: Bool { configuration != nil }
    var canCreatePrivateSpace: Bool {
        guard accountID != nil, canUseForeground else { return false }
        return (snapshot == nil && confirmedNoSpace) ||
            (snapshot?.members.count == 1 && snapshot?.members.first == accountID)
    }
    var canJoinPrivateSpace: Bool { accountID != nil && canUseForeground && snapshot == nil && confirmedNoSpace }
    var openRuns: [ChecklistRun] { state.runs.filter(\.isOpen).sorted { $0.startedAt > $1.startedAt } }
    func run(_ id: UUID) -> ChecklistRun? { state.runs.first { $0.id == id } }
    func latestOpenRun(_ id: UUID) -> ChecklistRun? { openRuns.first { $0.routineID == id } }
    func personName(_ id: UUID) -> String { id == accountID ? "You" : "Other participant" }

    func activate() {
        selected = true
        UserDefaults.standard.set(true, forKey: Self.selectedKey)
        resetSession()
        Task { await restore() }
    }

    func useLocal() {
        selected = false
        UserDefaults.standard.set(false, forKey: Self.selectedKey)
        resetSession()
    }

    func setConfiguration(authURL: String, publishableKey: String, serverURL: String) throws {
        guard let auth = URL(string: authURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let server = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SharedStateFailure.invalidResponse
        }
        let next = ConnectedConfiguration(authURL: auth, publishableKey: publishableKey,
                                          serverURL: server)
        try next.validate(allowLocalHTTP: AuthSessionVault.localHTTPAllowed)
        if configuration != next {
            let oldConfiguration = configuration
            resetSession()
            if let oldConfiguration { try ConnectedKeychain.delete(configuration: oldConfiguration) }
            configuration = next
            UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: Self.configKey)
        }
    }

    func signIn(email: String, password: String) async {
        guard canUseForeground else { return }
        guard let configuration else { errorMessage = "Enter the connection settings first."; return }
        resetSession()
        let epoch = generation
        var pendingSessionID: UUID?
        defer {
            if let pendingSessionID, vault?.sessionID != pendingSessionID {
                ConnectedKeychain.end(configuration: configuration, sessionID: pendingSessionID)
            }
        }
        busy = true
        let auth = SharedAuthClient(authURL: configuration.authURL,
                                    publishableKey: configuration.publishableKey,
                                    allowLocalHTTP: AuthSessionVault.localHTTPAllowed)
        do {
            let response = try await auth.signIn(email: email, password: password)
            guard currentForegroundSession(epoch) else { return }
            let candidate = AuthSessionVault.fresh(response, configuration: configuration)
            pendingSessionID = candidate.sessionID
            ConnectedKeychain.bind(configuration: configuration, sessionID: candidate.sessionID)
            #if SECONDLOOK_DEMO
            if commandChecksRequested { try await candidate.verifyRefreshForAcceptance() }
            else { try await candidate.verify() }
            #else
            try await candidate.verify()
            #endif
            guard currentForegroundSession(epoch) else { return }
            try await candidate.persistVerifiedCredentials()
            guard currentForegroundSession(epoch) else { return }
            install(candidate, accountID: response.user.id, configuration: configuration)
            await discoverSpace(epoch: epoch)
        } catch {
            if currentForegroundSession(epoch) {
                status = "Could not authenticate this account."
                errorMessage = Self.safeMessage(error)
                busy = false
            }
        }
    }

    func restore() async {
        guard canUseForeground, selected, !busy, accountID == nil, let configuration else { return }
        let epoch = generation
        var pendingSessionID: UUID?
        defer {
            if let pendingSessionID, vault?.sessionID != pendingSessionID {
                ConnectedKeychain.end(configuration: configuration, sessionID: pendingSessionID)
            }
        }
        busy = true
        #if SECONDLOOK_DEMO
        if restoreRaceChecksRequested {
            restoreCandidateCount += 1
            if !didTriggerRestoreRace {
                didTriggerRestoreRace = true
                // Deliberately race genuine saved-session restores on the isolated local fixture.
                Task { await restore() }
                Task { await restore() }
            }
        }
        #endif
        do {
            guard let candidate = try ConnectedKeychain.restore(configuration: configuration) else {
                #if SECONDLOOK_DEMO
                if forbiddenRestoreChecksRequested { forbiddenRestoreCredentialStatus = "No saved credentials" }
                #endif
                if currentForegroundSession(epoch) { busy = false }
                return
            }
            pendingSessionID = candidate.sessionID
            ConnectedKeychain.bind(configuration: configuration, sessionID: candidate.sessionID)
            #if SECONDLOOK_DEMO
            if restoreRaceChecksRequested { try await candidate.verifyRefreshForAcceptance() }
            else { try await candidate.verify() }
            #else
            try await candidate.verify()
            #endif
            guard currentForegroundSession(epoch) else { return }
            #if SECONDLOOK_DEMO
            if forbiddenRestoreChecksRequested {
                simulatedForbiddenRestore = true
                throw SharedStateFailure.forbidden
            }
            #endif
            install(candidate, accountID: candidate.accountID, configuration: configuration)
            await discoverSpace(epoch: epoch)
        } catch {
            if currentForegroundSession(epoch) {
                if let failure = error as? SharedStateFailure,
                   failure == .unauthenticated || failure == .forbidden {
                    do { try ConnectedKeychain.delete(configuration: configuration) }
                    catch {
                        status = "Signed out. Saved session cleanup needs another attempt."
                        errorMessage = Self.safeMessage(error)
                        busy = false
                        return
                    }
                    status = "Sign in again to reconnect."
                } else if error as? ConnectedIdentityFailure == .secureSessionRemovalFailed {
                    status = "Signed out. Saved session cleanup needs another attempt."
                } else { status = "Could not reconnect. Try again when the service is available." }
                #if SECONDLOOK_DEMO
                if forbiddenRestoreChecksRequested {
                    forbiddenRestoreCredentialStatus = (try? ConnectedKeychain.restore(configuration: configuration)) == nil
                        ? "No saved credentials" : "Saved credentials remain"
                }
                #endif
                errorMessage = Self.safeMessage(error)
                busy = false
            }
        }
    }

    private func install(_ candidate: AuthSessionVault, accountID: UUID,
                         configuration: ConnectedConfiguration) {
        vault = candidate
        self.accountID = accountID
        client = SharedHTTPClient(serverURL: configuration.serverURL,
                                  bearerToken: { try await candidate.token() },
                                  allowLocalHTTP: AuthSessionVault.localHTTPAllowed)
    }

    private func discoverSpace(epoch: UInt64) async {
        guard let client, let accountID, let configuration else { return }
        confirmedNoSpace = false
        var membershipLookupReturnedSpace = false
        do {
            #if SECONDLOOK_DEMO
            let arguments = ProcessInfo.processInfo.arguments
            if !didSimulateMembershipFailure, arguments.contains("-ui-testing"),
               arguments.contains("-shared-testing"), arguments.contains("-shared-test-membership-failure") {
                didSimulateMembershipFailure = true
                simulatedMembershipFailure = true
                throw SharedStateFailure.serviceUnavailable
            }
            #endif
            let incoming = try await client.currentSpace()
            membershipLookupReturnedSpace = true
            guard currentForegroundSession(epoch) else { return }
            try await publishSpace(incoming, accountID: accountID, configuration: configuration,
                                   client: client, epoch: epoch)
            guard currentForegroundSession(epoch) else { return }
            busy = false
        } catch SharedStateFailure.notPaired {
            if currentForegroundSession(epoch) {
                purgeConnectedScope(confirmedAbsentFromLookup: !membershipLookupReturnedSpace)
            }
        } catch {
            if currentForegroundSession(epoch) {
                let message = Self.safeMessage(error)
                if !handleSessionOrScopeLoss(error) {
                    retryMembership = true
                    status = "Could not check private-space membership. Try again when connected."
                    errorMessage = message
                    busy = false
                }
            }
        }
    }

    func createSpace() async {
        guard canCreatePrivateSpace, !busy, let client, let accountID, let configuration else { return }
        let epoch = generation
        #if SECONDLOOK_DEMO
        let dropCreateReply = localRecoveryChecksRequested && snapshot == nil &&
            !didDropCreateReply && ProcessInfo.processInfo.arguments.contains("-shared-test-create-reply-loss")
        let dropRenewalReply = localRecoveryChecksRequested && invitation != nil && !didDropRenewalReply &&
            ProcessInfo.processInfo.arguments.contains("-shared-test-renewal-reply-loss")
        #endif
        confirmedNoSpace = false
        retryMembership = true
        // Once renewal starts, the server may rotate the old code even if its reply is lost.
        invitation = nil
        busy = true
        do {
            let result = try await client.createSpace(expectedSpaceRevision: snapshot?.revision)
            guard currentForegroundSession(epoch) else { return }
            #if SECONDLOOK_DEMO
            if dropCreateReply {
                didDropCreateReply = true
                simulatedPairingReplyLoss = true
                // The initial server create committed; only its decoded reply is discarded.
                throw SharedStateFailure.serviceUnavailable
            }
            if dropRenewalReply {
                didDropRenewalReply = true
                simulatedPairingReplyLoss = true
                // The server operation is genuine; discarding its decoded response is simulated.
                throw SharedStateFailure.serviceUnavailable
            }
            #endif
            try await publishSpace(result.snapshot, accountID: accountID,
                                   configuration: configuration, client: client, epoch: epoch)
            guard currentForegroundSession(epoch) else { return }
            // A concurrent fetch may have observed a newer rotation or join. Never
            // display this reply's token against a different published snapshot.
            invitation = snapshot == result.snapshot ? result : nil
            busy = false
            #if SECONDLOOK_DEMO
            startInvitationReceiptAcceptanceIfRequested()
            #endif
        } catch {
            if currentForegroundSession(epoch) {
                if !handleSessionOrScopeLoss(error) {
                    errorMessage = Self.safeMessage(error)
                    busy = false
                }
            }
        }
    }

    func joinSpace(token: String) async {
        guard canJoinPrivateSpace, !busy, let client, let accountID, let configuration else { return }
        let epoch = generation
        confirmedNoSpace = false
        retryMembership = true
        busy = true
        do {
            let result = try await client.joinSpace(inviteToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
            guard currentForegroundSession(epoch) else { return }
            #if SECONDLOOK_DEMO
            if localRecoveryChecksRequested, !didDropJoinReply,
               ProcessInfo.processInfo.arguments.contains("-shared-test-join-reply-loss") {
                didDropJoinReply = true
                simulatedPairingReplyLoss = true
                throw SharedStateFailure.serviceUnavailable
            }
            #endif
            try await publishSpace(result, accountID: accountID,
                                   configuration: configuration, client: client, epoch: epoch)
            guard currentForegroundSession(epoch) else { return }
            busy = false
        } catch {
            if currentForegroundSession(epoch) {
                if !handleSessionOrScopeLoss(error) {
                    status = "Could not confirm pairing. Checking membership before retrying."
                    errorMessage = Self.safeMessage(error)
                    busy = false
                }
            }
        }
    }

    private func publishSpace(_ incoming: SharedSnapshot, accountID: UUID,
                              configuration: ConnectedConfiguration,
                              client: SharedHTTPClient, epoch: UInt64) async throws {
        try incoming.validate(for: accountID)
        guard currentForegroundSession(epoch) else { throw SharedStateFailure.sessionChanged }
        let scope = SharedAccountScope(backend: configuration.backendID,
                                       accountID: accountID, spaceID: incoming.spaceID)
        if coordinator.scope == scope {
            // Renewing an invitation is a write to the same space. Fetch through
            // the existing coordinator so unknown command outcomes keep their
            // original envelopes and explicit retry IDs.
            let floor = max(snapshot?.revision ?? heldSnapshot?.revision ?? 0, incoming.revision)
            try await coordinator.refresh()
            guard currentForegroundSession(epoch) else { throw SharedStateFailure.sessionChanged }
            guard let refreshed = coordinator.snapshot, refreshed.revision >= floor else {
                throw SharedStateFailure.staleState
            }
            if refreshed.revision == incoming.revision && refreshed != incoming {
                throw SharedStateFailure.invalidResponse
            }
            snapshot = refreshed
            publishIssuedActionsAfterVerification()
        } else {
            let restoringSameScope = suspendedScope == scope
            #if SECONDLOOK_DEMO
            let coordinatorClient: any SharedStateClient
            if initialRevisionFloorChecksRequested && !restoringSameScope && incoming.revision > 0 {
                // The membership lookup above is genuine. Only the first two explicit-space
                // fetch responses are made to appear one revision behind for local acceptance.
                initialRevisionFloorForAcceptance = incoming.revision
                coordinatorClient = SharedLaggingInitialSnapshotClient(base: client,
                    initialRevision: incoming.revision)
            } else {
                coordinatorClient = client
            }
            #else
            let coordinatorClient: any SharedStateClient = client
            #endif
            coordinator.beginSession(scope: scope, client: coordinatorClient)
            if restoringSameScope {
                // Core retains only issued envelopes for this verified account/space.
                // Do not expose retry metadata until its fetch also succeeds.
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { throw SharedStateFailure.sessionChanged }
                guard let refreshed = coordinator.snapshot,
                      refreshed.revision >= max(heldSnapshot?.revision ?? 0, incoming.revision) else {
                    throw SharedStateFailure.staleState
                }
                if refreshed.revision == incoming.revision && refreshed != incoming {
                    throw SharedStateFailure.invalidResponse
                }
                snapshot = refreshed
                publishIssuedActionsAfterVerification()
            } else {
                if hasContentForPresentation { discardPresentation() }
                issuedActions = []
                creationCompletions = [:]
                unconfirmedActions = []
                suspendedSharedAlert = nil
                // The first authenticated space lookup is already validated and held only in memory.
                snapshot = incoming
            }
        }
        suspendedScope = nil
        confirmedNoSpace = false
        retryMembership = false
        status = snapshot?.members.count == 2 ? "Private space connected." : "Waiting for your invited reviewer."
        #if SECONDLOOK_DEMO
        simulatedMembershipFailure = false
        startCommandAcceptanceIfRequested()
        #endif
    }

    private func publishIssuedActionsAfterVerification() {
        issuedActions.removeAll {
            !coordinator.hasUnconfirmedCommand(commandID: $0.id) &&
                !coordinator.hasConfirmedReceipt(commandID: $0.id, command: $0.command)
        }
        unconfirmedActions = issuedActions
        restoreSuspendedSharedAlertIfVerified()
    }

    private func restoreSuspendedSharedAlertIfVerified() {
        guard let held = suspendedSharedAlert, errorMessage == nil else { return }
        guard errorSheetIDs.last == held.sheetID else {
            // A dismissed or replaced sheet cannot receive its previous alert.
            suspendedSharedAlert = nil
            return
        }
        guard
              let snapshot, snapshot.revision >= held.minimumRevision,
              coordinator.scope == held.scope,
              snapshot.spaceID == held.scope.spaceID,
              accountID == held.scope.accountID,
              configuration?.backendID == held.scope.backend else { return }
        if let actionID = held.retryActionID {
            guard unconfirmedActions.contains(where: { $0.id == actionID }),
                  coordinator.hasUnconfirmedCommand(commandID: actionID) ||
                    issuedActions.contains(where: {
                        $0.id == actionID && coordinator.hasConfirmedReceipt(
                            commandID: actionID, command: $0.command)
                    }) else {
                suspendedSharedAlert = nil
                return
            }
        }
        suspendedSharedAlert = nil
        errorMessage = held.message
        retryActionForError = held.retryActionID
    }

    #if SECONDLOOK_DEMO
    private var localRecoveryChecksRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains("-shared-testing"),
              let configuration else { return false }
        return [configuration.authURL, configuration.serverURL].allSatisfy {
            $0.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains($0.host ?? "")
        }
    }

    private var initialRevisionFloorChecksRequested: Bool {
        localRecoveryChecksRequested && ProcessInfo.processInfo.arguments.contains("-shared-test-initial-revision-floor")
    }

    func runSharedCleanupProbe() async {
        guard localRecoveryChecksRequested,
              ProcessInfo.processInfo.arguments.contains("-shared-test-cleanup-status"),
              canUseForeground, !busy, snapshot?.members.count == 2,
              let configuration, let vault, let accountID else { return }
        let epoch = generation
        busy = true
        sharedCleanupProbeStatus = nil
        var phase = "startStandard"
        do {
            try await coordinator.refresh()
            guard currentForegroundSession(epoch) else { return }
            for high in [false, true] {
                phase = high ? "startEvidence" : "startStandard"
                let item = RoutineItem(title: "Invented cleanup step", priority: high ? .high : .standard)
                let result = try await coordinator.execute(.startOneOff(
                    title: high ? "Cleanup status evidence synthetic" : "Cleanup status standard synthetic",
                    items: [item], settings: .init()))
                guard currentForegroundSession(epoch), let id = result,
                      let current = coordinator.snapshot,
                      var run = current.state.runs.first(where: { $0.id == id }),
                      let runItem = run.items.first else { throw SharedStateFailure.sessionChanged }
                if high {
                    phase = "submitMetadata"
                    let submitted = try await SharedSyntheticEvidenceTestClient.submit(
                        serverURL: configuration.serverURL, token: vault.token(), snapshot: current,
                        run: run, itemID: runItem.id, actorID: accountID)
                    guard currentForegroundSession(epoch) else { return }
                    phase = "fetchMetadata"
                    try await coordinator.refresh()
                    guard currentForegroundSession(epoch), let fetched = coordinator.snapshot,
                          fetched == submitted,
                          let refreshedRun = fetched.state.runs.first(where: { $0.id == id }) else {
                        throw SharedStateFailure.invalidResponse
                    }
                    run = refreshedRun
                }
                phase = high ? "cancelEvidence" : "cancelStandard"
                _ = try await coordinator.execute(.cancel(runID: run.id, expectedRunRevision: run.revision))
                guard currentForegroundSession(epoch), let closed = coordinator.snapshot,
                      closed.state.archives.contains(where: {
                          $0.id == id && $0.cleanupStatus == (high ? .pending : .notNeeded)
                      }) else { throw SharedStateFailure.invalidResponse }
                snapshot = closed
            }
            sharedCleanupProbeStatus = "Cleanup archive checks ready"
        } catch {
            if currentForegroundSession(epoch) { sharedCleanupProbeStatus = "Cleanup archive checks failed at " + phase }
        }
        if currentForegroundSession(epoch) { busy = false }
    }

    var draftLifecycleChecksRequested: Bool {
        localRecoveryChecksRequested &&
            ProcessInfo.processInfo.arguments.contains("-shared-test-draft-lifecycle")
    }

    func armDraftRevalidationPauseForAcceptance() {
        guard draftLifecycleChecksRequested, canUseForeground, !busy, snapshot != nil else { return }
        pauseNextDraftRevalidation = true
    }

    func resumeDraftRevalidationForAcceptance() {
        guard draftLifecycleChecksRequested, canUseForeground, simulatedDraftRevalidationPause else { return }
        let continuation = draftRevalidationContinuation
        draftRevalidationContinuation = nil
        simulatedDraftRevalidationPause = false
        continuation?.resume()
    }

    func prepareSharedReviewDraftProbe() async {
        guard draftLifecycleChecksRequested, canUseForeground, !busy,
              snapshot?.members.count == 2, let vault, let configuration, let accountID else { return }
        let epoch = generation
        busy = true
        sharedReviewDraftProbeStatus = nil
        do {
            try await coordinator.refresh()
            guard currentForegroundSession(epoch) else { return }
            let id = try await coordinator.execute(.startOneOff(title: "Review draft synthetic",
                items: [RoutineItem(title: "Synthetic review draft step", priority: .high)], settings: .init()))
            guard currentForegroundSession(epoch), let id, let current = coordinator.snapshot,
                  let run = current.state.runs.first(where: { $0.id == id }), let item = run.items.first else {
                throw SharedStateFailure.invalidResponse
            }
            let submitted = try await SharedSyntheticEvidenceTestClient.submit(
                serverURL: configuration.serverURL, token: vault.token(), snapshot: current,
                run: run, itemID: item.id, actorID: accountID)
            guard currentForegroundSession(epoch) else { return }
            try await coordinator.refresh()
            guard currentForegroundSession(epoch), coordinator.snapshot == submitted else {
                throw SharedStateFailure.invalidResponse
            }
            snapshot = submitted
            sharedReviewDraftProbeStatus = "Review draft checks ready"
        } catch {
            if currentForegroundSession(epoch) { sharedReviewDraftProbeStatus = "Review draft checks failed" }
        }
        if currentForegroundSession(epoch) { busy = false }
    }

    private var forbiddenRestoreChecksRequested: Bool {
        localRecoveryChecksRequested && ProcessInfo.processInfo.arguments.contains("-shared-test-forbidden-restore")
    }

    private func shouldDropCreationReceipt(_ command: SharedCommand) -> Bool {
        guard localRecoveryChecksRequested, !didDropCreationReply else { return false }
        let args = ProcessInfo.processInfo.arguments
        switch command {
        case .startOneOff:
            return args.contains("-shared-test-creation-receipt-one-off") ||
                args.contains("-shared-test-scope-loss-purge")
        case .saveRunAsRoutine: return args.contains("-shared-test-creation-receipt-save-as-routine")
        default: return false
        }
    }

    private func finishCreationReceiptAcceptance(_ receipt: ActionReceipt?, actionID: UUID, epoch: UInt64) {
        guard currentForegroundSession(epoch), actionID == creationReceiptActionID,
              let expected = creationReceiptCreatedID, let command = creationReceiptCommand,
              let snapshot else { return }
        guard receipt?.createdID == expected else {
            creationReceiptAcceptanceStatus = "Creation receipt checks failed: originalID"
            return
        }
        let single: Bool
        switch command {
        case .startOneOff(let title, _, _):
            let runs = snapshot.state.runs.filter { $0.title == title }
            single = runs.count == 1 && runs.first?.id == expected
        case .saveRunAsRoutine:
            single = snapshot.state.routines.count == 1 && snapshot.state.routines.first?.id == expected
        default: single = false
        }
        creationReceiptAcceptanceStatus = single ? "Creation receipt checks passed"
            : "Creation receipt checks failed: singleObject"
    }

    var restoreRaceChecksRequested: Bool {
        localRecoveryChecksRequested && ProcessInfo.processInfo.arguments.contains("-shared-test-restore-race")
    }

    var refreshDelayChecksRequested: Bool {
        localRecoveryChecksRequested && ProcessInfo.processInfo.arguments.contains("-shared-test-delayed-refresh")
    }

    var refreshMismatchChecksRequested: Bool {
        localRecoveryChecksRequested && ProcessInfo.processInfo.arguments.contains("-shared-test-refresh-account-mismatch")
    }

    func beginDelayedRefreshForAcceptance() {
        guard refreshDelayChecksRequested, canUseForeground, !busy, snapshot != nil else { return }
        overlappingRefreshAcceptanceResult = nil
        delayNextRefreshForAcceptance = true
        enqueue { _ = await self.refresh() }
    }

    func attemptOverlappingRefreshForAcceptance() async {
        guard refreshDelayChecksRequested, canUseForeground, simulatedRefreshDelay else { return }
        let epoch = generation
        let result = await refresh()
        guard currentForegroundSession(epoch) else { return }
        overlappingRefreshAcceptanceResult = result
    }

    func resumeRefreshForAcceptance() {
        let continuation = refreshContinuationForAcceptance
        refreshContinuationForAcceptance = nil
        simulatedRefreshDelay = false
        continuation?.resume()
    }

    func refreshWithMismatchedAccountForAcceptance() async {
        guard refreshMismatchChecksRequested, canUseForeground, !busy, let vault else { return }
        await vault.useMismatchedRefreshAccountForAcceptance()
        _ = await refresh()
    }

    var canInvalidateAccessForAcceptance: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains("-shared-testing"),
              arguments.contains("-shared-test-access-loss"), let configuration,
              snapshot?.members.count == 1, snapshot?.members.first == accountID else { return false }
        return [configuration.authURL, configuration.serverURL].allSatisfy {
            $0.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains($0.host ?? "")
        }
    }

    func invalidateAccessForAcceptance() async {
        guard canInvalidateAccessForAcceptance, canUseForeground, !busy, let vault else { return }
        let epoch = generation
        await vault.useInvalidAccessForAcceptance()
        guard currentForegroundSession(epoch) else { return }
        accessInvalidatedForAcceptance = true
    }

    private var commandChecksRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-ui-testing") && arguments.contains("-shared-testing") &&
            arguments.contains("-shared-command-checks")
    }

    private var invitationReceiptChecksRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return localRecoveryChecksRequested &&
            (arguments.contains("-shared-test-invitation-receipts") ||
             arguments.contains("-shared-test-lifecycle-receipt"))
    }

    var lifecycleReceiptChecksRequested: Bool {
        localRecoveryChecksRequested &&
            ProcessInfo.processInfo.arguments.contains("-shared-test-lifecycle-receipt")
    }

    func resumeLifecycleRevalidationForAcceptance() {
        guard lifecycleReceiptChecksRequested, simulatedLifecycleRevalidationPause,
              canUseForeground else { return }
        let continuation = lifecycleRevalidationContinuation
        lifecycleRevalidationContinuation = nil
        simulatedLifecycleRevalidationPause = false
        continuation?.resume()
    }

    private func startInvitationReceiptAcceptanceIfRequested() {
        guard invitationReceiptChecksRequested, !invitationReceiptAcceptanceStarted,
              let snapshot, snapshot.members.count == 1,
              snapshot.members.first == accountID,
              let client, let configuration, let accountID else { return }
        invitationReceiptAcceptanceStarted = true
        let epoch = generation
        invitationReceiptAcceptanceTask = Task { [weak self] in
            guard let self, self.currentForegroundSession(epoch) else { return }
            let actionID = UUID()
            let adapter = SharedInvitationReceiptLossClient(base: client, targetCommandID: actionID)
            let scope = SharedAccountScope(backend: configuration.backendID,
                                           accountID: accountID, spaceID: snapshot.spaceID)
            self.coordinator.beginSession(scope: scope, client: adapter)
            do {
                try await self.coordinator.refresh()
                guard !Task.isCancelled, self.currentForegroundSession(epoch),
                      let initial = self.coordinator.snapshot,
                      initial.revision >= snapshot.revision else { return }
                self.snapshot = initial
            } catch {
                self.failInvitationReceiptAcceptance("initialFetch", epoch: epoch)
                return
            }

            let command = SharedCommand.startOneOff(
                title: "Synthetic receipt preservation",
                items: [RoutineItem(title: "Invented checklist step")], settings: .init())
            let first = await self.execute(command, commandID: actionID)
            guard !Task.isCancelled, self.currentForegroundSession(epoch) else { return }
            guard first == nil,
                  self.coordinator.hasUnconfirmedCommand(commandID: actionID),
                  self.unconfirmedActions.contains(where: { $0.id == actionID }),
                  let createdID = await adapter.committedCreatedID() else {
                self.failInvitationReceiptAcceptance("lostReply", epoch: epoch)
                return
            }
            self.simulatedCommandReplyLoss = true
            guard await self.refresh(), !Task.isCancelled,
                  self.currentForegroundSession(epoch),
                  let beforeRenewal = self.snapshot else {
                self.failInvitationReceiptAcceptance("reconcile", epoch: epoch)
                return
            }
            if self.lifecycleReceiptChecksRequested {
                self.invitationReceiptActionID = actionID
                self.invitationReceiptCreatedID = createdID
                self.pauseNextLifecycleRevalidation = true
                self.invitationReceiptAcceptanceStatus = "Lifecycle receipt checks ready for background"
                return
            }
            await self.createSpace()
            guard !Task.isCancelled, self.currentForegroundSession(epoch),
                  let renewed = self.snapshot,
                  renewed.spaceID == beforeRenewal.spaceID,
                  renewed.revision >= beforeRenewal.revision + 1 else {
                self.failInvitationReceiptAcceptance("renewal", epoch: epoch)
                return
            }
            guard self.coordinator.hasUnconfirmedCommand(commandID: actionID),
                  self.unconfirmedActions.contains(where: { $0.id == actionID }),
                  self.canRetryUnconfirmedAction(actionID) else {
                self.failInvitationReceiptAcceptance("pendingAfterRenewal", epoch: epoch)
                return
            }
            self.invitationReceiptActionID = actionID
            self.invitationReceiptCreatedID = createdID
            self.invitationReceiptAcceptanceStatus = "Invitation receipt checks ready for retry"
        }
    }

    private func failInvitationReceiptAcceptance(_ step: String, epoch: UInt64) {
        guard !Task.isCancelled, currentForegroundSession(epoch) else { return }
        invitationReceiptAcceptanceStatus = "Invitation receipt checks failed: " + step
    }

    private func finishInvitationReceiptAcceptance(_ receipt: ActionReceipt?, actionID: UUID,
                                                   epoch: UInt64) async {
        guard currentForegroundSession(epoch), !Task.isCancelled,
              actionID == invitationReceiptActionID,
              let expectedID = invitationReceiptCreatedID else { return }
        guard receipt?.createdID == expectedID else {
            failInvitationReceiptAcceptance("originalReceipt", epoch: epoch)
            return
        }
        guard await refresh(), currentForegroundSession(epoch),
              let snapshot else {
            failInvitationReceiptAcceptance("finalRefresh", epoch: epoch)
            return
        }
        let matchingRuns = snapshot.state.runs.filter { $0.title == "Synthetic receipt preservation" }
        guard matchingRuns.count == 1, matchingRuns.first?.id == expectedID else {
            failInvitationReceiptAcceptance("singleRun", epoch: epoch)
            return
        }
        invitationReceiptAcceptanceStatus = lifecycleReceiptChecksRequested
            ? "Lifecycle receipt checks passed" : "Invitation receipt checks passed"
    }

    /// Explicit UI-test opt-in uses the installed account client; no credential is exported.
    private func startCommandAcceptanceIfRequested() {
        guard commandChecksRequested, !commandAcceptanceStarted,
              peerJoined, canUseForeground, let client, let vault, let accountID else { return }
        commandAcceptanceStarted = true
        let epoch = generation
        commandAcceptanceTask = Task { [weak self] in
            guard let self, self.currentForegroundSession(epoch) else { return }
            self.busy = true
            guard await vault.storedCredentialsMatchForAcceptance() else {
                guard !Task.isCancelled, self.currentForegroundSession(epoch) else { return }
                self.commandAcceptanceStatus = "Shared command checks failed: refreshedCredentialPersistence"
                self.busy = false
                return
            }
            do {
                try await vault.verifyRefreshForAcceptance()
            } catch {
                guard !Task.isCancelled, self.currentForegroundSession(epoch) else { return }
                self.commandAcceptanceStatus = "Shared command checks failed: sessionRefresh"
                self.busy = false
                return
            }
            let report = await SharedCommandAcceptanceChecks.run(client: client, accountID: accountID)
            guard !Task.isCancelled, self.currentForegroundSession(epoch) else { return }
            let refreshed = await self.refreshInstalledSpace()
            guard !Task.isCancelled, self.currentForegroundSession(epoch) else { return }
            self.commandAcceptanceStatus = !refreshed ? "Shared command checks failed: postRunRefresh" :
                report.allPassed ? "Shared command checks passed" :
                "Shared command checks failed: " + (report.firstFailedStepID?.rawValue ?? "incomplete")
            self.busy = false
        }
    }

    private func cancelCommandAcceptance() {
        commandAcceptanceTask?.cancel()
        commandAcceptanceTask = nil
        commandAcceptanceStatus = nil
    }
    #endif

    @discardableResult
    func refresh(quietly: Bool = false) async -> Bool {
        guard !busy else { return false }
        return await refreshInstalledSpace(quietly: quietly)
    }

    /// Foreground and command recovery already own busy; keep their refresh in that operation.
    @discardableResult
    private func refreshInstalledSpace(quietly: Bool = false) async -> Bool {
        guard canUseForeground, let client, let accountID, let configuration else { return false }
        let epoch = generation
        guard activeRefreshEpoch != epoch else { return false }
        activeRefreshEpoch = epoch
        defer { if activeRefreshEpoch == epoch { activeRefreshEpoch = nil } }
        confirmedNoSpace = false
        busy = true
        var membershipLookupReturnedSpace = false
        do {
            // A fresh membership lookup also catches a revoked or changed space.
            let incoming = try await client.currentSpace()
            membershipLookupReturnedSpace = true
            guard currentForegroundSession(epoch) else { return false }
            try incoming.validate(for: accountID)
            #if SECONDLOOK_DEMO
            if draftLifecycleChecksRequested && pauseNextDraftRevalidation {
                pauseNextDraftRevalidation = false
                if ProcessInfo.processInfo.arguments.contains("-shared-test-draft-access-loss") {
                    simulatedDraftAccessLoss = true
                    throw SharedStateFailure.forbidden
                }
                simulatedDraftRevalidationPause = true
                // Access was genuinely fetched. Only native publication is paused for XCTest.
                await withCheckedContinuation { draftRevalidationContinuation = $0 }
                guard currentForegroundSession(epoch) else { return false }
            }
            if lifecycleReceiptChecksRequested && pauseNextLifecycleRevalidation {
                pauseNextLifecycleRevalidation = false
                lifecycleRevalidationPauseCount += 1
                simulatedLifecycleRevalidationPause = true
                // Membership is genuinely fetched; only publication waits for XCTest.
                await withCheckedContinuation { lifecycleRevalidationContinuation = $0 }
                guard currentForegroundSession(epoch) else { return false }
            }
            if refreshDelayChecksRequested && delayNextRefreshForAcceptance {
                delayNextRefreshForAcceptance = false
                simulatedRefreshDelay = true
                // Authentication/membership were fetched genuinely; delaying publication is simulated.
                await withCheckedContinuation { refreshContinuationForAcceptance = $0 }
                guard currentForegroundSession(epoch) else { return false }
            }
            #endif
            if snapshot?.spaceID != incoming.spaceID {
                try await publishSpace(incoming, accountID: accountID,
                                       configuration: configuration, client: client, epoch: epoch)
                guard currentForegroundSession(epoch) else { return false }
            } else {
                let floor = max(snapshot?.revision ?? heldSnapshot?.revision ?? 0, incoming.revision)
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { return false }
                guard let refreshed = coordinator.snapshot, refreshed.revision >= floor else {
                    throw SharedStateFailure.staleState
                }
                snapshot = coordinator.snapshot
                publishIssuedActionsAfterVerification()
            }
            if snapshot?.members.count == 2 { invitation = nil }
            status = snapshot?.members.count == 2 ? "Private space connected." : "Waiting for your invited reviewer."
            retryMembership = false
            busy = false
            return true
        } catch SharedStateFailure.notPaired {
            if currentForegroundSession(epoch) {
                purgeConnectedScope(confirmedAbsentFromLookup: !membershipLookupReturnedSpace)
            }
        } catch {
            if currentForegroundSession(epoch) {
                let message = Self.safeMessage(error)
                if handleSessionOrScopeLoss(error) { return false }
                if quietly {
                    status = "Could not synchronize. Retrying when connected."
                    retryMembership = snapshot == nil
                } else {
                    retryMembership = snapshot == nil
                }
                #if SECONDLOOK_DEMO
                let awaitingFloorDiagnostic = initialRevisionFloorForAcceptance != nil &&
                    error as? SharedStateFailure == .staleState
                #else
                let awaitingFloorDiagnostic = false
                #endif
                if !quietly && !awaitingFloorDiagnostic { errorMessage = message }
                busy = false
            }
        }
        return false
    }

    /// Any transition away from the foreground invalidates in-flight publications, including
    /// sign-in before an account is installed and discovery before a snapshot is available.
    /// Installed credentials remain bound to this account for foreground revalidation.
    func holdForValidation() {
        #if SECONDLOOK_DEMO
        confirmedCreationConsumptionContinuation?.resume()
        confirmedCreationConsumptionContinuation = nil
        simulatedConfirmedCreationConsumptionPause = false
        if draftLifecycleChecksRequested && draftRevalidationContinuation != nil {
            pauseNextDraftRevalidation = true
        }
        draftRevalidationContinuation?.resume()
        draftRevalidationContinuation = nil
        simulatedDraftRevalidationPause = false
        resumeRefreshForAcceptance()
        if lifecycleReceiptChecksRequested && lifecycleRevalidationContinuation != nil {
            pauseNextLifecycleRevalidation = true
        }
        lifecycleRevalidationContinuation?.resume()
        lifecycleRevalidationContinuation = nil
        simulatedLifecycleRevalidationPause = false
        #endif
        let wasEligible = foregroundEligible
        foregroundEligible = false
        confirmedNoSpace = false
        guard selected, wasEligible else { return }
        #if SECONDLOOK_DEMO
        cancelCommandAcceptance()
        #endif
        generation &+= 1
        if accountID == nil {
            // A pre-install auth/restore task must not persist its response after this point.
            if busy, let configuration { ConnectedKeychain.clearBinding(configuration: configuration) }
            let interruptedSignIn = busy
            busy = false
            foregroundRevalidationPending = false
            retryMembership = false
            if interruptedSignIn { status = "Sign-in was interrupted. Reconnect when the app is active." }
            return
        }
        foregroundRevalidationPending = true
        retryMembership = true
        suspendedScope = coordinator.scope ?? suspendedScope
        if suspendedSharedAlert == nil, let scope = suspendedScope, let message = errorMessage {
            suspendedSharedAlert = SuspendedSharedAlert(
                scope: scope, minimumRevision: snapshot?.revision ?? heldSnapshot?.revision ?? 0,
                message: message, retryActionID: retryActionForError,
                sheetID: errorSheetIDs.last)
        }
        heldSnapshot = snapshot ?? heldSnapshot
        coordinator.suspendSession()
        unconfirmedActions = []
        snapshot = nil
        invitation = nil
        // Alerts live outside the protected-content gate, so hide the old alert too.
        errorMessage = nil
        status = "Checking private-space access…"
        busy = true
    }

    /// Only a synchronous lifecycle callback can re-arm connected work. A delayed SwiftUI task
    /// may revalidate, but cannot make an inactive app eligible to publish protected state.
    func markForegroundActive() {
        guard UIApplication.shared.applicationState == .active else { return }
        foregroundEligible = true
    }

    private var canUseForeground: Bool {
        foregroundEligible && UIApplication.shared.applicationState == .active
    }

    private func currentForegroundSession(_ epoch: UInt64) -> Bool {
        generation == epoch && selected && canUseForeground
    }

    /// Capture the session at the tap, before an unstructured task gets a chance to start.
    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let epoch = generation
        Task { [weak self] in
            guard let self, self.currentForegroundSession(epoch) else { return }
            await operation()
        }
    }

    func revalidateAfterActivation() async {
        guard selected, canUseForeground else { return }
        if accountID == nil {
            if !busy { await restore() }
            return
        }
        guard foregroundRevalidationPending else { return }
        foregroundRevalidationPending = false
        retryMembership = false
        await refreshInstalledSpace()
    }

    struct ActionReceipt { let createdID: UUID? }

    private struct CreationCompletion {
        let owner: UUID
        let presentationEpoch: UInt64
        let complete: @MainActor (ActionReceipt) -> Void
    }

    func registerCreationCompletion(commandID: UUID, owner: UUID,
                                    completion: @escaping @MainActor (ActionReceipt) -> Void) {
        guard canUseForeground, snapshot != nil else { return }
        creationCompletions[commandID] = CreationCompletion(owner: owner, presentationEpoch: presentationGeneration,
                                                           complete: completion)
    }

    func unregisterCreationCompletion(owner: UUID) {
        creationCompletions = creationCompletions.filter { $0.value.owner != owner }
    }

    private func unconfirmedCreation(owner: UUID) -> UnconfirmedAction? {
        unconfirmedActions.first { action in
            guard let completion = creationCompletions[action.id] else { return false }
            return completion.owner == owner && completion.presentationEpoch == presentationGeneration &&
                (coordinator.hasUnconfirmedCommand(commandID: action.id) ||
                 coordinator.hasConfirmedReceipt(commandID: action.id, command: action.command))
        }
    }

    func hasUnconfirmedCreation(owner: UUID) -> Bool {
        unconfirmedCreation(owner: owner) != nil
    }

    @discardableResult
    func retryCreationAction(owner: UUID) async -> ActionReceipt? {
        guard let action = unconfirmedCreation(owner: owner) else { return nil }
        return await retryUnconfirmedAction(action.id)
    }

    private func completeCreationFlow(_ receipt: ActionReceipt, commandID: UUID, epoch: UInt64) {
        guard currentForegroundSession(epoch), let completion = creationCompletions[commandID],
              completion.presentationEpoch == presentationGeneration else { return }
        creationCompletions.removeValue(forKey: commandID)
        completion.complete(receipt)
    }

    struct UnconfirmedAction: Identifiable {
        let id: UUID
        let command: SharedCommand
        var title: String {
            switch command {
            case .saveRoutine: return "Save routine"
            case .deleteRoutine: return "Delete routine"
            case .startRun, .startOneOff, .repeatRun: return "Start checklist"
            case .saveRunAsRoutine: return "Save checklist as routine"
            case .setStandardChecked(_, _, let checked, _): return checked ? "Check step" : "Uncheck step"
            case .updateRunSettings: return "Save checklist settings"
            case .cancel: return "Cancel checklist"
            case .approve: return "Approve submission"
            case .requestAnother: return "Request another submission"
            case .withdraw: return "Withdraw submission"
            }
        }
    }

    func canRetryUnconfirmedAction(_ id: UUID) -> Bool {
        canUseForeground && !busy && snapshot != nil &&
            unconfirmedActions.contains(where: { $0.id == id }) &&
            (coordinator.hasUnconfirmedCommand(commandID: id) ||
             unconfirmedActions.contains(where: {
                 $0.id == id && coordinator.hasConfirmedReceipt(commandID: id, command: $0.command)
             }))
    }

    @discardableResult
    func retryUnconfirmedAction(_ id: UUID) async -> ActionReceipt? {
        guard canRetryUnconfirmedAction(id),
              let action = unconfirmedActions.first(where: { $0.id == id }) else { return nil }
        errorMessage = nil
        let epoch = generation
        let receipt: ActionReceipt?
        if let confirmed = coordinator.takeConfirmedReceipt(commandID: action.id,
                                                              command: action.command) {
            // The verified, exact-scope receipt is local. Never send this command again.
            issuedActions.removeAll { $0.id == id }
            unconfirmedActions.removeAll { $0.id == id }
            snapshot = coordinator.snapshot
            let accepted = ActionReceipt(createdID: confirmed.createdID)
            completeCreationFlow(accepted, commandID: id, epoch: epoch)
            receipt = accepted
        } else {
            receipt = await execute(action.command, commandID: action.id)
        }
        #if SECONDLOOK_DEMO
        finishCreationReceiptAcceptance(receipt, actionID: id, epoch: epoch)
        if invitationReceiptChecksRequested && id == invitationReceiptActionID {
            await finishInvitationReceiptAcceptance(receipt, actionID: id, epoch: epoch)
        }
        #endif
        return receipt
    }

    @discardableResult
    func execute(_ command: SharedCommand, commandID: UUID = UUID()) async -> ActionReceipt? {
        guard canUseForeground else { return nil }
        guard !busy else {
            errorMessage = "Still synchronizing. Wait a moment and try again."
            return nil
        }
        guard snapshot != nil else { errorMessage = "Refresh this private space before changing it."; return nil }
        let epoch = generation
        busy = true
        defer { if currentForegroundSession(epoch) { busy = false } }
        do {
            // Coordinator owns exact space revision, actor scope, and response publication.
            if coordinator.snapshot != snapshot {
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { return nil }
                guard let refreshed = coordinator.snapshot, let visible = snapshot else {
                    throw SharedStateFailure.staleState
                }
                guard refreshed.revision >= visible.revision else {
                    // The genuine membership snapshot may be newer than the first
                    // explicit-space fetch. Keep it visible and retry from its floor.
                    throw SharedStateFailure.staleState
                }
                if refreshed.revision == visible.revision && refreshed != visible {
                    throw SharedStateFailure.invalidResponse
                }
                guard refreshed == visible else {
                    snapshot = refreshed
                    throw SharedStateFailure.staleState
                }
            }
            #if SECONDLOOK_DEMO
            if shouldDropCreationReceipt(command), let client, let configuration, let accountID,
               let snapshot {
                let adapter = SharedInvitationReceiptLossClient(base: client, targetCommandID: commandID)
                coordinator.beginSession(scope: SharedAccountScope(backend: configuration.backendID,
                    accountID: accountID, spaceID: snapshot.spaceID), client: adapter)
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { return nil }
                guard coordinator.snapshot == snapshot else { throw SharedStateFailure.staleState }
                didDropCreationReply = true
                creationReceiptActionID = commandID
                creationReceiptCommand = command
                creationReceiptLossClient = adapter
            }
            #endif
            if !issuedActions.contains(where: { $0.id == commandID }) {
                issuedActions.append(UnconfirmedAction(id: commandID, command: command))
            }
            #if SECONDLOOK_DEMO
            if localRecoveryChecksRequested,
               ProcessInfo.processInfo.arguments.contains("-shared-test-scope-loss-purge"),
               didDropCreationReply, scopeLossActionID == nil,
               case .saveRoutine = command, let adapter = creationReceiptLossClient {
                scopeLossActionID = commandID
                await adapter.armScopeLoss(afterCommittedCommandID: commandID)
                guard currentForegroundSession(epoch) else { return nil }
            }
            #endif
            let created = try await coordinator.execute(command, commandID: commandID)
            #if SECONDLOOK_DEMO
            if localRecoveryChecksRequested,
               ProcessInfo.processInfo.arguments.contains("-shared-test-confirmed-consumption-suspend"),
               !didPauseConfirmedCreationConsumption,
               case .startOneOff = command {
                didPauseConfirmedCreationConsumption = true
                creationReceiptActionID = commandID
                creationReceiptCreatedID = created
                creationReceiptCommand = command
                simulatedConfirmedCreationConsumptionPause = true
                // The service and coordinator confirmed the command. Only model consumption
                // waits here for the native foreground acceptance case.
                await withCheckedContinuation { confirmedCreationConsumptionContinuation = $0 }
                simulatedConfirmedCreationConsumptionPause = false
            }
            #endif
            guard currentForegroundSession(epoch) else { return nil }
            guard let confirmed = coordinator.takeConfirmedReceipt(commandID: commandID,
                                                                    command: command) else {
                throw SharedStateFailure.invalidResponse
            }
            issuedActions.removeAll { $0.id == commandID }
            unconfirmedActions.removeAll { $0.id == commandID }
            snapshot = coordinator.snapshot
            let receipt = ActionReceipt(createdID: confirmed.createdID)
            completeCreationFlow(receipt, commandID: commandID, epoch: epoch)
            return receipt
        } catch {
            if currentForegroundSession(epoch) {
                #if SECONDLOOK_DEMO
                if commandID == scopeLossActionID,
                   error as? SharedStateFailure == .notPaired {
                    simulatedCommandScopeLoss = true
                }
                #endif
                if handleSessionOrScopeLoss(error) { return nil }
                let keepVerifiedSnapshot: Bool
                if let visible = snapshot, let fetched = coordinator.snapshot,
                   fetched.spaceID == visible.spaceID {
                    keepVerifiedSnapshot = fetched.revision < visible.revision ||
                        (fetched.revision == visible.revision && fetched != visible)
                } else {
                    keepVerifiedSnapshot = false
                }
                if !keepVerifiedSnapshot {
                    snapshot = coordinator.snapshot
                }
                let unconfirmed = coordinator.hasUnconfirmedCommand(commandID: commandID) ||
                    coordinator.hasConfirmedReceipt(commandID: commandID, command: command)
                if unconfirmed && !unconfirmedActions.contains(where: { $0.id == commandID }) {
                    unconfirmedActions.append(UnconfirmedAction(id: commandID, command: command))
                } else if !unconfirmed {
                    creationCompletions.removeValue(forKey: commandID)
                    issuedActions.removeAll { $0.id == commandID }
                    unconfirmedActions.removeAll { $0.id == commandID }
                }
                #if SECONDLOOK_DEMO
                if unconfirmed, commandID == creationReceiptActionID, let adapter = creationReceiptLossClient {
                    let committedID = await adapter.committedCreatedID()
                    guard currentForegroundSession(epoch) else { return nil }
                    creationReceiptCreatedID = committedID
                    simulatedCreationReplyLoss = true
                }
                #endif
                let message = unconfirmed
                    ? "Could not confirm this action. Use Retry this action to check its original result."
                    : Self.safeMessage(error)
                #if SECONDLOOK_DEMO
                let awaitingFloorDiagnostic = initialRevisionFloorForAcceptance != nil &&
                    error as? SharedStateFailure == .staleState
                #else
                let awaitingFloorDiagnostic = false
                #endif
                if !awaitingFloorDiagnostic { errorMessage = message }
                if unconfirmed { retryActionForError = commandID }
                if error as? SharedStateFailure == .staleState {
                    await refreshInstalledSpace()
                    #if SECONDLOOK_DEMO
                    if let initialRevisionFloorForAcceptance,
                       currentForegroundSession(epoch) {
                        // The diagnostic reflects the final model state even if the
                        // automatic genuine membership refresh happened to succeed.
                        let diagnostic = "Simulated lagging explicit-space response: visible revision \(snapshot?.revision ?? -1), genuine membership revision \(initialRevisionFloorForAcceptance)"
                        status = diagnostic
                        errorMessage = diagnostic
                    }
                    #endif
                }
            }
            return nil
        }
    }

    /// Call only after the response's foreground/session epoch was checked.
    /// Membership or scope loss drops connected presentation, but keeps verified
    /// Auth credentials installed until a genuine membership lookup runs again.
    @discardableResult
    private func handleSessionOrScopeLoss(_ error: Error) -> Bool {
        guard let failure = error as? SharedStateFailure else { return false }
        switch failure {
        case .unauthenticated, .forbidden:
            signOut()
            if errorMessage == nil { errorMessage = Self.safeMessage(error) }
            return true
        case .notPaired, .scopeMismatch:
            purgeConnectedScope(confirmedAbsentFromLookup: false)
            return true
        default:
            return false
        }
    }

    func signOut() {
        let oldConfiguration = configuration
        resetSession()
        if let oldConfiguration {
            do { try ConnectedKeychain.delete(configuration: oldConfiguration) }
            catch {
                status = "Signed out. Saved session cleanup needs another attempt."
                errorMessage = Self.safeMessage(error)
            }
        }
    }

    private func purgeConnectedScope(confirmedAbsentFromLookup: Bool) {
        // Invalidate every in-flight model continuation before changing any
        // presentation. The Auth vault/client remain installed for revalidation.
        generation &+= 1
        activeRefreshEpoch = nil
        foregroundRevalidationPending = false
        coordinator.endSession()
        discardPresentation()
        issuedActions = []
        unconfirmedActions = []
        suspendedScope = nil
        suspendedSharedAlert = nil
        snapshot = nil
        invitation = nil
        errorSheetIDs = []
        errorMessage = nil
        retryActionForError = nil
        confirmedNoSpace = confirmedAbsentFromLookup
        retryMembership = !confirmedAbsentFromLookup
        status = confirmedAbsentFromLookup
            ? "Signed in. Create a private space or enter an invitation."
            : "Private-space access changed. Check membership to continue."
        busy = false
        #if SECONDLOOK_DEMO
        cancelCommandAcceptance()
        invitationReceiptAcceptanceTask?.cancel()
        invitationReceiptAcceptanceTask = nil
        invitationReceiptAcceptanceStarted = false
        invitationReceiptAcceptanceStatus = nil
        invitationReceiptActionID = nil
        invitationReceiptCreatedID = nil
        draftRevalidationContinuation?.resume()
        draftRevalidationContinuation = nil
        pauseNextDraftRevalidation = false
        simulatedDraftRevalidationPause = false
        sharedReviewDraftProbeStatus = nil
        sharedCleanupProbeStatus = nil
        lifecycleRevalidationContinuation?.resume()
        lifecycleRevalidationContinuation = nil
        pauseNextLifecycleRevalidation = false
        simulatedLifecycleRevalidationPause = false
        resumeRefreshForAcceptance()
        delayNextRefreshForAcceptance = false
        initialRevisionFloorForAcceptance = nil
        confirmedCreationConsumptionContinuation?.resume()
        confirmedCreationConsumptionContinuation = nil
        simulatedConfirmedCreationConsumptionPause = false
        creationReceiptAcceptanceStatus = nil
        creationReceiptActionID = nil
        creationReceiptCreatedID = nil
        creationReceiptCommand = nil
        creationReceiptLossClient = nil
        scopeLossActionID = nil
        simulatedCreationReplyLoss = false
        simulatedCommandReplyLoss = false
        simulatedPairingReplyLoss = false
        #endif
    }

    private func discardPresentation() {
        heldSnapshot = nil
        presentationGeneration &+= 1
        creationCompletions = [:]
    }

    private func resetSession() {
        discardPresentation()
        #if SECONDLOOK_DEMO
        sharedCleanupProbeStatus = nil
        sharedReviewDraftProbeStatus = nil
        draftRevalidationContinuation?.resume()
        draftRevalidationContinuation = nil
        pauseNextDraftRevalidation = false
        simulatedDraftRevalidationPause = false
        simulatedDraftAccessLoss = false
        cancelCommandAcceptance()
        commandAcceptanceStarted = false
        accessInvalidatedForAcceptance = false
        simulatedMembershipFailure = false
        simulatedForbiddenRestore = false
        forbiddenRestoreCredentialStatus = nil
        simulatedCreationReplyLoss = false
        simulatedCommandScopeLoss = false
        confirmedCreationConsumptionContinuation?.resume()
        confirmedCreationConsumptionContinuation = nil
        simulatedConfirmedCreationConsumptionPause = false
        didPauseConfirmedCreationConsumption = false
        creationReceiptAcceptanceStatus = nil
        creationReceiptActionID = nil
        creationReceiptCreatedID = nil
        creationReceiptCommand = nil
        creationReceiptLossClient = nil
        scopeLossActionID = nil
        didDropCreationReply = false
        didSimulateMembershipFailure = false
        simulatedPairingReplyLoss = false
        invitationReceiptAcceptanceTask?.cancel()
        invitationReceiptAcceptanceTask = nil
        invitationReceiptAcceptanceStarted = false
        invitationReceiptAcceptanceStatus = nil
        invitationReceiptActionID = nil
        invitationReceiptCreatedID = nil
        simulatedCommandReplyLoss = false
        lifecycleRevalidationContinuation?.resume()
        lifecycleRevalidationContinuation = nil
        simulatedLifecycleRevalidationPause = false
        pauseNextLifecycleRevalidation = false
        lifecycleRevalidationPauseCount = 0
        resumeRefreshForAcceptance()
        delayNextRefreshForAcceptance = false
        initialRevisionFloorForAcceptance = nil
        restoreCandidateCount = 0
        didDropRenewalReply = false
        didDropCreateReply = false
        didDropJoinReply = false
        didTriggerRestoreRace = false
        #endif
        generation &+= 1
        foregroundRevalidationPending = false
        retryMembership = false
        confirmedNoSpace = false
        if let configuration { ConnectedKeychain.clearBinding(configuration: configuration) }
        if let vault { Task { await vault.invalidate() } }
        coordinator.endSession()
        creationCompletions = [:]
        issuedActions = []
        suspendedScope = nil
        suspendedSharedAlert = nil
        unconfirmedActions = []
        vault = nil; client = nil; accountID = nil; snapshot = nil; invitation = nil
        busy = false; errorMessage = nil
        status = "Sign in to connect a private space."
    }

    static func safeMessage(_ error: Error) -> String {
        if let failure = error as? SharedAuthFailure {
            switch failure {
            case .invalidCredentials:
                return "Email or password is incorrect. Check both and try again."
            }
        }
        if let failure = error as? ConnectedIdentityFailure {
            switch failure {
            case .secureStorageUnavailable:
                return "Secure session storage is unavailable on this device."
            case .secureSessionRemovalFailed:
                return "You are signed out. This device could not clear its saved session. Reopen the app to retry cleanup."
            }
        }
        guard let failure = error as? SharedStateFailure else {
            return "Connection failed. Check the service and try again."
        }
        switch failure {
        case .unauthenticated: return "Sign in again to continue."
        case .forbidden: return "This account does not have access to that private space."
        case .notPaired: return "This account is not paired yet."
        case .invalidInvite: return "This invitation is invalid or has expired."
        case .pairingUnavailable: return "This private space cannot accept another account."
        case .staleState: return "The shared list changed. It has been refreshed; review it before trying again."
        case .scopeMismatch, .sessionChanged: return "The account changed. Reopen the current space."
        case .invalidResponse: return "The service returned an unexpected response. No local change was saved."
        case .serviceUnavailable: return "The service is unavailable. Try again when connected."
        case .domain(.reviewerRequired): return "Invite the other account before starting a high-priority run."
        case .domain(let error): return AppModel.message(error)
        }
    }
}

#if SECONDLOOK_DEMO
/// Localhost UI acceptance only. Each fetch checks the real server first; the
/// first two decoded explicit-space snapshots then report a simulated older revision.
private actor SharedLaggingInitialSnapshotClient: SharedStateClient {
    let base: SharedHTTPClient
    let initialRevision: Int
    var laggingResponsesRemaining = 2

    init(base: SharedHTTPClient, initialRevision: Int) {
        self.base = base
        self.initialRevision = initialRevision
    }

    func fetch(spaceID: UUID) async throws -> SharedSnapshot {
        var genuine = try await base.fetch(spaceID: spaceID)
        if laggingResponsesRemaining > 0 && genuine.revision >= initialRevision {
            laggingResponsesRemaining -= 1
            genuine.revision = initialRevision - 1
        }
        return genuine
    }

    func execute(_ envelope: SharedCommandEnvelope) async throws -> SharedCommandResult {
        try await base.execute(envelope)
    }
}
#endif

import Foundation
import Observation
import SecondLookCore
import UIKit

@MainActor @Observable
final class ConnectedAppModel {
    private(set) var selected: Bool
    private(set) var configuration: ConnectedConfiguration?
    private(set) var generation: UInt64 = 0
    private(set) var accountID: UUID?
    private(set) var snapshot: SharedSnapshot?
    private(set) var invitation: PairingInvitation?
    private(set) var retryMembership = false
    private(set) var confirmedNoSpace = false
    private(set) var status = "Sign in to connect a private space."
    var errorMessage: String? {
        didSet { retryActionForError = nil }
    }
    private(set) var retryActionForError: UUID?
    private(set) var unconfirmedActions: [UnconfirmedAction] = []
    var busy = false

    #if SECONDLOOK_DEMO
    private(set) var commandAcceptanceStatus: String?
    private(set) var accessInvalidatedForAcceptance = false
    private(set) var simulatedMembershipFailure = false
    @ObservationIgnored private var didSimulateMembershipFailure = false
    @ObservationIgnored private var commandAcceptanceTask: Task<Void, Never>?
    @ObservationIgnored private var commandAcceptanceStarted = false
    private(set) var simulatedPairingReplyLoss = false
    private(set) var restoreCandidateCount = 0
    @ObservationIgnored private var didDropRenewalReply = false
    @ObservationIgnored private var didDropJoinReply = false
    @ObservationIgnored private var didTriggerRestoreRace = false
    #endif

    @ObservationIgnored private let coordinator = SharedStateCoordinator()
    @ObservationIgnored private var vault: AuthSessionVault?
    @ObservationIgnored private var client: SharedHTTPClient?
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

    var state: SecondLookState { snapshot?.state ?? SecondLookState() }
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
        guard canUseForeground, selected, accountID == nil, let configuration else { return }
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
            install(candidate, accountID: candidate.accountID, configuration: configuration)
            await discoverSpace(epoch: epoch)
        } catch {
            if currentForegroundSession(epoch) {
                if error as? SharedStateFailure == .unauthenticated {
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
            guard currentForegroundSession(epoch) else { return }
            try publishSpace(incoming, accountID: accountID, configuration: configuration,
                             client: client)
            busy = false
        } catch SharedStateFailure.notPaired {
            if currentForegroundSession(epoch) {
                coordinator.endSession()
                unconfirmedActions = []
                snapshot = nil
                invitation = nil
                confirmedNoSpace = true
                status = "Signed in. Create a private space or enter an invitation."
                busy = false
            }
        } catch {
            if currentForegroundSession(epoch) {
                let message = Self.safeMessage(error)
                if !clearSessionIfAccessLost(error) {
                    retryMembership = true
                    status = "Could not check private-space membership. Try again when connected."
                    errorMessage = message
                }
                busy = false
            }
        }
    }

    func createSpace() async {
        guard canCreatePrivateSpace, !busy, let client, let accountID, let configuration else { return }
        let epoch = generation
        #if SECONDLOOK_DEMO
        let dropRenewalReply = localRecoveryChecksRequested && invitation != nil && !didDropRenewalReply &&
            ProcessInfo.processInfo.arguments.contains("-shared-test-renewal-reply-loss")
        #endif
        // Once renewal starts, the server may rotate the old code even if its reply is lost.
        invitation = nil
        busy = true
        do {
            let result = try await client.createSpace()
            guard currentForegroundSession(epoch) else { return }
            #if SECONDLOOK_DEMO
            if dropRenewalReply {
                didDropRenewalReply = true
                simulatedPairingReplyLoss = true
                // The server operation is genuine; discarding its decoded response is simulated.
                throw SharedStateFailure.serviceUnavailable
            }
            #endif
            try publishSpace(result.snapshot, accountID: accountID,
                             configuration: configuration, client: client)
            invitation = result
            busy = false
        } catch {
            if currentForegroundSession(epoch) {
                if !clearSessionIfAccessLost(error) { errorMessage = Self.safeMessage(error) }
                busy = false
            }
        }
    }

    func joinSpace(token: String) async {
        guard canJoinPrivateSpace, !busy, let client, let accountID, let configuration else { return }
        let epoch = generation
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
            try publishSpace(result, accountID: accountID, configuration: configuration, client: client)
            busy = false
        } catch {
            if currentForegroundSession(epoch) {
                if !clearSessionIfAccessLost(error) { errorMessage = Self.safeMessage(error) }
                busy = false
            }
        }
    }

    private func publishSpace(_ incoming: SharedSnapshot, accountID: UUID,
                              configuration: ConnectedConfiguration,
                              client: SharedHTTPClient) throws {
        try incoming.validate(for: accountID)
        if let snapshot, snapshot.spaceID == incoming.spaceID {
            guard incoming.revision >= snapshot.revision,
                  incoming.revision != snapshot.revision || incoming == snapshot else {
                throw SharedStateFailure.staleState
            }
        }
        coordinator.beginSession(scope: SharedAccountScope(backend: configuration.backendID,
                                                            accountID: accountID,
                                                            spaceID: incoming.spaceID), client: client)
        unconfirmedActions = []
        // The first authenticated space lookup is already validated and held only in memory.
        snapshot = incoming
        confirmedNoSpace = false
        retryMembership = false
        status = incoming.members.count == 2 ? "Private space connected." : "Waiting for your invited reviewer."
        #if SECONDLOOK_DEMO
        simulatedMembershipFailure = false
        startCommandAcceptanceIfRequested()
        #endif
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

    var restoreRaceChecksRequested: Bool {
        localRecoveryChecksRequested && ProcessInfo.processInfo.arguments.contains("-shared-test-restore-race")
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
            let refreshed = await self.refresh()
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
        guard canUseForeground, let client, let accountID, let configuration else { return false }
        let epoch = generation
        confirmedNoSpace = false
        busy = true
        do {
            // A fresh membership lookup also catches a revoked or changed space.
            let incoming = try await client.currentSpace()
            guard currentForegroundSession(epoch) else { return false }
            try incoming.validate(for: accountID)
            if snapshot?.spaceID != incoming.spaceID {
                try publishSpace(incoming, accountID: accountID,
                                 configuration: configuration, client: client)
            } else {
                let floor = max(snapshot?.revision ?? 0, incoming.revision)
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { return false }
                guard let refreshed = coordinator.snapshot, refreshed.revision >= floor else {
                    throw SharedStateFailure.staleState
                }
                snapshot = coordinator.snapshot
            }
            if snapshot?.members.count == 2 { invitation = nil }
            status = snapshot?.members.count == 2 ? "Private space connected." : "Waiting for your invited reviewer."
            retryMembership = false
            busy = false
            return true
        } catch SharedStateFailure.notPaired {
            if currentForegroundSession(epoch) {
                coordinator.endSession(); snapshot = nil; invitation = nil
                confirmedNoSpace = true
                retryMembership = false
                status = "This account is no longer paired."
                busy = false
            }
        } catch {
            if currentForegroundSession(epoch) {
                let message = Self.safeMessage(error)
                let accessLost = clearSessionIfAccessLost(error)
                if !accessLost && quietly {
                    status = "Could not synchronize. Retrying when connected."
                    retryMembership = snapshot == nil
                } else if !accessLost {
                    retryMembership = snapshot == nil
                }
                if !quietly && !accessLost { errorMessage = message }
                busy = false
            }
        }
        return false
    }

    /// Any transition away from the foreground invalidates in-flight publications, including
    /// sign-in before an account is installed and discovery before a snapshot is available.
    /// Installed credentials remain bound to this account for foreground revalidation.
    func holdForValidation() {
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
        coordinator.endSession()
        unconfirmedActions = []
        snapshot = nil
        invitation = nil
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
        await refresh()
    }

    struct ActionReceipt { let createdID: UUID? }

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
        canUseForeground && !busy && snapshot != nil && coordinator.hasUnconfirmedCommand(commandID: id)
    }

    @discardableResult
    func retryUnconfirmedAction(_ id: UUID) async -> ActionReceipt? {
        guard canRetryUnconfirmedAction(id),
              let action = unconfirmedActions.first(where: { $0.id == id }) else { return nil }
        errorMessage = nil
        return await execute(action.command, commandID: action.id)
    }

    @discardableResult
    func execute(_ command: SharedCommand, commandID: UUID = UUID()) async -> ActionReceipt? {
        guard canUseForeground, !busy else { return nil }
        guard snapshot != nil else { errorMessage = "Refresh this private space before changing it."; return nil }
        let epoch = generation
        busy = true
        defer { if currentForegroundSession(epoch) { busy = false } }
        do {
            // Coordinator owns exact space revision, actor scope, and response publication.
            if coordinator.snapshot == nil {
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { return nil }
                guard coordinator.snapshot == snapshot else {
                    snapshot = coordinator.snapshot
                    throw SharedStateFailure.staleState
                }
            }
            let created = try await coordinator.execute(command, commandID: commandID)
            guard currentForegroundSession(epoch) else { return nil }
            unconfirmedActions.removeAll { $0.id == commandID }
            snapshot = coordinator.snapshot
            return ActionReceipt(createdID: created)
        } catch {
            if currentForegroundSession(epoch) {
                snapshot = coordinator.snapshot
                let unconfirmed = coordinator.hasUnconfirmedCommand(commandID: commandID)
                if unconfirmed && !unconfirmedActions.contains(where: { $0.id == commandID }) {
                    unconfirmedActions.append(UnconfirmedAction(id: commandID, command: command))
                } else if !unconfirmed {
                    unconfirmedActions.removeAll { $0.id == commandID }
                }
                let message = unconfirmed
                    ? "Could not confirm this action. Use Retry this action to check its original result."
                    : Self.safeMessage(error)
                if !clearSessionIfAccessLost(error) {
                    errorMessage = message
                    if unconfirmed { retryActionForError = commandID }
                }
                if error as? SharedStateFailure == .staleState { await refresh() }
            }
            return nil
        }
    }

    /// Call only after the response's foreground/session epoch was checked.
    /// Domain command denials do not change the authenticated identity.
    @discardableResult
    private func clearSessionIfAccessLost(_ error: Error) -> Bool {
        guard let failure = error as? SharedStateFailure,
              failure == .unauthenticated || failure == .forbidden else { return false }
        signOut()
        if errorMessage == nil { errorMessage = Self.safeMessage(error) }
        return true
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

    private func resetSession() {
        #if SECONDLOOK_DEMO
        cancelCommandAcceptance()
        commandAcceptanceStarted = false
        accessInvalidatedForAcceptance = false
        simulatedMembershipFailure = false
        didSimulateMembershipFailure = false
        simulatedPairingReplyLoss = false
        restoreCandidateCount = 0
        didDropRenewalReply = false
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

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
    private(set) var status = "Sign in to connect a private space."
    var errorMessage: String?
    var busy = false

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
            if let configuration { ConnectedKeychain.delete(configuration: configuration) }
            let environment = ProcessInfo.processInfo.environment
            if let auth = environment["SECONDLOOK_TEST_AUTH_URL"].flatMap({ URL(string: $0) }),
               let server = environment["SECONDLOOK_TEST_SERVER_URL"].flatMap({ URL(string: $0) }) {
                let testConfiguration = ConnectedConfiguration(authURL: auth,
                    publishableKey: environment["SECONDLOOK_TEST_PUBLISHABLE_KEY"] ?? "",
                    serverURL: server)
                ConnectedKeychain.delete(configuration: testConfiguration)
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
            if let oldConfiguration { ConnectedKeychain.delete(configuration: oldConfiguration) }
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
            try await candidate.verify()
            guard currentForegroundSession(epoch) else { return }
            try ConnectedKeychain.save(response, configuration: configuration,
                                       sessionID: candidate.sessionID)
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
        do {
            guard let candidate = try ConnectedKeychain.restore(configuration: configuration) else {
                if currentForegroundSession(epoch) { busy = false }
                return
            }
            pendingSessionID = candidate.sessionID
            ConnectedKeychain.bind(configuration: configuration, sessionID: candidate.sessionID)
            try await candidate.verify()
            guard currentForegroundSession(epoch) else { return }
            install(candidate, accountID: candidate.accountID, configuration: configuration)
            await discoverSpace(epoch: epoch)
        } catch {
            if currentForegroundSession(epoch) {
                if error as? SharedStateFailure == .unauthenticated {
                    ConnectedKeychain.delete(configuration: configuration)
                    status = "Sign in again to reconnect."
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
        do {
            let incoming = try await client.currentSpace()
            guard currentForegroundSession(epoch) else { return }
            try publishSpace(incoming, accountID: accountID, configuration: configuration,
                             client: client)
            busy = false
        } catch SharedStateFailure.notPaired {
            if currentForegroundSession(epoch) {
                coordinator.endSession()
                snapshot = nil
                invitation = nil
                status = "Signed in. Create a private space or enter an invitation."
                busy = false
            }
        } catch {
            if currentForegroundSession(epoch) {
                let message = Self.safeMessage(error)
                if error as? SharedStateFailure == .unauthenticated ||
                    error as? SharedStateFailure == .forbidden {
                    signOut()
                } else {
                    status = "Could not check private-space membership. Try again when connected."
                }
                errorMessage = message
                busy = false
            }
        }
    }

    func createSpace() async {
        guard canUseForeground, let client, let accountID, let configuration,
              snapshot == nil || (snapshot?.members.count == 1 && snapshot?.members.first == accountID) else { return }
        let epoch = generation
        busy = true
        do {
            let result = try await client.createSpace()
            guard currentForegroundSession(epoch) else { return }
            try publishSpace(result.snapshot, accountID: accountID,
                             configuration: configuration, client: client)
            invitation = result
            busy = false
        } catch { if currentForegroundSession(epoch) { errorMessage = Self.safeMessage(error); busy = false } }
    }

    func joinSpace(token: String) async {
        guard canUseForeground, let client, let accountID, let configuration, snapshot == nil else { return }
        let epoch = generation
        busy = true
        do {
            let result = try await client.joinSpace(inviteToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
            guard currentForegroundSession(epoch) else { return }
            try publishSpace(result, accountID: accountID, configuration: configuration, client: client)
            busy = false
        } catch { if currentForegroundSession(epoch) { errorMessage = Self.safeMessage(error); busy = false } }
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
        // The first authenticated space lookup is already validated and held only in memory.
        snapshot = incoming
        retryMembership = false
        status = incoming.members.count == 2 ? "Private space connected." : "Waiting for your invited reviewer."
    }

    func refresh(quietly: Bool = false) async {
        guard canUseForeground, let client, let accountID, let configuration else { return }
        let epoch = generation
        busy = true
        do {
            // A fresh membership lookup also catches a revoked or changed space.
            let incoming = try await client.currentSpace()
            guard currentForegroundSession(epoch) else { return }
            try incoming.validate(for: accountID)
            if snapshot?.spaceID != incoming.spaceID {
                try publishSpace(incoming, accountID: accountID,
                                 configuration: configuration, client: client)
            } else {
                let floor = max(snapshot?.revision ?? 0, incoming.revision)
                try await coordinator.refresh()
                guard currentForegroundSession(epoch) else { return }
                guard let refreshed = coordinator.snapshot, refreshed.revision >= floor else {
                    throw SharedStateFailure.staleState
                }
                snapshot = coordinator.snapshot
            }
            if snapshot?.members.count == 2 { invitation = nil }
            status = snapshot?.members.count == 2 ? "Private space connected." : "Waiting for your invited reviewer."
            retryMembership = false
            busy = false
        } catch SharedStateFailure.notPaired {
            if currentForegroundSession(epoch) {
                coordinator.endSession(); snapshot = nil; invitation = nil
                retryMembership = false
                status = "This account is no longer paired."
                busy = false
            }
        } catch {
            if currentForegroundSession(epoch) {
                let message = Self.safeMessage(error)
                let accessLost = error as? SharedStateFailure == .forbidden ||
                    error as? SharedStateFailure == .unauthenticated
                if accessLost {
                    signOut()
                } else if quietly {
                    status = "Could not synchronize. Retrying when connected."
                    retryMembership = snapshot == nil
                } else {
                    retryMembership = snapshot == nil
                }
                if !quietly || accessLost { errorMessage = message }
                busy = false
            }
        }
    }

    /// Any transition away from the foreground invalidates in-flight publications, including
    /// sign-in before an account is installed and discovery before a snapshot is available.
    /// Installed credentials remain bound to this account for foreground revalidation.
    func holdForValidation() {
        let wasEligible = foregroundEligible
        foregroundEligible = false
        guard selected, wasEligible else { return }
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

    @discardableResult
    func execute(_ command: SharedCommand) async -> ActionReceipt? {
        guard canUseForeground else { return nil }
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
            let created = try await coordinator.execute(command)
            guard currentForegroundSession(epoch) else { return nil }
            snapshot = coordinator.snapshot
            return ActionReceipt(createdID: created)
        } catch {
            if currentForegroundSession(epoch) {
                snapshot = coordinator.snapshot
                let message = Self.safeMessage(error)
                if error as? SharedStateFailure == .forbidden || error as? SharedStateFailure == .unauthenticated {
                    signOut()
                }
                errorMessage = message
                if error as? SharedStateFailure == .staleState { await refresh() }
            }
            return nil
        }
    }

    func signOut() {
        let oldConfiguration = configuration
        resetSession()
        if let oldConfiguration { ConnectedKeychain.delete(configuration: oldConfiguration) }
    }

    private func resetSession() {
        generation &+= 1
        foregroundRevalidationPending = false
        retryMembership = false
        if let configuration { ConnectedKeychain.clearBinding(configuration: configuration) }
        if let vault { Task { await vault.invalidate() } }
        coordinator.endSession()
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
        if error is ConnectedIdentityFailure {
            return "Secure session storage is unavailable on this device."
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

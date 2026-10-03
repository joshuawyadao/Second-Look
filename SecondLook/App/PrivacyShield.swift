import SwiftUI
import UIKit
#if SECONDLOOK_DEMO
import CoreFoundation
#endif

/// Owns a cover for one scene. A separate window also covers SwiftUI sheets and alerts.
struct PrivacyShieldHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shield = PrivacyShieldController()

    var body: some View {
        RootView()
            .background {
                PrivacySceneReader { scene in shield.attach(to: scene) }
                    .frame(width: 0, height: 0)
            }
            .onAppear { shield.setProtected(scenePhase != .active) }
            .onDisappear { shield.disconnect() }
            .onChange(of: scenePhase) { _, phase in
                shield.setProtected(phase != .active)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { note in
                if shield.owns(note.object) { shield.setProtected(true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { note in
                if shield.owns(note.object) { shield.setProtected(true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { note in
                if shield.owns(note.object) { shield.setProtected(false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                shield.setProtected(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                if shield.isSceneActive { shield.setProtected(false) }
            }
    }
}

@MainActor
private final class PrivacyShieldController {
    private weak var scene: UIWindowScene?
    private var coverWindow: UIWindow?
    private var protected = false
    #if SECONDLOOK_DEMO
    private let privacyTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        && ProcessInfo.processInfo.arguments.contains("-privacy-testing")
    private struct WeakTestController { weak var value: PrivacyShieldController? }
    private static var testControllers: [UInt: WeakTestController] = [:]
    private static var nextTestObserverID: UInt = 1
    private var testObserver: UnsafeMutableRawPointer?
    #endif

    var isSceneActive: Bool { scene?.activationState == .foregroundActive }

    func owns(_ object: Any?) -> Bool {
        guard let scene else { return false }
        return (object as? UIWindowScene) === scene
    }

    func attach(to nextScene: UIWindowScene?) {
        guard let nextScene else { return }
        guard scene !== nextScene else { return }
        disconnect()
        scene = nextScene
        #if SECONDLOOK_DEMO
        if privacyTesting { installTestObserver() }
        #endif
        if protected { showCover(in: nextScene) }
    }

    func setProtected(_ value: Bool) {
        protected = value
        if value {
            if let scene { showCover(in: scene) }
        } else {
            coverWindow?.isHidden = true
            coverWindow = nil
        }
    }

    func disconnect() {
        coverWindow?.isHidden = true
        coverWindow = nil
        #if SECONDLOOK_DEMO
        removeTestObserver()
        #endif
        scene = nil
    }

    private func showCover(in scene: UIWindowScene) {
        guard coverWindow == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
        window.backgroundColor = .systemBackground
        window.isOpaque = true
        let content = UIHostingController(rootView: PrivacyCoverView())
        content.view.backgroundColor = .systemBackground
        content.view.accessibilityViewIsModal = true
        window.rootViewController = content
        coverWindow = window
        // Keep the app's main window key so an open editor retains focus and state.
        window.isHidden = false
    }

    #if SECONDLOOK_DEMO
    private func installTestObserver() {
        let id = Self.nextTestObserverID
        Self.nextTestObserverID += 1
        // Core Foundation treats this token as opaque; no pointer is dereferenced.
        guard let token = UnsafeMutableRawPointer(bitPattern: id) else { return }
        testObserver = token
        Self.testControllers[id] = WeakTestController(value: self)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, token, { _, observer, _, _, _ in
            PrivacyShieldController.routeTestSignal(observer: observer, protected: true)
        }, "com.secondlook.ui-tests.privacy.show" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, token, { _, observer, _, _, _ in
            PrivacyShieldController.routeTestSignal(observer: observer, protected: false)
        }, "com.secondlook.ui-tests.privacy.hide" as CFString, nil, .deliverImmediately)
    }

    private func removeTestObserver() {
        guard let testObserver else { return }
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), testObserver, nil, nil)
        Self.testControllers.removeValue(forKey: UInt(bitPattern: testObserver))
        self.testObserver = nil
    }

    nonisolated private static func routeTestSignal(observer: UnsafeMutableRawPointer?, protected: Bool) {
        guard let observer else { return }
        let id = UInt(bitPattern: observer)
        Task { @MainActor in
            testControllers[id]?.value?.setProtected(protected)
        }
    }
    #endif
}

private struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Label("Second Look", systemImage: "checklist")
                    .font(.title2)
                Text("Content hidden")
                    .accessibilityIdentifier("privacyShieldVisible")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PrivacySceneReader: UIViewRepresentable {
    let onScene: @MainActor (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> SceneProbeView {
        let view = SceneProbeView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: SceneProbeView, context: Context) {
        view.onScene = onScene
        if let scene = view.window?.windowScene { onScene(scene) }
    }
}

private final class SceneProbeView: UIView {
    var onScene: (@MainActor (UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onScene?(window?.windowScene)
    }
}

import SwiftUI
import UIKit

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
    private var testControlWindow: UIWindow?
    private let privacyTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        && ProcessInfo.processInfo.arguments.contains("-privacy-testing")
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
        if privacyTesting { makeTestControl(in: nextScene) }
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
        testControlWindow?.isHidden = true
        testControlWindow = nil
        #endif
        scene = nil
    }

    private func showCover(in scene: UIWindowScene) {
        guard coverWindow == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
        window.backgroundColor = .systemBackground
        window.isOpaque = true
        #if SECONDLOOK_DEMO
        let content = UIHostingController(rootView: PrivacyCoverView(
            testRestore: privacyTesting,
            restore: { [weak self] in self?.setProtected(false) }
        ))
        #else
        let content = UIHostingController(rootView: PrivacyCoverView())
        #endif
        content.view.backgroundColor = .systemBackground
        content.view.accessibilityViewIsModal = true
        window.rootViewController = content
        coverWindow = window
        // Keep the app's main window key so an open editor retains focus and state.
        window.isHidden = false
    }

    #if SECONDLOOK_DEMO
    private func makeTestControl(in scene: UIWindowScene) {
        let bounds = scene.coordinateSpace.bounds
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: max(0, bounds.maxX - 86), y: 110, width: 76, height: 52)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        let content = UIHostingController(rootView: Button { [weak self] in
            self?.setProtected(true)
        } label: {
            Image(systemName: "eye.slash.fill")
                .font(.title3)
                .padding(12)
                .background(.regularMaterial, in: Capsule())
        }
        .accessibilityLabel("Show privacy shield")
        .accessibilityIdentifier("testShowPrivacyShield"))
        content.view.backgroundColor = .clear
        window.rootViewController = content
        testControlWindow = window
        window.isHidden = false
    }
    #endif
}

private struct PrivacyCoverView: View {
    #if SECONDLOOK_DEMO
    let testRestore: Bool
    let restore: @MainActor () -> Void
    #endif

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Label("Second Look", systemImage: "checklist")
                    .font(.title2)
                Text("Content hidden")
                    .accessibilityIdentifier("privacyShieldVisible")
                #if SECONDLOOK_DEMO
                if testRestore {
                    Button("Restore app for test", action: restore)
                        .accessibilityIdentifier("testRestoreApp")
                }
                #endif
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

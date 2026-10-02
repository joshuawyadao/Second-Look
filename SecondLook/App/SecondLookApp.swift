import SwiftUI

@main
struct SecondLookApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .overlay {
                    if scenePhase != .active {
                        Color(.systemBackground)
                            .overlay(Label("Second Look", systemImage: "checklist").font(.title2))
                            .ignoresSafeArea()
                    }
                }
        }
    }
}

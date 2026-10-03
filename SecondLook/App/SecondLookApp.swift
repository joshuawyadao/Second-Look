import SwiftUI

@main
struct SecondLookApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PrivacyShieldHost()
                .environment(model)
        }
    }
}

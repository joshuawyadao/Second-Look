import SwiftUI

@main
struct SecondLookApp: App {
    @State private var model = AppModel()
    @State private var connected = ConnectedAppModel()

    var body: some Scene {
        WindowGroup {
            PrivacyShieldHost()
                .environment(model)
                .environment(connected)
        }
    }
}

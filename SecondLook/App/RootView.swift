import SwiftUI
import SecondLookCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var model = model
        Group {
            if model.loadFailure != nil {
                ContentUnavailableView {
                    Label("Your lists could not be opened", systemImage: "exclamationmark.folder")
                } description: {
                    Text("The saved file has been preserved. No new changes will overwrite it. \(model.loadFailure ?? "")")
                } actions: {
                    Button("Try again") { model.load() }
                }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.modeTitle).font(.caption.bold())
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text(model.modeDetail).font(.caption2)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(model.modeTitle). \(model.modeDetail)")
                        Spacer(minLength: 8)
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape").padding(8)
                        }
                        .accessibilityLabel("Local settings")
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.thinMaterial)
                    TabView {
                        NavigationStack { RoutinesView() }
                            .tabItem { Label("Routines", systemImage: "checklist") }
                        NavigationStack { ReviewView() }
                            .tabItem { Label("Review", systemImage: "eye") }
                        NavigationStack { HistoryView() }
                            .tabItem { Label("History", systemImage: "clock") }
                    }
                }
                .sheet(isPresented: $showingSettings) { LocalSettingsView() }
            }
        }
        .tint(.teal)
        .alert("Change not saved", isPresented: Binding(
            get: { model.errorMessage != nil && !model.sheetHandlesErrors },
            set: { if !$0 && !model.sheetHandlesErrors { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct LocalSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Local foundation") {
                    Text("Lists and progress are stored on this device. Authentication, pairing, real photos, notifications, and shared synchronization are not connected.")
                    Text("Reminder and timeout preferences are saved only. No reminders are delivered and no evidence expires in this milestone.")
                }
                #if SECONDLOOK_DEMO
                Section("Development simulation") {
                    Picker("Preview role", selection: Bindable(model).demoRole) {
                        Text("Demo Alex").tag(DemoRole.performer)
                        Text("Demo Sam").tag(DemoRole.reviewer)
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier("demoRole")
                    Text("These are synthetic identities on one device. Switching roles does not sign in or grant real access.")
                        .font(.footnote)
                }
                #endif
            }
            .navigationTitle("Local settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

/// Mutation errors belong above the active sheet; the root handles nonmodal actions.
private struct SheetErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onAppear { model.sheetHandlesErrors = true }
            .onDisappear { model.sheetHandlesErrors = false }
            .alert("Change not saved", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
}

extension View {
    func sheetErrorAlert() -> some View { modifier(SheetErrorAlert()) }
}

import SwiftUI

/// A presented sheet owns its errors until dismissal; the root owns errors otherwise.
struct ConnectedActionErrorPresentation: ViewModifier {
    @Environment(ConnectedAppModel.self) private var model
    let inSheet: Bool
    @State private var sheetID = UUID()

    func body(content: Content) -> some View {
        content
            .alert("Shared action not completed", isPresented: Binding(
                get: { model.canPresentSharedError(sheetID: inSheet ? sheetID : nil) },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                if let actionID = model.retryActionForError {
                    Button("Retry this action") {
                        model.enqueue { _ = await model.retryUnconfirmedAction(actionID) }
                    }
                    .disabled(!model.canRetryUnconfirmedAction(actionID))
                }
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onAppear { if inSheet { model.registerErrorSheet(sheetID) } }
            .onDisappear { if inSheet { model.unregisterErrorSheet(sheetID) } }
    }
}

extension View {
    func connectedActionErrors(inSheet: Bool = false) -> some View {
        modifier(ConnectedActionErrorPresentation(inSheet: inSheet))
    }
}

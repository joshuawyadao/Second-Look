import SwiftUI
import UIKit

/// Keep the protected view tree mounted while a foreground membership check runs. Its fields
/// remain in memory, but the opaque overlay blocks sight and hit testing until verification.
private struct ConnectedRevalidationGate: ViewModifier {
    @Environment(ConnectedAppModel.self) private var model

    func body(content: Content) -> some View {
        let gated = model.needsPresentationRevalidation
        ZStack {
            content
                .opacity(gated ? 0 : 1)
                .allowsHitTesting(!gated)
                .accessibilityHidden(gated)

            if gated {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 12) {
                    #if SECONDLOOK_DEMO
                    if model.draftLifecycleChecksRequested {
                        Text("Protected presentation held for verification")
                            .font(.caption)
                            .accessibilityIdentifier("sharedDraftPresentationGate")
                    }
                    #endif
                    if model.busy {
                        ProgressView()
                        Text("Checking private-space membership")
                            .font(.footnote)
                    } else {
                        Text("Private-space membership could not be verified. Try again or sign out.")
                            .font(.footnote)
                        Button("Retry membership check") {
                            model.enqueue { await model.refresh() }
                        }
                        .accessibilityIdentifier("retrySharedRevalidation")
                        Button("Sign out") { model.signOut() }
                            .accessibilityIdentifier("signOutSharedRevalidation")
                    }
                    #if SECONDLOOK_DEMO
                    if model.simulatedDraftRevalidationPause {
                        Text("Foreground draft revalidation paused (simulated for acceptance)")
                            .font(.caption)
                            .accessibilityIdentifier("sharedSimulatedDraftRevalidationPause")
                        Button("Resume verified draft presentation") {
                            model.resumeDraftRevalidationForAcceptance()
                        }
                        .accessibilityIdentifier("resumeSharedDraftRevalidation")
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if gated { resignTextInput() }
        }
        .onChange(of: gated) { _, nowGated in
            if nowGated { resignTextInput() }
        }
        .interactiveDismissDisabled(gated)
    }

    private func resignTextInput() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

extension View {
    func connectedRevalidationGate() -> some View {
        modifier(ConnectedRevalidationGate())
    }
}

import SwiftUI

struct ApplePINPresenter: ViewModifier {
    private let store = AppleRestrictionStore.shared
    func body(content: Content) -> some View {
        content
            .disabled(store.prompt != nil)
            .accessibilityHidden(store.prompt != nil)
            .overlay {
                if let prompt = store.prompt {
                    VStack {
                        Spacer()
                        ApplePINEntryView(title: "Enter PIN", error: store.error,
                            onSubmit: store.submit, onCancel: store.cancelPrompt)
                        AppleForgotPINButton()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                    .id(prompt.id)
                }
            }
    }
}

struct AppleForgotPINButton: View {
    private let store = AppleRestrictionStore.shared
    @State private var confirmsReset = false
    @State private var error: String?
    var body: some View {
        Button { confirmsReset = true } label: {
            Text("Forgot PIN").frame(minHeight: 44).contentShape(.rect)
        }
            .accessibilityIdentifier("restrictions.forgot")
            .confirmationDialog("Remove restrictions?", isPresented: $confirmsReset, titleVisibility: .visible) {
                Button("Remove Restrictions", role: .destructive, action: reset)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the PIN and all locked groups and channels on this device.")
            }
            .alert("Could Not Remove Restrictions", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func reset() {
        do { try store.removeRestrictions() }
        catch { self.error = "Could not clear the PIN." }
    }
}

struct AppleSettingsPINLock: ViewModifier {
    var active = true
    private let store = AppleRestrictionStore.shared
    func body(content: Content) -> some View {
        if active && store.settingsLocked {
            VStack(spacing: 24) {
                Button {
                    Task { _ = await store.authorize(channelID: "", group: "", title: "Settings", settings: true) }
                } label: { Text("Unlock Settings").frame(minHeight: 44).contentShape(.rect) }
                .accessibilityIdentifier("restrictions.settings.unlock")
                AppleForgotPINButton()
            }
        } else { content }
    }
}

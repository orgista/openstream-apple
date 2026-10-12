import SwiftUI

/// How long "Hold to Reset" must be held. The gesture itself waits the full
/// duration; the tolerance only absorbs the few milliseconds between the
/// finger landing and the press callback recording it.
enum AppleHoldToConfirmPolicy {
    static let duration: Duration = .seconds(5)
    static let tolerance: Duration = .milliseconds(50)

    static func fires(heldFor held: Duration) -> Bool {
        held >= duration - tolerance
    }
}

/// The Reset OpenStream row: opens the confirmation page.
struct AppleResetEntry: View {
    var body: some View {
        NavigationLink {
            AppleResetView()
        } label: {
            Text("Reset oStream")
                #if !os(tvOS)
                .foregroundStyle(.red)
                #endif
        }
        .accessibilityIdentifier("settings.reset")
    }
}

/// Reset OpenStream's confirmation: what is erased, what is not, and the
/// final press-and-hold.
struct AppleResetView: View {
    var body: some View {
        Form {
            Section {
                Text("Erases everything oStream keeps on this device.")
                Text("iCloud copies stay. Remove them in Settings > your name > iCloud, and in Passwords (search oStream).")
                    .foregroundStyle(.secondary)
            }
            Section {
                AppleHoldToConfirmButton(title: "Hold to Reset", confirmationTitle: "Reset oStream?") {
                    AppleDeviceReset.eraseThisDeviceAndRestart()
                }
            }
        }
        .appleSettingsPage("Reset oStream")
        .scrollIndicators(.hidden)
    }
}

/// A destructive action that only runs after a 5 second press and hold (the
/// Select button on Apple TV). The fill shows the hold; letting go early
/// empties it. VoiceOver cannot hold, so its activation asks once more instead.
struct AppleHoldToConfirmButton: View {
    let title: String
    let confirmationTitle: String
    let action: () -> Void

    @State private var progress = 0.0
    @State private var pressStarted: ContinuousClock.Instant?
    @State private var fired = false
    @State private var confirmingWithVoiceOver = false
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            #if !os(tvOS)
            .foregroundStyle(.red)
            #endif
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(.red.opacity(0.35))
                        .frame(width: proxy.size.width * progress)
                }
            }
            .contentShape(Rectangle())
            #if os(tvOS)
            .focusable()
            .focused($focused)
            .scaleEffect(focused ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            .onLongPressGesture(minimumDuration: 5, perform: finish, onPressingChanged: pressingChanged)
            #else
            .onLongPressGesture(minimumDuration: 5, maximumDistance: 40, perform: finish, onPressingChanged: pressingChanged)
            #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { confirmingWithVoiceOver = true }
            .accessibilityIdentifier("reset.hold")
            .alert(confirmationTitle, isPresented: $confirmingWithVoiceOver) {
                Button("Reset", role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            }
            #if os(iOS)
            .sensoryFeedback(.success, trigger: fired) { _, didFire in didFire }
            #endif
    }

    private func pressingChanged(_ pressing: Bool) {
        guard !fired else { return }
        if pressing {
            pressStarted = .now
            withAnimation(.linear(duration: 5)) { progress = 1 }
        } else {
            pressStarted = nil
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
        }
    }

    private func finish() {
        guard let pressStarted, AppleHoldToConfirmPolicy.fires(heldFor: pressStarted.duration(to: .now)) else {
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            return
        }
        fired = true
        action()
    }
}

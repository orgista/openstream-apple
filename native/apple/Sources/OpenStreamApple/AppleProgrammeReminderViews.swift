import SwiftUI

struct AppleProgrammeReminderAction: View {
    let channel: AppleIPTVChannel
    let title: String
    let start: Date?
    let end: Date?
    private let store = AppleProgrammeReminderStore.shared

    var body: some View {
        if let start, let end, start > .now, end > start {
            let reminder = AppleProgrammeReminder(channelID: channel.id, channelName: channel.name, title: title, start: start, end: end)
            let saved = store.reminders.contains { $0.id == reminder.id }
            Button(saved ? "Cancel Reminder" : "Remind Me", systemImage: saved ? "bell.slash" : "bell") {
                Task { await store.toggle(reminder) }
            }
            .accessibilityIdentifier("guide.reminder")
        }
    }
}

struct AppleProgrammeReminderBanner: ViewModifier {
    private let store = AppleProgrammeReminderStore.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .alert("Reminder", isPresented: Binding(
                get: { store.notificationError != nil },
                set: { if !$0 { store.notificationError = nil } }
            )) { Button("OK") { store.notificationError = nil } } message: {
                Text(store.notificationError ?? "")
            }
            #if os(tvOS)
            .overlay(alignment: .top) {
                if let reminder = store.banner {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading) {
                            Text(reminder.title).font(.headline)
                            Text(reminder.channelName)
                        }
                        Button("Watch Now") { store.watch(reminder) }
                        Button("Dismiss") { store.banner = nil }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 32)
                    .accessibilityIdentifier("guide.reminder.banner")
                }
            }
            #endif
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                store.activateNotifications()
                while !Task.isCancelled {
                    store.poll()
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                }
            }
    }
}

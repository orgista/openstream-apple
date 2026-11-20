import SwiftUI

struct AppleLiveResumeSetting: View {
    @AppStorage(AppleLiveWatchHistoryStore.resumeKey) private var startWithLastChannel = true

    var body: some View {
        Toggle("Start with last channel", isOn: $startWithLastChannel)
            .accessibilityIdentifier("settings.live.resumeLastChannel")
    }
}

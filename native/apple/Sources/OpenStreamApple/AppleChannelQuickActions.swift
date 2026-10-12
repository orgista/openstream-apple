import SwiftUI

private struct AppleLiveSettingsKey: EnvironmentKey {
    static let defaultValue: AppleSettingsStore? = nil
}

extension EnvironmentValues {
    var liveChannelSettings: AppleSettingsStore? {
        get { self[AppleLiveSettingsKey.self] }
        set { self[AppleLiveSettingsKey.self] = newValue }
    }
}

struct AppleChannelQuickActions: View {
    let channel: AppleIPTVChannel
    @Environment(\.liveChannelSettings) private var settings

    var body: some View {
        if let settings {
            Button("Hide Channel", systemImage: "eye.slash") { settings.hiddenLiveChannelIDs.insert(channel.id) }
            if !channel.group.isEmpty {
                Button("Hide Group", systemImage: "eye.slash") {
                    settings.hiddenLiveGroups.insert(AppleLiveChannelPreferences.groupKey(channel))
                }
            }
        }
    }
}

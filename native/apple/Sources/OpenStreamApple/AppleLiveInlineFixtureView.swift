#if DEBUG
import SwiftUI

/// Local-only proof of the production inline player, without loading saved
/// sources or writing a channel/history entry on a review simulator.
public struct AppleLiveInlineFixtureView: View {
    @State private var coordinator: ApplePlaybackCoordinator
    private let channel: AppleIPTVChannel?
    private var request: ApplePlaybackRequest? { channel?.playbackRequest() }
    #if os(tvOS)
    @State private var footer = AppleTVLiveFooterState()
    @State private var multiview = false
    @State private var fixtureSelected: AppleIPTVChannel?
    #endif

    public init() {
        let defaults = UserDefaults.standard
        #if os(tvOS)
        _multiview = State(initialValue: defaults.bool(forKey: "OpenStreamMultiviewFixture"))
        #endif
        if defaults.bool(forKey: "OpenStreamVisionPlaybackIsLive"),
           let raw = defaults.string(forKey: "OpenStreamVisionPlaybackURL"),
           let url = URL(string: raw),
           Self.isFixtureURL(url, allowsLAN: defaults.bool(forKey: "OpenStreamDeviceLiveFixture")) {
            channel = AppleIPTVChannel(id: "inline-caption-fixture", sourceID: UUID(),
                                      name: "Caption fixture", streamURL: url)
        } else {
            channel = nil
        }
        let preferred = ApplePlaybackEngineKind.resolved(launchArguments: ProcessInfo.processInfo.arguments)
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: preferred)
        let languages = defaults.stringArray(forKey: AppleSubtitleLanguages.defaultsKey)
        let preference = defaults.string(forKey: "openstream.settings.captions.preference.v1")
            .flatMap(AppleCaptionsPreference.init(rawValue:)) ?? .always
        engine.applyCaptionPreferences(preference: preference, languages: languages ?? [],
                                       languagesAreExplicit: languages != nil)
        _coordinator = State(initialValue: ApplePlaybackCoordinator(engine: engine))
    }

    static func isFixtureURL(_ url: URL, allowsLAN: Bool) -> Bool {
        guard url.scheme == "http", url.user == nil, url.password == nil else { return false }
        if url.host == "127.0.0.1" { return true }
        guard allowsLAN, let host = url.host else { return false }
        let parts = host.split(separator: ".")
        let octets = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    #if os(tvOS)
    private var fixtureChannels: [AppleIPTVChannel] {
        guard let channel else { return [] }
        return (1...4).map { index in
            var streamURL = channel.streamURL
            if let template = UserDefaults.standard.string(forKey: "OpenStreamMultiviewTemplate"),
               let url = URL(string: template.replacingOccurrences(of: "{channel}", with: String(index))),
               url.scheme == "http", url.host == "127.0.0.1" { streamURL = url }
            if let urls = UserDefaults.standard.stringArray(forKey: "OpenStreamMultiviewURLs"), urls.count >= index,
               let url = URL(string: urls[index - 1]), url.scheme == "http", url.host == "127.0.0.1" {
                streamURL = url
            }
            return AppleIPTVChannel(id: "multiview-fixture-\(index)", sourceID: channel.sourceID,
                                    name: "Channel \(index)", streamURL: streamURL)
        }
    }
    #endif

    public var body: some View {
        #if os(tvOS)
        if channel != nil, multiview {
            AppleTVMultiviewScreen(initial: Array(fixtureChannels.prefix(max(2, min(4, UserDefaults.standard.integer(forKey: "OpenStreamMultiviewCount"))))), channels: fixtureChannels,
                                  onExit: { fixtureSelected = $0; multiview = false })
        } else if let channel = fixtureSelected ?? channel {
            AppleTVLivePlayerScreen(channel: channel, coordinator: coordinator,
                                    footerChannels: fixtureChannels, footer: $footer, onMultiview: { _ in multiview = true }, onSwitch: { fixtureSelected = $0 })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("live.stage.player")
                .accessibilityValue(coordinator.isReconnectingLive ? "Reconnecting" : coordinator.phase == .playing ? "Playing" : "")
        }
        #else
        TabView {
            Tab("Live", systemImage: "dot.radiowaves.left.and.right") {
                NavigationStack {
                    VStack(spacing: 0) {
                        if let request {
                            AppleLiveInlinePlayer(request: request, coordinator: coordinator,
                                                  playbackRevision: 0, logoURL: nil, sharedChannel: nil)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("live.stage.player")
                                .accessibilityValue(coordinator.isReconnectingLive ? "Reconnecting" : coordinator.phase == .playing ? "Playing" : "")
                            Label("Caption fixture", systemImage: "tv")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        Spacer()
                    }
                    .navigationTitle("Live")
                }
            }
        }
        .tint(.primary)
        #endif
    }
}
#endif

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
           let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1" {
            channel = AppleIPTVChannel(id: "inline-caption-fixture", sourceID: UUID(),
                                      name: "Caption fixture", streamURL: url)
        } else {
            channel = nil
        }
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: .openStream)
        let languages = defaults.stringArray(forKey: AppleSubtitleLanguages.defaultsKey)
        let preference = defaults.string(forKey: "openstream.settings.captions.preference.v1")
            .flatMap(AppleCaptionsPreference.init(rawValue:)) ?? .always
        engine.applyCaptionPreferences(preference: preference, languages: languages ?? [],
                                       languagesAreExplicit: languages != nil)
        _coordinator = State(initialValue: ApplePlaybackCoordinator(engine: engine))
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

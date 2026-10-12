#if DEBUG && os(tvOS)
import SwiftUI

/// Local, in-memory guide fixture. Bypasses source stores, history and normal startup.
public struct AppleLiveGuideFixtureView: View {
    @State private var channelIndex = AppleIPTVChannelIndex([])
    private var channels: [AppleIPTVChannel] { channelIndex.channels }
    @State private var guide = AppleIPTVGuide(programmes: [])
    @State private var category = "All"
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var player: AppleTVLivePlayerPresentation?
    @State private var playingChannel: AppleIPTVChannel?
    @State private var coordinator = ApplePlaybackCoordinator()
    @State private var footer = AppleTVLiveFooterState()
    @State private var multiviewChannels: [AppleIPTVChannel] = []

    public init() {}

    public var body: some View {
        TabView {
            Tab("Live", systemImage: "dot.radiowaves.left.and.right") {
                NavigationStack {
                    if !channels.isEmpty {
                        AppleTVLiveGuideScreen(
                            channels: channels, channelIndex: channelIndex, categories: ["All", "Favorites"], selectedCategory: $category,
                            guide: guide, guideRevision: 1, entries: [], favoriteIDs: [], nowPlaying: playingChannel ?? channels.first,
                            previewsEnabled: UserDefaults.standard.bool(forKey: "openstream.settings.trailer.autoplay.v1"),
                            isPlayerOpen: player != nil,
                            focusRestoreToken: 0, focusRestoreChannelID: "", searchDestination: { AppleTVChannelSearchEditor(query: $query) },
                            onSelect: play, onToggleFavorite: { _ in }, onVisibleChannels: { _ in },
                            onMultiview: { beginMultiview($0) })
                    } else if let errorMessage {
                        Text(errorMessage)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .tint(.white)
        .fullScreenCover(item: $player) { _ in
            if !multiviewChannels.isEmpty {
                AppleTVMultiviewScreen(initial: multiviewChannels, channels: channels, guide: guide,
                    onExit: { multiviewChannels = []; play($0) })
            } else if let channel = playingChannel {
                AppleTVLivePlayerScreen(channel: channel, coordinator: coordinator, footerChannels: channels,
                    footer: $footer, guide: guide, onMultiview: beginMultiview, onSwitch: play)
                    .id(ObjectIdentifier(coordinator))
            }
        }
        .task {
            AppleLaunchClock.begin()
            AppleTVGuideLatencyProbe.shared.install()
            do {
                let args = ProcessInfo.processInfo.arguments
                guard let index = args.firstIndex(of: "-OpenStreamDebugLiveFixture"), args.count > index + 2,
                      let m3u = URL(string: args[index + 1]), let xml = URL(string: args[index + 2]),
                      Self.isLocal(m3u), Self.isLocal(xml) else { throw AppleIPTVError.invalidPlaylist }
                let (playlist, _) = try await AppleBoundedHTTPDataLoader.load(URLRequest(url: m3u), maximumBytes: 2 * 1024 * 1024, redirectPolicy: .reject)
                let (programmes, _) = try await AppleBoundedHTTPDataLoader.load(URLRequest(url: xml), maximumBytes: 8 * 1024 * 1024, redirectPolicy: .reject)
                let fixture = try await Task.detached(priority: .userInitiated) {
                    let sourceID = UUID(uuidString: "D4000000-0000-0000-0000-000000000001")!
                    let channels = try AppleIPTVClient.parseM3U(playlist, sourceID: sourceID, baseURL: m3u)
                    guard !channels.isEmpty, channels.count <= 300, channels.allSatisfy({ channel in
                        Self.isLocal(channel.streamURL) && channel.logoURL.map(Self.isLocal) == true
                    }) else { throw AppleIPTVError.invalidPlaylist }
                    let mapping = Dictionary(channels.compactMap { channel in channel.guideID.map { ($0, channel.id) } }, uniquingKeysWith: { first, _ in first })
                    let mapped = AppleIPTVGuideXMLTVParser().parse(data: programmes).compactMap { p -> AppleIPTVProgramme? in
                        guard let id = mapping[p.channelID] else { return nil }
                        return AppleIPTVProgramme(id: p.id, channelID: id, title: p.title, subtitle: p.subtitle, description: p.description,
                                                  start: p.start, end: p.end, category: p.category, isLive: p.isLive)
                    }
                    return (channels, AppleIPTVGuide(programmes: mapped), mapped.count)
                }.value
                guard !Task.isCancelled else { return }
                guide = fixture.1
                channelIndex = AppleIPTVChannelIndex(fixture.0)
                appleTrace("guide.fixture channels=\(fixture.0.count) programmes=\(fixture.2) autoplay=\(UserDefaults.standard.bool(forKey: "openstream.settings.trailer.autoplay.v1"))")
            } catch {
                errorMessage = "Local guide fixture unavailable"
                appleTrace("guide.fixture failed")
            }
        }
    }

    private func play(_ channel: AppleIPTVChannel) {
        coordinator.stop()
        let native = AppleLiveStreamRoutePolicy.nativeRemoteHLS(url: channel.streamURL, probedKind: channel.probedMediaKind)
        let (engine, _) = ApplePlaybackEngineFactory.make(preferred: native ? .native : .openStream)
        coordinator = ApplePlaybackCoordinator(engine: engine)
        playingChannel = channel
        if player == nil { player = AppleTVLivePlayerPresentation() }
    }

    private func beginMultiview(_ held: AppleIPTVChannel?) {
        guard let current = playingChannel ?? channels.first,
              let otherID = AppleMultiviewPolicy.companionID(currentID: current.id, heldID: held?.id, orderedIDs: channels.map(\.id)),
              let other = held?.id == otherID ? held : channels.first(where: { $0.id == otherID }) else { return }
        coordinator.stop()
        multiviewChannels = [current, other]
        if player == nil { player = AppleTVLivePlayerPresentation() }
    }

    nonisolated private static func isLocal(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.user == nil && url.password == nil
    }
}
#endif

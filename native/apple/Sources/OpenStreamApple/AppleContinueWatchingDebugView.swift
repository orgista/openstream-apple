#if DEBUG
import SwiftUI
import CoreGraphics

/// Isolated artwork and clocks for repeatable card captures; no sources or watch history.
public struct AppleContinueWatchingDebugView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    AppleMediaShelf(title: "Continue Watching") {
                        tile(index: 0, name: "Harbor Lights", type: "series")
                        #if !os(iOS)
                        tile(index: 1, name: "Night Crossing", type: "movie")
                        tile(index: 2, name: "The Next Morning", type: "series")
                        #endif
                    }
                    #if os(iOS)
                    AppleMediaShelf(title: "") {
                        tile(index: 1, name: "Night Crossing", type: "movie")
                    }
                    AppleMediaShelf(title: "") {
                        tile(index: 2, name: "The Next Morning", type: "series")
                    }
                    #endif
                }
                .padding(.vertical, 40)
            }
            .scrollIndicators(.never)
            .background(.black)
            .environment(\.appleDiscoverRows, fixtureRowStyle)
            .appleCatalogCardButtonStyle()
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private var fixtureRowStyle: AppleDiscoverRowStyle? {
        #if os(iOS)
        .phone
        #else
        nil
        #endif
    }

    private func tile(index: Int, name: String, type: String) -> some View {
        let saved = ApplePlaybackProgress(position: index == 1 ? 1_800 : 1_020,
            duration: index == 1 ? 6_120 : 2_400, partID: "fixture:2:5")
        let next = index == 2 ? AppleMediaEpisode(id: "fixture:2:6", title: name, season: 2, episode: 6) : nil
        return AppleContinueWatchingTile(
            item: AppleCatalogItem(mediaID: "cw-fixture-\(index)", type: type, name: name,
                                   backgroundURL: URL(string: "https://fixture.example/art/cw-\(index).png")),
            info: .make(type: type, saved: saved, recordProgress: nil, episode: next, isNext: index == 2),
            isInList: false, onOpenTitle: {}, onToggleList: {}, onRemove: {}
        ) { Text(name) }
        .accessibilityIdentifier("cw.fixture.\(index)")
    }

    /// Fixture images stay in memory and never enter the user's artwork disk cache.
    nonisolated static func artwork(for url: URL) -> CGImage? {
        guard ProcessInfo.processInfo.arguments.contains("-OpenStreamContinueWatchingFixture"),
              url.host == "fixture.example",
              let index = (0..<3).first(where: { url.path == "/art/cw-\($0).png" }) else { return nil }
        return artwork[index]
    }

    nonisolated private static let artwork: [CGImage?] = (0..<3).map(makeArtwork)

    nonisolated private static func makeArtwork(_ index: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8,
                                      bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let light = index != 1
        context.setFillColor(CGColor(red: light ? 0.87 : 0.08, green: light ? 0.93 : 0.13,
                                     blue: light ? 0.98 : 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        context.setFillColor(CGColor(red: 0.97, green: 0.83, blue: 0.56, alpha: 1))
        context.fillEllipse(in: CGRect(x: 670, y: 330, width: 110, height: 110))
        context.setFillColor(CGColor(red: light ? 0.32 : 0.04, green: light ? 0.56 : 0.08,
                                     blue: light ? 0.64 : 0.13, alpha: 1))
        context.move(to: .zero)
        for point in [CGPoint(x: 0, y: 200), CGPoint(x: 240, y: 310), CGPoint(x: 450, y: 145),
                      CGPoint(x: 760, y: 255), CGPoint(x: 960, y: 110), CGPoint(x: 960, y: 0)] {
            context.addLine(to: point)
        }
        context.fillPath()
        return context.makeImage()
    }
}
#endif

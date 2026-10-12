import Foundation

/// When a play on the AVPlayer-only (stock) route is handed to the OpenStream
/// engine instead. An internal safety net, never a choice the viewer sees.
///
/// Owner decision 2026-10-01, "native player with our engine": every play uses
/// the OpenStream engine, which remuxes MKV/TS on the device and plays the
/// result in Apple's own player. The AVPlayer-only engine is reached only by
/// the DEBUG launch override (`-openstream.playback.engine native`) and, on
/// Apple TV, by an MP4 the policy sends straight to AVPlayer
/// (`AppleTVPlaybackPresentationPolicy.engineKind`). AVPlayer cannot open
/// Matroska, TS, AVI or WebM (SNL S51E7 offers only those), so:
/// - pre-gate: under the override, a press none of whose streams the stock
///   player opens starts on the OpenStream engine (`engine(preferred:for:)`);
/// - fallback: a press whose every stream fails on the stock route starts
///   again on the OpenStream engine, the streams it never tried first
///   (`afterEveryStreamFailed`, `fallbackOrder`);
/// - the "Playback Unavailable" alert (failure text, OK only) is for the
///   OpenStream engine failing.
public enum ApplePlaybackEngineFallback {
    /// The stock player opens this stream by the existing rules: not one the
    /// add-on marked as needing the gateway, and not a container AVFoundation
    /// cannot demux (`ApplePlaybackCoordinator.stockPlayerOpens`). A name that
    /// says nothing about its container counts as playable.
    public static func stockPlayable(_ request: ApplePlaybackRequest) -> Bool {
        !request.hints.notWebReady
            && ApplePlaybackCoordinator.stockPlayerOpens(url: request.url, filename: request.hints.filename)
    }

    /// The engine a press starts on. Only Native changes, only for on-demand
    /// streams, and only when not one candidate is stock-playable.
    public static func engine(
        preferred: ApplePlaybackEngineKind,
        for candidates: [ApplePlaybackRequest]
    ) -> ApplePlaybackEngineKind {
        guard preferred == .native, !candidates.isEmpty, !candidates.contains(where: \.isLive),
              !candidates.contains(where: stockPlayable) else { return preferred }
        return .openStream
    }

    public enum Decision: Equatable, Sendable {
        /// Start the title again on the OpenStream engine, this play only.
        case openStream
        /// "Playback Unavailable" with this text and OK.
        case alert(String)
    }

    /// Every stream of a press failed before anything played. Nil for a
    /// cancelled load, which is never shown.
    ///
    /// `engine` is the engine that failed; `alreadyFellBack` is true when this
    /// press was itself the OpenStream fallback, so it never loops.
    public static func afterEveryStreamFailed(
        _ failure: ApplePlaybackFailure,
        engine: ApplePlaybackEngineKind,
        alreadyFellBack: Bool
    ) -> Decision? {
        guard failure.kind != .cancelled else { return nil }
        if engine == .native, !alreadyFellBack { return .openStream }
        return .alert(failure.userMessage)
    }

    /// The fallback press's order: the streams the stock player never tried
    /// (the MKVs it skipped, and any past its limit) first, in their order,
    /// then the ones it tried, which the OpenStream engine may still open.
    public static func fallbackOrder<Item>(
        _ items: [Item],
        url: (Item) -> URL,
        tried: Set<URL>
    ) -> [Item] {
        items.filter { !tried.contains(url($0)) } + items.filter { tried.contains(url($0)) }
    }
}

/// What a player hands its presenter when every stream of a press failed
/// before anything played (`AppleStremioPlayerPresentation.onUnplayable`).
public struct ApplePlaybackUnplayable: Equatable, Sendable {
    public let failure: ApplePlaybackFailure
    /// The engine that failed.
    public let engine: ApplePlaybackEngineKind
    /// The streams it loaded (`ApplePlaybackCoordinator.triedSourceURLs`).
    public let triedSourceURLs: [URL]

    public init(failure: ApplePlaybackFailure, engine: ApplePlaybackEngineKind, triedSourceURLs: [URL]) {
        self.failure = failure
        self.engine = engine
        self.triedSourceURLs = triedSourceURLs
    }
}

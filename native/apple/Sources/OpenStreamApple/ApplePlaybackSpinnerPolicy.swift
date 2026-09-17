import Foundation

/// Which spinner is on screen while a stream connects — exactly one.
///
/// The player screen draws its own centred spinner until the engine has picked
/// a route; after that the route's player owns the indicator (the transport
/// overlay on the software route, AVKit's own on the stock route). The two
/// overlapped because `AppleTransportOverlayModel` keeps its own copy of the
/// route, which lags the coordinator's during a retry or a fallback: the
/// coordinator was back at `.none` while the model still said `.surface`, so
/// both drew, a few points apart — the owner's "loading videos has double
/// circles" (2026-09-14). Latching on the first route removes the overlap
/// without either side having to know about the other.
public enum ApplePlaybackSpinnerPolicy: Sendable {
    public static func showsScreenSpinner(
        route: ApplePlaybackPresentationRoute,
        isBusy: Bool,
        hasRouted: Bool
    ) -> Bool {
        guard !hasRouted else { return false }
        return route == .none && isBusy
    }
}

import Foundation

/// Which service a stream belongs to, derived from the stream itself: the
/// add-on that returned it and the registrable part of the host it points at.
/// Nothing here names a provider; two streams share a key exactly when they
/// came from the same add-on and point at the same domain.
public enum AppleStreamServiceKey {
    public static func key(addonName: String?, url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let addon = addonName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(addon)|\(domain(of: host))"
    }

    /// `a1.cdn.fixture.example` → `fixture.example`; `media.fixture.co.uk` →
    /// `fixture.co.uk`; an IP address or a single-label host stays whole, so
    /// two local servers on different addresses are two services.
    static func domain(of host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }), !host.contains(":") else {
            return host
        }
        let top = labels[labels.count - 1], second = labels[labels.count - 2]
        let keep = top.count == 2 && second.count <= 3 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// The part of a key the trace may name: the add-on, or the domain when
    /// the stream came from no named add-on.
    static func traceName(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addon = parts.first, !addon.isEmpty else { return parts.last.map(String.init) ?? key }
        return String(addon)
    }
}

/// Whether a playback failure says the whole service is down, or only that
/// this one stream cannot play.
public enum AppleStreamServiceFailureScope: Equatable, Sendable {
    /// 5xx, 429, timeouts, no route to the host, DNS failure, or the
    /// service's own "down for maintenance" answer: every stream from the
    /// same service will fail the same way.
    case service
    /// A missing file (404/410), a refused account, a codec or decoder
    /// failure: the next stream from the same service may well play.
    case stream

    public static func of(_ failure: ApplePlaybackFailure) -> Self {
        if let status = failure.httpStatus {
            return status >= 500 || status == 429 ? .service : .stream
        }
        switch failure.kind {
        case .unsupportedMedia, .authentication, .cancelled, .sourceEnded, .engineUnavailable:
            return .stream
        case .timedOut:
            return .service
        case .network, .player, .unavailable:
            break
        }
        if let code = failure.networkCode, serviceDownCodes.contains(code) { return .service }
        return saysServiceIsDown(failure.message) ? .service : .stream
    }

    private static let serviceDownCodes: Set<URLError.Code> = [
        .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse,
    ]

    private static func saysServiceIsDown(_ message: String) -> Bool {
        message.range(of: #"\b(maintenance|temporarily unavailable|service unavailable|is down|outage)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Services that failed at the service level in the last few minutes, kept in
/// memory for this launch only. A down service is never dropped: its streams
/// are demoted behind every other service's and still tried when nothing else
/// is left. Keys are domains and add-on names, never URLs.
@MainActor
public final class AppleStreamServiceHealth {
    public static let shared = AppleStreamServiceHealth()
    public let timeToLive: TimeInterval
    private var failures: [String: Date] = [:]

    public init(timeToLive: TimeInterval = 600) {
        self.timeToLive = timeToLive
    }

    public func recordFailure(_ key: String, now: Date = Date()) {
        failures = failures.filter { now.timeIntervalSince($0.value) < timeToLive }
        failures[key] = now
    }

    public func isUnhealthy(_ key: String?, now: Date = Date()) -> Bool {
        guard let key, let failed = failures[key] else { return false }
        return now.timeIntervalSince(failed) < timeToLive
    }

    public func unhealthyKeys(now: Date = Date()) -> Set<String> {
        Set(failures.filter { now.timeIntervalSince($0.value) < timeToLive }.keys)
    }

    /// `items` with every healthy service's entries first, order otherwise kept.
    func healthyFirst<Item>(_ items: [Item], now: Date = Date(), key: (Item) -> String?) -> [Item] {
        let down = items.map { isUnhealthy(key($0), now: now) }
        return zip(items, down).filter { !$0.1 }.map(\.0) + zip(items, down).filter { $0.1 }.map(\.0)
    }
}

extension AppleStremioHTTPPlaybackCandidate {
    /// The service this stream belongs to (see `AppleStreamServiceKey`).
    public var serviceKey: String? {
        AppleStreamServiceKey.key(addonName: sourceName, url: sourceURL)
    }
}

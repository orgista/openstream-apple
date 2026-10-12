import Foundation

actor AppleIPTVAccountLimits {
    static let shared = AppleIPTVAccountLimits()
    private var limits: [UUID: Int] = [:]

    func record(_ info: AppleIPTVAccountInfo, sourceID: UUID) {
        limits[sourceID] = info.maxConnections.flatMap { $0 > 0 ? $0 : nil }
    }

    func snapshot() -> [UUID: Int] { limits }
}

public struct AppleIPTVAccountInfo: Equatable, Sendable {
    public let expiresAt: Date?
    public let maxConnections: Int?
    public let activeConnections: Int?
    public let status: String?

    public init(expiration: String?, maxConnections: String?, activeConnections: String?, status: String?) {
        expiresAt = expiration.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        self.maxConnections = maxConnections.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        self.activeConnections = activeConnections.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        self.status = status
    }

    public var streamsInUse: String? {
        guard let activeConnections, let maxConnections, maxConnections > 0 else { return nil }
        return "\(activeConnections) of \(maxConnections) streams in use"
    }

    public func rejection(now: Date = .now, checkConnections: Bool = true) -> String? {
        let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["expired", "disabled", "banned"].contains(normalized) { return status }
        if let expiresAt, expiresAt <= now { return "Expired" }
        if checkConnections, let maximum = maxConnections, maximum > 0,
           let active = activeConnections, active >= maximum { return "MaxConnections" }
        return nil
    }
}

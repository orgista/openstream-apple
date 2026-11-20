import CoreGraphics
import Foundation

/// Pure multiview geometry and transitions. Channel order is insertion order,
/// so thermal shedding always retires the oldest stream without audio.
public enum AppleMultiviewPolicy {
    static func providerLimitReached(sourceID: UUID, sources: [String: UUID], limits: [UUID: Int],
                                     replacing: String? = nil) -> Bool {
        guard let limit = limits[sourceID], limit > 0 else { return false }
        return sources.filter { $0.key != replacing && $0.value == sourceID }.count >= limit
    }

    static func companionID(currentID: String, heldID: String?, orderedIDs: [String]) -> String? {
        if let heldID, heldID != currentID { return heldID }
        return orderedIDs.first { $0 != currentID }
    }

    public enum Layout: String, CaseIterable, Sendable { case grid, bigAndSmalls }
    public enum Thermal: Sendable { case nominal, fair, serious, critical }
    public enum Refusal: Sendable, Equatable {
        case full, thermal, duplicate
        public var message: String {
            switch self {
            case .full: "Multiview allows up to four channels"
            case .thermal: "Let Apple TV cool down before adding a channel"
            case .duplicate: "This channel is already in Multiview"
            }
        }
    }

    public struct Session: Equatable, Sendable {
        public private(set) var channels: [String]
        public private(set) var audioID: String?
        public private(set) var bigID: String?
        public private(set) var fullScreenID: String?
        public var layout: Layout = .grid

        public init(channels: [String]) {
            var seen = Set<String>()
            self.channels = Array(channels.filter { seen.insert($0).inserted }.prefix(4))
            audioID = self.channels.first
            bigID = self.channels.first
        }

        @discardableResult public mutating func add(_ id: String, thermal: Thermal) -> Refusal? {
            guard !channels.contains(id) else { return .duplicate }
            guard thermal != .serious && thermal != .critical else { return .thermal }
            guard channels.count < 4 else { return .full }
            channels.append(id)
            if audioID == nil { audioID = id }
            if bigID == nil { bigID = id }
            return nil
        }

        public mutating func focus(_ id: String) {
            guard channels.contains(id) else { return }
            audioID = id
        }

        public mutating func select(_ id: String) {
            guard channels.contains(id) else { return }
            focus(id)
            fullScreenID = id
        }

        public mutating func promote(_ id: String) {
            guard channels.contains(id) else { return }
            bigID = id
            layout = .bigAndSmalls
        }

        @discardableResult public mutating func replace(_ id: String, with replacement: String) -> Bool {
            guard !channels.contains(replacement), let index = channels.firstIndex(of: id) else { return false }
            channels[index] = replacement
            if audioID == id { audioID = replacement }
            if bigID == id { bigID = replacement }
            if fullScreenID == id { fullScreenID = replacement }
            return true
        }

        /// Returns the channel to play normally if only one tile remains.
        @discardableResult public mutating func remove(_ id: String) -> String? {
            channels.removeAll { $0 == id }
            if audioID == id { audioID = channels.first }
            if bigID == id { bigID = channels.first }
            if fullScreenID == id { fullScreenID = nil }
            return channels.count <= 1 ? channels.first : nil
        }

        /// Fullscreen Back preserves the grid; grid Back exits to audio.
        public mutating func back() -> String? {
            if fullScreenID != nil { fullScreenID = nil; return nil }
            return audioID
        }

        @discardableResult public mutating func shed(thermal: Thermal) -> String? {
            guard thermal == .critical, let oldest = channels.first(where: { $0 != audioID }) else { return nil }
            remove(oldest)
            return oldest
        }

        public var displayOrder: [String] {
            guard channels.count == 3 || layout == .bigAndSmalls, let bigID else { return channels }
            return [bigID] + channels.filter { $0 != bigID }
        }

        public var pausedChannelIDs: Set<String> {
            guard let fullScreenID else { return [] }
            return Set(channels.filter { $0 != fullScreenID })
        }
    }

    public static func frames(count: Int, layout: Layout, size: CGSize, gap: CGFloat = 12) -> [CGRect] {
        guard (1...4).contains(count), size.width > 0, size.height > 0 else { return [] }
        let gap = max(0, min(gap, min(size.width, size.height) / 8))
        if count == 1 { return [CGRect(origin: .zero, size: size)] }
        if count == 2 {
            let width = (size.width - gap) / 2
            return [CGRect(x: 0, y: 0, width: width, height: size.height), CGRect(x: width + gap, y: 0, width: width, height: size.height)]
        }
        if count == 3 || layout == .bigAndSmalls {
            let width = (size.width - gap) * 2 / 3
            let smallHeight = (size.height - gap * CGFloat(count - 2)) / CGFloat(count - 1)
            return [CGRect(x: 0, y: 0, width: width, height: size.height)] + (0..<(count - 1)).map {
                CGRect(x: width + gap, y: CGFloat($0) * (smallHeight + gap), width: size.width - width - gap, height: smallHeight)
            }
        }
        let width = (size.width - gap) / 2, height = (size.height - gap) / 2
        return (0..<4).map { CGRect(x: CGFloat($0 % 2) * (width + gap), y: CGFloat($0 / 2) * (height + gap), width: width, height: height) }
    }

    public static func message(for failure: ApplePlaybackFailure) -> String {
        let diagnostic = failure.message.lowercased()
        if failure.httpStatus.map({ (400..<500).contains($0) }) == true
            || ["max connections", "maximum connections", "connection limit", "too many", "http 401", "http 403", "http 429"].contains(where: diagnostic.contains) {
            return "Your provider allows fewer streams at once"
        }
        return "This channel can't play in Multiview"
    }
}

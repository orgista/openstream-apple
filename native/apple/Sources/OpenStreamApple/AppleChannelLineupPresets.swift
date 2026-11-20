// AppleChannelLineupPresets.swift
// OpenStreamApple
// Done / hooks needed: AppleChannelLineupPresets.match(channelName:in:) inside the Channel Manager's "Complete Guide" preset
import CoreFoundation
import Foundation

public struct AppleChannelLineupEntry: Codable, Sendable, Equatable {
    public let number: Int
    public let name: String
    public let aliases: [String]
    public let category: String
    public let market: Market?

    public init(number: Int, name: String, aliases: [String], category: String, market: Market? = nil) {
        self.number = number
        self.name = name
        self.aliases = aliases
        self.category = category
        self.market = market
    }

    public enum Market: Codable, Sendable, Equatable {
        case network(String)
        case region(String)

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(), let str = try? container.decode(String.self) {
                self = .region(str)
            } else if let container = try? decoder.container(keyedBy: CodingKeys.self), let network = try? container.decode(String.self, forKey: .network) {
                self = .network(network)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid market"))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .region(let name):
                var container = encoder.singleValueContainer()
                try container.encode(name)
            case .network(let network):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(network, forKey: .network)
            }
        }

        enum CodingKeys: String, CodingKey {
            case network
        }
    }
}

public enum AppleChannelLineupError: Error, Equatable, LocalizedError {
    case invalidFile, unsupportedVersion, tooLarge, couldNotSave, couldNotDownload

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "Invalid lineup file."
        case .unsupportedVersion: "This is a newer lineup. Update oStream to import it."
        case .tooLarge: "Lineup files must be 128 KB or smaller."
        case .couldNotSave: "Could not save the lineup."
        case .couldNotDownload: "Could not download the lineup."
        }
    }
}

public struct AppleChannelLineupFile: Codable, Equatable, Sendable {
    // JSON encodes the lineup as base64 inside the shared configuration.
    public static let maximumBytes = 128 * 1024
    public let format: String
    public let version: Int
    public let name: String
    public let region: String
    public let updated: String
    public let channels: [AppleChannelLineupEntry]
    public let markets: [String: String]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AppleChannelLineupError.tooLarge }
        do {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppleChannelLineupError.invalidFile
            }
            if let version = object["version"] {
                guard let number = version as? Int, let value = version as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw AppleChannelLineupError.invalidFile }
                guard number == 1 else { throw AppleChannelLineupError.unsupportedVersion }
            }
            let keys: Set<String> = ["format", "version", "name", "region", "updated", "channels", "markets"]
            guard Set(object.keys).isSubset(of: keys),
                  object["format"] == nil || object["format"] as? String == "ostream-lineup" else {
                throw AppleChannelLineupError.invalidFile
            }
            object["format"] = "ostream-lineup"
            object["version"] = 1
            if object["name"] == nil { object["name"] = "Lineup" }
            if object["region"] == nil { object["region"] = "" }
            if object["updated"] == nil { object["updated"] = "" }
            if object["markets"] == nil { object["markets"] = [String: String]() }
            guard let channels = object["channels"] as? [[String: Any]], !channels.isEmpty else {
                throw AppleChannelLineupError.invalidFile
            }
            let channelKeys: Set<String> = ["number", "name", "aliases", "category", "market"]
            for channel in channels {
                guard Set(channel.keys).isSubset(of: channelKeys) else { throw AppleChannelLineupError.invalidFile }
                if let market = channel["market"] as? [String: Any] {
                    guard Set(market.keys) == ["network"] else { throw AppleChannelLineupError.invalidFile }
                }
            }
            let file = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
            let names = [file.name, file.region, file.updated] + Array(file.markets.keys) + Array(file.markets.values)
                + file.channels.flatMap { [$0.name, $0.category] + $0.aliases + [$0.market.map {
                    switch $0 { case .network(let value), .region(let value): value }
                } ?? ""] }
            guard !file.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  file.channels.allSatisfy({ $0.number > 0 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  names.allSatisfy({ !$0.contains("://") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                throw AppleChannelLineupError.invalidFile
            }
            return file
        } catch let error as AppleChannelLineupError { throw error }
        catch { throw AppleChannelLineupError.invalidFile }
    }
}

/// Complete Guide organises channels from the viewer's own playlist.
public enum AppleChannelLineupPresets {
    public static var current: [AppleChannelLineupEntry] { AppleChannelLineupStore.shared.current?.channels ?? [] }
    public static var isAvailable: Bool { !current.isEmpty }

    public static func match(channelName: String, in entries: [AppleChannelLineupEntry]) -> AppleChannelLineupEntry? {
        let normalizedSearch = normalize(name: channelName)
        for entry in entries {
            if normalize(name: entry.name) == normalizedSearch {
                return entry
            }
            if entry.aliases.contains(where: { normalize(name: $0) == normalizedSearch }) {
                return entry
            }
        }
        return nil
    }

    public static func localMatches(zip: String, entries: [AppleChannelLineupEntry],
                                    markets: [String: String] = AppleChannelLineupStore.shared.current?.markets ?? [:]) -> [AppleChannelLineupEntry] {
        
        let prefix3 = String(zip.prefix(3))
        guard let marketName = markets[prefix3] else { return [] }
        
        return entries.filter { entry in
            switch entry.market {
            case .region(let region):
                return region == marketName
            case .network(_):
                return true
            case nil:
                return false
            }
        }
    }

    public static func matchesLocalChannel(name: String, zip: String, entries: [AppleChannelLineupEntry],
                                           markets: [String: String] = AppleChannelLineupStore.shared.current?.markets ?? [:]) -> Bool {
        localMatches(zip: zip, entries: entries, markets: markets).contains { entry in
            if case .region = entry.market { return match(channelName: name, in: [entry]) != nil }
            return false
        }
    }

    static func normalize(name: String) -> String {
        var str = name.lowercased()
        if str.hasPrefix("us:") {
            str = String(str.dropFirst(3))
        }
        str = str.trimmingCharacters(in: .whitespaces)
        
        // Replace punctuation with spaces
        let punctuation = CharacterSet.punctuationCharacters
        str = String(str.unicodeScalars.map { punctuation.contains($0) ? Character(" ") : Character($0) })
        
        // Collapse spaces
        str = str.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        
        let removals = [" hd", " fhd", " 4k", " east", " west"]
        var changed = true
        while changed {
            changed = false
            for r in removals {
                if str.hasSuffix(r) {
                    str = String(str.dropLast(r.count))
                    str = str.trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return str
    }
}

struct AppleChannelLineupIndex: Sendable {
    private let entries: [String: AppleChannelLineupEntry]
    init(_ values: [AppleChannelLineupEntry]) {
        var result: [String: AppleChannelLineupEntry] = [:]
        for entry in values {
            for name in [entry.name] + entry.aliases {
                let normalized = AppleChannelLineupPresets.normalize(name: name)
                if result[normalized] == nil { result[normalized] = entry }
            }
        }
        entries = result
    }
    func match(_ name: String) -> AppleChannelLineupEntry? {
        entries[AppleChannelLineupPresets.normalize(name: name)]
    }
}

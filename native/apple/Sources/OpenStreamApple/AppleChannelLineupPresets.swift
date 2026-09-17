// AppleChannelLineupPresets.swift
// OpenStreamApple
// Done / hooks needed: AppleChannelLineupPresets.match(channelName:in:) inside the Channel Manager's "Premier Guide" preset
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

private struct LineupFile: Codable, Sendable {
    let channels: [AppleChannelLineupEntry]
    let markets: [String: String]
}

public enum AppleChannelLineupPresets {
    private static let bundle = Bundle.module

    private static let cachedFile: Result<LineupFile, any Error> = Result { try readFile() }
    private static func loadFile() throws -> LineupFile { try cachedFile.get() }

    private static func readFile() throws -> LineupFile {
        let url: URL
        if let bundleURL = bundle.url(forResource: "premier-us-extended", withExtension: "json") {
            url = bundleURL
        } else if let bundleURL = bundle.url(forResource: "premier-us-extended", withExtension: "json", subdirectory: "ChannelLineup") {
            url = bundleURL
        } else {
            let thisFile = URL(fileURLWithPath: #filePath)
            url = thisFile.deletingLastPathComponent().appendingPathComponent("Resources/ChannelLineup/premier-us.json")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LineupFile.self, from: data)
    }

    public static func premierUS() throws -> [AppleChannelLineupEntry] {
        return try loadFile().channels
    }

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

    public static func localMatches(zip: String, entries: [AppleChannelLineupEntry]) -> [AppleChannelLineupEntry] {
        guard let file = try? loadFile() else { return [] }
        
        let prefix3 = String(zip.prefix(3))
        guard let marketName = file.markets[prefix3] else { return [] }
        
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

    public static func matchesLocalChannel(name: String, zip: String, entries: [AppleChannelLineupEntry]) -> Bool {
        localMatches(zip: zip, entries: entries).contains { entry in
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

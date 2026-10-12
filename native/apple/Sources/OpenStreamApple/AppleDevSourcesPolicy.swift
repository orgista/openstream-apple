#if DEBUG && OPENSTREAM_ADDONS
import Foundation

/// One source from the owner's private dev-sources file, written by
/// `scripts/dev-sources.py` (schema v1). Debug builds only.
enum AppleDevSource: Equatable, Sendable {
    enum Credential: Equatable, Sendable {
        case password(username: String, password: String)
        case token(String)
    }

    case stremio(name: String, manifestURL: String)
    case xtream(name: String, serverURL: String, username: String, password: String, epgURL: String?)
    case m3u(name: String, playlistURL: String, epgURL: String?)
    case smb(name: String, host: String, port: Int, share: String, path: String,
             username: String, password: String, domain: String)
    case mediaServer(kind: AppleMediaServerKind, name: String, url: String, credential: Credential)
    /// A folder on this device (a simulator's container path), added as a
    /// Library folder: how a fixture such as a disc image reaches Library.
    case folder(name: String, path: String)

    /// The file's `kind` value.
    var kindName: String {
        switch self {
        case .stremio: "stremio"
        case .xtream: "xtream"
        case .m3u: "m3u"
        case .smb: "smb"
        case .mediaServer: "mediaServer"
        case .folder: "folder"
        }
    }

    var name: String {
        switch self {
        case .stremio(let name, _), .xtream(let name, _, _, _, _), .m3u(let name, _, _),
             .smb(let name, _, _, _, _, _, _, _), .mediaServer(_, let name, _, _), .folder(let name, _):
            name
        }
    }

    /// Values that must never reach the trace. A playlist or configured
    /// add-on URL carries its credentials in the address itself.
    var secrets: [String] {
        let values: [String]
        switch self {
        case .stremio(_, let url): values = [url]
        case .xtream(_, let server, let username, let password, _): values = [server, username, password]
        case .m3u(_, let playlist, _): values = [playlist]
        case .smb(_, _, _, _, _, let username, let password, _): values = [username, password]
        case .mediaServer(_, _, let url, .password(let username, let password)): values = [url, username, password]
        case .mediaServer(_, _, let url, .token(let token)): values = [url, token]
        case .folder: values = []
        }
        return values.filter { !$0.isEmpty }
    }
}

/// The service keys block of the dev-sources file. Empty values are absent.
struct AppleDevSettings: Equatable, Sendable {
    struct Arr: Equatable, Sendable {
        var url: String
        var apiKey: String
        var rootFolderPath: String
        var qualityProfileID: String
    }

    var tmdbAPIKey: String?
    var radarr: Arr?
    var sonarr: Arr?
    var traktClientID: String?

    /// Which keys the file set, by name only.
    var appliedNames: [String] {
        [tmdbAPIKey.map { _ in "tmdb" }, radarr.map { _ in "radarr" },
         sonarr.map { _ in "sonarr" }, traktClientID.map { _ in "trakt" }].compactMap { $0 }
    }
}

struct AppleDevSourcesFile: Equatable, Sendable {
    var sources: [AppleDevSource] = []
    var settings = AppleDevSettings()
    /// Entries that could not be used: "<kind> <name>: missing <field>".
    /// Field names only, never a value.
    var problems: [String] = []
    /// `kind` values this build does not know; those entries are skipped.
    var ignoredKinds: [String] = []
}

/// Pure rules for `-OpenStreamDevSources <path>`: decoding the file,
/// recognising a source that is already saved, and trace wording that never
/// carries a secret.
enum AppleDevSourcesPolicy {
    static let launchKey = "OpenStreamDevSources"
    static let supportedVersion = 1
    static let tracePrefix = "dev sources:"

    enum DecodeError: Error, Equatable {
        case notJSON
        case unsupportedVersion(Int?)
    }

    enum Outcome: Equatable, Sendable {
        case added
        case exists
        case failed(String)
    }

    static func decode(_ data: Data) throws -> AppleDevSourcesFile {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DecodeError.notJSON
        }
        let version = integer(root["version"])
        guard version == supportedVersion else { throw DecodeError.unsupportedVersion(version) }
        var file = AppleDevSourcesFile()
        for (index, value) in ((root["sources"] as? [Any]) ?? []).enumerated() {
            guard let entry = value as? [String: Any] else {
                file.problems.append("source \(index + 1): not an object")
                continue
            }
            decodeSource(entry, index: index, into: &file)
        }
        file.settings = decodeSettings(root["settings"] as? [String: Any] ?? [:])
        return file
    }

    /// Same kind and same address as a source that is already saved.
    static func alreadyAdded(_ source: AppleDevSource, in existing: [AppleSource]) -> Bool {
        switch source {
        case .stremio(_, let manifestURL):
            guard let url = try? AppleManifestURLPolicy.normalize(manifestURL) else { return false }
            return existing.contains { $0.isAddon && $0.url == url }
        case .xtream(_, let serverURL, _, _, _):
            return existingIPTV(.xtream, endpoint: serverURL, in: existing)
        case .m3u(_, let playlistURL, _):
            return existingIPTV(.m3u, endpoint: playlistURL, in: existing)
        case .smb(_, let host, let port, let share, let path, _, _, _):
            guard let url = try? AppleSMBEndpointPolicy.makeURL(host: host, port: port, share: share, path: path) else {
                return false
            }
            return existing.contains { $0.kind == .nas && $0.url == url }
        case .mediaServer(let kind, _, let urlText, _):
            guard let url = AppleMediaServerFormPolicy.normalizedBaseURL(urlText) else { return false }
            return existing.contains {
                $0.kind == .mediaServer && $0.serverKind == kind
                    && $0.url.host?.lowercased() == url.host?.lowercased() && $0.url.port == url.port
            }
        case .folder(_, let path):
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return existing.contains { $0.kind == .library && $0.url.standardizedFileURL == url }
        }
    }

    /// `dev sources: <kind> <name>: added|exists|failed <reason>`.
    static func traceLine(for source: AppleDevSource, outcome: Outcome) -> String {
        var label = source.name
        if label.isEmpty, case .stremio(_, let manifestURL) = source {
            // An add-on's host is public; its path can carry a configuration.
            label = URL(string: manifestURL)?.host ?? ""
        }
        if label.isEmpty { label = "(unnamed)" }
        let result = switch outcome {
        case .added: "added"
        case .exists: "exists"
        case .failed(let reason): "failed \(reason)"
        }
        return "\(tracePrefix) \(source.kindName) \(label): \(result)"
    }

    static func summaryLine(added: Int, exists: Int, failed: Int, skipped: Int) -> String {
        "\(tracePrefix) done (\(added) added, \(exists) exists, \(failed) failed, \(skipped) skipped)"
    }

    /// An error's message with every secret of the entry and every URL or
    /// credential-looking pair taken out, on one short line.
    static func failureReason(_ error: any Error, hiding secrets: [String]) -> String {
        var text = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        text = AppleDiagnosticRedactor.redact(text)
        text = text.components(separatedBy: .newlines).joined(separator: " ")
        return String(text.trimmingCharacters(in: .whitespaces).prefix(160))
    }

    // MARK: - Decoding

    private static func decodeSource(_ entry: [String: Any], index: Int, into file: inout AppleDevSourcesFile) {
        let kind = string(entry["kind"])
        let name = string(entry["name"])
        var missing: [String] = []
        func required(_ key: String) -> String {
            let value = string(entry[key])
            if value.isEmpty { missing.append(key) }
            return value
        }
        let source: AppleDevSource?
        switch kind {
        case "stremio":
            source = .stremio(name: name, manifestURL: required("manifestURL"))
        case "xtream":
            source = .xtream(name: name, serverURL: required("serverURL"), username: required("username"),
                             password: required("password"), epgURL: optional(entry["epgURL"]))
        case "m3u":
            source = .m3u(name: name, playlistURL: required("playlistURL"), epgURL: optional(entry["epgURL"]))
        case "smb":
            source = .smb(name: name, host: required("host"), port: integer(entry["port"]) ?? 445,
                          share: required("share"), path: string(entry["path"]),
                          username: string(entry["username"]), password: string(entry["password"]),
                          domain: string(entry["domain"]))
        case "mediaServer":
            let server = string(entry["server"]).lowercased()
            let url = required("url")
            guard let serverKind = AppleMediaServerKind(rawValue: server) else {
                missing.append("server")
                source = nil
                break
            }
            let credential: AppleDevSource.Credential = serverKind == .plex
                ? .token(required("token"))
                : .password(username: required("username"), password: string(entry["password"]))
            source = .mediaServer(kind: serverKind, name: name, url: url, credential: credential)
        case "folder":
            source = .folder(name: name, path: required("path"))
        case "":
            file.problems.append("source \(index + 1): missing kind")
            return
        default:
            file.ignoredKinds.append(kind)
            return
        }
        if missing.isEmpty, let source {
            file.sources.append(source)
        } else {
            let label = name.isEmpty ? "source \(index + 1)" : name
            file.problems.append("\(kind) \(label): missing \(missing.joined(separator: ", "))")
        }
    }

    private static func decodeSettings(_ settings: [String: Any]) -> AppleDevSettings {
        AppleDevSettings(
            tmdbAPIKey: optional(settings["tmdbAPIKey"]),
            radarr: arr(settings["radarr"]),
            sonarr: arr(settings["sonarr"]),
            traktClientID: optional(settings["traktClientID"])
        )
    }

    private static func arr(_ value: Any?) -> AppleDevSettings.Arr? {
        guard let object = value as? [String: Any] else { return nil }
        let url = string(object["url"])
        let apiKey = string(object["apiKey"])
        guard !url.isEmpty, !apiKey.isEmpty else { return nil }
        return AppleDevSettings.Arr(url: url, apiKey: apiKey,
                                    rootFolderPath: string(object["rootFolderPath"]),
                                    qualityProfileID: string(object["qualityProfileID"]))
    }

    private static func existingIPTV(_ type: AppleIPTVSourceType, endpoint: String, in existing: [AppleSource]) -> Bool {
        guard let url = try? AppleIPTVEndpointPolicy.normalize(endpoint) else { return false }
        return existing.contains { $0.kind == .liveTV && $0.iptvType == type && $0.url == url }
    }

    /// Strings are trimmed; a number (the Python script can write a port or
    /// a profile id either way) reads as its decimal text.
    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    private static func optional(_ value: Any?) -> String? {
        let text = string(value)
        return text.isEmpty ? nil : text
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
#endif

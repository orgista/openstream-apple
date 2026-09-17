import Foundation
import Observation

public enum AppleSourceKind: String, Codable, CaseIterable, Sendable {
    case library
    case stremio
    case youtube
    case liveTV
    case nas

    public var title: String {
        switch self {
        case .library: "Library"
        case .stremio: "Add-on"
        case .youtube: "YouTube"
        case .liveTV: "Live TV"
        case .nas: "Network share"
        }
    }
}

public enum AppleIPTVSourceType: String, Codable, CaseIterable, Sendable {
    case m3u
    case xtream

    public var title: String {
        switch self {
        case .m3u: "M3U Playlist"
        case .xtream: "Xtream Account"
        }
    }
}

public struct AppleIPTVCredentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

enum AppleDiagnosticRedactor {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?|smb)://[^\s\"'<>]+"#
    )
    private static let bodyPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(body|requestBody|responseBody)\s*[:=]\s*.*$"#
    )
    private static let credentialPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passwd|pwd|username|user|token|cookie|authorization)\b\s*[\"']?\s*[:=]\s*[\"']?[^,\s;&}\]]+"#
    )

    static func redact(_ value: String) -> String {
        var redacted = replace(urlPattern, in: value, with: "[REDACTED URL]")
        redacted = replace(bodyPattern, in: redacted, with: "$1=[REDACTED]")
        return replace(credentialPattern, in: redacted, with: "$1=[REDACTED]")
    }

    private static func replace(
        _ expression: NSRegularExpression,
        in value: String,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}

public struct AppleSource: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: AppleSourceKind
    public var name: String
    public var url: URL
    public var isEnabled: Bool
    public let addedAt: Date
    public var manifestID: String?
    public var version: String?
    public var resources: [String]
    public var catalogs: [AppleStremioCatalog]
    public var logoURL: URL?
    public var iptvType: AppleIPTVSourceType?
    public var epgURL: URL?
    public var credentialReference: String?
    public var transportReference: String?
    public var bookmarkData: Data?
    public var isManagedImports: Bool
    public var configurationRevision: Int
    public var lastValidatedAt: Date?
    public var validationSummary: String?
    public var lastValidationFailureAt: Date?
    public var validationFailureSummary: String?
    public var discoveredItemCount: Int?
    public var capabilities: [String]
    /// The readable Bonjour hostname for NAS sources. `url.host` remains the
    /// resolved numeric endpoint used by the SMB client.
    public var networkDisplayHost: String?

    // Decode-only bridge for v1 installs. AppleSourceStore immediately moves
    // these values to Keychain and they are never encoded again.
    var legacyUsername: String?
    var legacyPassword: String?

    public init(
        id: UUID = UUID(),
        kind: AppleSourceKind,
        name: String,
        url: URL,
        isEnabled: Bool = true,
        addedAt: Date = .now,
        manifestID: String? = nil,
        version: String? = nil,
        resources: [String] = [],
        catalogs: [AppleStremioCatalog] = [],
        logoURL: URL? = nil,
        iptvType: AppleIPTVSourceType? = nil,
        epgURL: URL? = nil,
        credentialReference: String? = nil,
        transportReference: String? = nil,
        bookmarkData: Data? = nil,
        isManagedImports: Bool = false,
        configurationRevision: Int = 1,
        lastValidatedAt: Date? = nil,
        validationSummary: String? = nil,
        lastValidationFailureAt: Date? = nil,
        validationFailureSummary: String? = nil,
        discoveredItemCount: Int? = nil,
        capabilities: [String] = [],
        networkDisplayHost: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.addedAt = addedAt
        self.manifestID = manifestID
        self.version = version
        self.resources = resources
        self.catalogs = catalogs
        self.logoURL = logoURL
        self.iptvType = iptvType
        self.epgURL = epgURL
        self.credentialReference = credentialReference
        self.transportReference = transportReference
        self.bookmarkData = bookmarkData
        self.isManagedImports = isManagedImports
        self.configurationRevision = max(configurationRevision, 1)
        self.lastValidatedAt = lastValidatedAt
        self.validationSummary = Self.cleanStatus(validationSummary)
        self.lastValidationFailureAt = lastValidationFailureAt
        self.validationFailureSummary = Self.cleanStatus(validationFailureSummary)
        self.discoveredItemCount = Self.cleanItemCount(discoveredItemCount)
        self.capabilities = Self.cleanCapabilities(capabilities)
        self.networkDisplayHost = Self.cleanNetworkDisplayHost(networkDisplayHost)
        legacyUsername = nil
        legacyPassword = nil
    }

    public var transportURL: URL {
        guard kind == .stremio else { return url }
        return AppleManifestURLPolicy.addonBaseURL(forManifest: url)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, url, isEnabled, addedAt, manifestID, version, resources, catalogs, isManagedImports
        case logoURL, iptvType, epgURL, credentialReference, transportReference, username, password, bookmarkData
        case configurationRevision, lastValidatedAt, validationSummary
        case lastValidationFailureAt, validationFailureSummary, discoveredItemCount, capabilities, networkDisplayHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(AppleSourceKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
        manifestID = try container.decodeIfPresent(String.self, forKey: .manifestID)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        resources = try container.decodeIfPresent([String].self, forKey: .resources) ?? []
        catalogs = try container.decodeIfPresent([AppleStremioCatalog].self, forKey: .catalogs) ?? []
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        iptvType = try container.decodeIfPresent(AppleIPTVSourceType.self, forKey: .iptvType)
        epgURL = try container.decodeIfPresent(URL.self, forKey: .epgURL)
        credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference)
        transportReference = try container.decodeIfPresent(String.self, forKey: .transportReference)
        legacyUsername = try container.decodeIfPresent(String.self, forKey: .username)
        legacyPassword = try container.decodeIfPresent(String.self, forKey: .password)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isManagedImports = try container.decodeIfPresent(Bool.self, forKey: .isManagedImports) ?? false
        configurationRevision = max(
            try container.decodeIfPresent(Int.self, forKey: .configurationRevision) ?? 1,
            1
        )
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        validationSummary = Self.cleanStatus(try container.decodeIfPresent(String.self, forKey: .validationSummary))
        lastValidationFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastValidationFailureAt)
        validationFailureSummary = Self.cleanStatus(
            try container.decodeIfPresent(String.self, forKey: .validationFailureSummary)
        )
        discoveredItemCount = Self.cleanItemCount(
            try container.decodeIfPresent(Int.self, forKey: .discoveredItemCount)
        )
        capabilities = Self.cleanCapabilities(
            try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        )
        networkDisplayHost = Self.cleanNetworkDisplayHost(
            try container.decodeIfPresent(String.self, forKey: .networkDisplayHost)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(manifestID, forKey: .manifestID)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(resources, forKey: .resources)
        try container.encode(catalogs, forKey: .catalogs)
        try container.encodeIfPresent(logoURL, forKey: .logoURL)
        try container.encodeIfPresent(iptvType, forKey: .iptvType)
        try container.encodeIfPresent(epgURL, forKey: .epgURL)
        try container.encodeIfPresent(credentialReference, forKey: .credentialReference)
        try container.encodeIfPresent(transportReference, forKey: .transportReference)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        if isManagedImports { try container.encode(true, forKey: .isManagedImports) }
        try container.encode(configurationRevision, forKey: .configurationRevision)
        try container.encodeIfPresent(lastValidatedAt, forKey: .lastValidatedAt)
        try container.encodeIfPresent(validationSummary, forKey: .validationSummary)
        try container.encodeIfPresent(lastValidationFailureAt, forKey: .lastValidationFailureAt)
        try container.encodeIfPresent(validationFailureSummary, forKey: .validationFailureSummary)
        try container.encodeIfPresent(discoveredItemCount, forKey: .discoveredItemCount)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(networkDisplayHost, forKey: .networkDisplayHost)
    }

    private static func cleanStatus(_ value: String?) -> String? {
        value?
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map(AppleDiagnosticRedactor.redact)
            .map { String($0.prefix(200)) }
    }

    private static func cleanItemCount(_ value: Int?) -> Int? {
        value.map { min(max($0, 0), 1_000_000) }
    }

    private static func cleanNetworkDisplayHost(_ value: String?) -> String? {
        value?
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(256)) }
    }

    private static func cleanCapabilities(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let bounded = String(clean.prefix(40))
            guard seen.insert(bounded.lowercased()).inserted else { return nil }
            return bounded
        }.prefix(16).map { $0 }
    }
}

public enum AppleManifestURLPolicy {
    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case empty
        case missingScheme
        case insecureHTTP
        case unsupportedScheme(String)
        case invalidURL
        case missingHost
        case credentialsNotAllowed
        case queryNotAllowed
        case fragmentNotAllowed
        case wrongJSONDocument(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                "Enter a manifest URL."
            case .missingScheme:
                "Add https:// to the beginning."
            case .insecureHTTP:
                "Use the add-on's HTTPS manifest URL."
            case .unsupportedScheme(let scheme):
                "\(scheme) URLs are not supported."
            case .invalidURL:
                "This URL is not valid."
            case .missingHost:
                "This URL is missing a host."
            case .credentialsNotAllowed:
                "URLs containing a username or password are not supported."
            case .queryNotAllowed:
                "URL query options are not supported."
            case .fragmentNotAllowed:
                "URL fragments are not supported."
            case .wrongJSONDocument(let filename):
                "\(filename) is not a manifest.json file."
            }
        }
    }

    public static func normalize(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.empty }
        guard let schemeSeparator = trimmed.range(of: "://"), schemeSeparator.lowerBound != trimmed.startIndex else {
            throw Error.missingScheme
        }
        // A configured add-on's address may be pasted with its JSON segment
        // still in raw braces; encode only what the parser cannot accept.
        guard var components = URLComponents(string: trimmed)
            ?? URLComponents(string: trimmed, encodingInvalidCharacters: true) else {
            throw Error.invalidURL
        }

        // Add-on directories hand out install links under their own scheme.
        // They address the same HTTPS manifest, so accept them as pasted.
        var scheme = components.scheme?.lowercased()
        if scheme == "stremio" || scheme == "openstream" {
            scheme = "https"
        }
        if scheme == "http" {
            guard let host = components.host, isLoopbackHost(host) else {
                throw Error.insecureHTTP
            }
        }
        guard scheme == "https" || scheme == "http" else {
            throw Error.unsupportedScheme(scheme ?? "Unknown")
        }
        guard let host = components.host, !host.isEmpty else { throw Error.missingHost }
        guard components.user == nil, components.password == nil else { throw Error.credentialsNotAllowed }
        guard components.query == nil else { throw Error.queryNotAllowed }
        guard components.fragment == nil else { throw Error.fragmentNotAllowed }

        let filename = components.path.split(separator: "/").last.map(String.init)
        if let filename,
           filename.lowercased().hasSuffix(".json"),
           filename.lowercased() != "manifest.json" {
            throw Error.wrongJSONDocument(filename)
        }

        components.scheme = scheme
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        if filename?.lowercased() != "manifest.json" {
            // Work on the encoded path so a configured add-on's JSON or base64
            // segment stays byte-for-byte what the owner pasted.
            let basePath = components.percentEncodedPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.percentEncodedPath = basePath.isEmpty
                ? "/manifest.json"
                : "/\(basePath)/manifest.json"
        }

        guard let normalized = components.url else { throw Error.invalidURL }
        return normalized
    }

    /// The add-on's base address: the manifest URL with only the trailing
    /// `manifest.json` removed (the slash before it stays). Works on the
    /// percent-encoded path so a configured add-on's JSON or base64 segment
    /// is never decoded or re-encoded on the way to its catalog endpoints.
    public static func addonBaseURL(forManifest url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let path = components.percentEncodedPath
        let suffix = "manifest.json"
        guard path.lowercased().hasSuffix("/\(suffix)") else { return url }
        components.percentEncodedPath = String(path.dropLast(suffix.count))
        return components.url ?? url
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost" || normalized == "::1" || normalized == "127.0.0.1"
    }

    public static func allowsLocalHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http"
            && url.host.map(isLoopbackHost) == true
    }
}

public struct AppleStremioCatalog: Codable, Equatable, Sendable {
    public let type: String
    public let id: String
    public let name: String?
    public let requiresInput: Bool
    public let supportsSearch: Bool

    public init(
        type: String,
        id: String,
        name: String? = nil,
        requiresInput: Bool = false,
        supportsSearch: Bool = false
    ) {
        self.type = String(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(40))
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.name = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(100)) }
        self.requiresInput = requiresInput
        self.supportsSearch = supportsSearch
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, name, extra, extraRequired, extraSupported, requiresInput, supportsSearch
    }

    private struct Extra: Decodable {
        let name: String?
        let isRequired: Bool

        private enum CodingKeys: String, CodingKey { case name, isRequired }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decode(String.self, forKey: .name)
            isRequired = (try? container.decode(Bool.self, forKey: .isRequired)) ?? false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        let extras = (try? container.decode(
            AppleManifestLossyList<Extra>.self,
            forKey: .extra
        ))?.values ?? []
        // Older add-ons describe their inputs with the short-hand
        // `extraRequired`/`extraSupported` name lists instead of `extra`.
        let required = (try? container.decode([String].self, forKey: .extraRequired)) ?? []
        let supported = (try? container.decode([String].self, forKey: .extraSupported)) ?? []
        func names(_ values: [String]) -> [String] {
            values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        }
        self.init(
            type: type,
            id: id,
            name: try? container.decode(String.self, forKey: .name),
            requiresInput: ((try? container.decode(Bool.self, forKey: .requiresInput)) ?? false)
                || extras.contains(where: \.isRequired)
                || !names(required).isEmpty,
            supportsSearch: ((try? container.decode(Bool.self, forKey: .supportsSearch)) ?? false)
                || extras.contains { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "search" }
                || names(required + supported).contains("search")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(requiresInput, forKey: .requiresInput)
        try container.encode(supportsSearch, forKey: .supportsSearch)
    }
}

public struct AppleStremioManifest: Decodable, Equatable, Sendable {
    public static let maximumCatalogs = 12

    public let id: String
    public let name: String
    public let version: String?
    public let logoURL: URL?
    public let resources: [String]
    public let catalogs: [AppleStremioCatalog]
    /// `behaviorHints.configurationRequired`: the add-on refuses to serve
    /// anything until the owner configures it on its own site.
    public let requiresConfiguration: Bool

    public init(
        id: String,
        name: String,
        version: String? = nil,
        logoURL: URL? = nil,
        resources: [String] = [],
        catalogs: [AppleStremioCatalog] = [],
        requiresConfiguration: Bool = false
    ) {
        self.requiresConfiguration = requiresConfiguration
        self.id = String(id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        self.version = version?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(40)) }
        self.logoURL = Self.sanitizeLogoURL(logoURL)
        self.resources = Self.sanitizeResources(resources)
        self.catalogs = Self.sanitizeCatalogs(catalogs)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, logo, icon, resources, catalogs, types, behaviorHints
    }

    private struct BehaviorHints: Decodable {
        let configurationRequired: Bool

        private enum CodingKeys: String, CodingKey { case configurationRequired }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            configurationRequired = (try? container.decode(Bool.self, forKey: .configurationRequired)) ?? false
        }
    }

    private enum ManifestResource: Decodable {
        case name(String)

        private enum CodingKeys: String, CodingKey { case name }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self = .name(value)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self = .name(try container.decode(String.self, forKey: .name))
        }

        var value: String {
            switch self { case .name(let value): value }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode leniently so the client can name the field an add-on omitted
        // rather than reporting one generic failure for every shape problem.
        let id = (try? container.decode(String.self, forKey: .id)) ?? ""
        let name = (try? container.decode(String.self, forKey: .name)) ?? ""
        let version = try? container.decode(String.self, forKey: .version)
        let logo = (try? container.decode(URL.self, forKey: .icon))
            ?? (try? container.decode(URL.self, forKey: .logo))

        let decodedResources = (try? container.decode(
            AppleManifestLossyList<ManifestResource>.self,
            forKey: .resources
        ))?.values.map(\.value) ?? []
        let decodedCatalogs = (try? container.decode(
            AppleManifestLossyList<AppleStremioCatalog>.self,
            forKey: .catalogs
        ))?.values ?? []
        let hints = try? container.decode(BehaviorHints.self, forKey: .behaviorHints)
        self.init(
            id: id,
            name: name,
            version: version,
            logoURL: logo,
            resources: decodedResources,
            catalogs: decodedCatalogs,
            requiresConfiguration: hints?.configurationRequired ?? false
        )
    }

    private static func sanitizeLogoURL(_ value: URL?) -> URL? {
        guard let value,
              let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url
    }

    private static func sanitizeResources(_ resources: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in resources {
            let cleaned = String(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(64))
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
            if result.count == 32 { break }
        }
        return result
    }

    private static func sanitizeCatalogs(_ catalogs: [AppleStremioCatalog]) -> [AppleStremioCatalog] {
        var seen = Set<String>()
        var result: [AppleStremioCatalog] = []
        for value in catalogs {
            let catalog = AppleStremioCatalog(
                type: value.type,
                id: value.id,
                name: value.name,
                requiresInput: value.requiresInput,
                supportsSearch: value.supportsSearch
            )
            let key = "\(catalog.type):\(catalog.id)"
            guard ["movie", "series"].contains(catalog.type),
                  !catalog.id.isEmpty,
                  seen.insert(key).inserted else {
                continue
            }
            result.append(catalog)
            if result.count == maximumCatalogs { break }
        }
        return result
    }
}

private struct AppleManifestLossyList<Value: Decodable>: Decodable {
    let values: [Value]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Value] = []
        var inspected = 0
        while !container.isAtEnd, inspected < 64 {
            inspected += 1
            let entry = try container.superDecoder()
            if let value = try? Value(from: entry) { result.append(value) }
        }
        values = result
    }
}

private struct AppleSourceLossyList {
    let values: [AppleSource]
    let unknownPayloads: [Data]

    init(data: Data) throws {
        guard let members = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a source array"))
        }
        var result: [AppleSource] = []
        var unknown: [Data] = []
        for member in members.prefix(1_024) {
            guard JSONSerialization.isValidJSONObject(member),
                  let payload = try? JSONSerialization.data(withJSONObject: member) else {
                continue
            }
            if let value = try? JSONDecoder().decode(AppleSource.self, from: payload) {
                result.append(value)
            } else {
                unknown.append(payload)
            }
        }
        values = result
        unknownPayloads = unknown
    }
}

public enum AppleManifestClientError: Swift.Error, Equatable, LocalizedError, Sendable {
    case nonHTTPResponse
    case insecureRedirect
    case requestFailed(Int)
    case responseTooLarge
    case invalidManifest
    case manifestNotJSON
    case manifestNotObject
    case manifestMissingField(String)
    /// A required field is present but has the wrong JSON shape
    /// (field name, expected shape such as "text" or "a list").
    case manifestFieldWrongType(String, String)
    case manifestNeedsConfiguration

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse: "The add-on returned an invalid response."
        case .insecureRedirect: "The add-on redirected to an insecure address."
        case .requestFailed(let status): "The manifest request failed with HTTP \(status)."
        case .responseTooLarge: "The manifest is too large."
        case .invalidManifest: "The response is not a valid add-on manifest."
        case .manifestNotJSON: "The address returned a page instead of a manifest."
        case .manifestNotObject: "The manifest is not a JSON object."
        case .manifestMissingField(let field): "The manifest has no \"\(field)\"."
        case .manifestFieldWrongType(let field, let expected):
            "The manifest's \"\(field)\" is not \(expected)."
        case .manifestNeedsConfiguration:
            "Configure this add-on on its own site first, then paste the address it gives you."
        }
    }
}

public struct AppleManifestClient: Sendable {
    public typealias Loader = @Sendable (URL) async throws -> (Data, URLResponse)
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let loader: Loader
    private let sleeper: Sleeper

    public init(
        loader: @escaping Loader = AppleManifestClient.liveLoader,
        sleeper: @escaping Sleeper = AppleManifestClient.liveSleeper
    ) {
        self.loader = loader
        self.sleeper = sleeper
    }

    public func load(_ value: String) async throws -> (URL, AppleStremioManifest) {
        let url = try AppleManifestURLPolicy.normalize(value)
        var lastTransportError: (any Swift.Error)?

        for attempt in 0 ..< 4 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await loader(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch AppleManifestClientError.responseTooLarge {
                throw AppleManifestClientError.responseTooLarge
            } catch {
                lastTransportError = error
                guard attempt < 3 else { throw error }
                try await sleeper(backoff(for: attempt))
                continue
            }

            guard let http = response as? HTTPURLResponse else { throw AppleManifestClientError.nonHTTPResponse }
            guard let responseURL = http.url,
                  responseURL.scheme?.lowercased() == "https"
                    || AppleManifestURLPolicy.allowsLocalHTTP(responseURL) else {
                throw AppleManifestClientError.insecureRedirect
            }
            if isRetryable(http.statusCode), attempt < 3 {
                try await sleeper(backoff(for: attempt))
                continue
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw AppleManifestClientError.requestFailed(http.statusCode)
            }
            return try decodedManifest(data, from: url)
        }

        if let lastTransportError { throw lastTransportError }
        throw AppleManifestClientError.invalidManifest
    }

    private func decodedManifest(_ data: Data, from url: URL) throws -> (URL, AppleStremioManifest) {
        guard data.count <= 2_000_000 else { throw AppleManifestClientError.responseTooLarge }
        // Name the shape problem before the lenient decoder smooths it over:
        // an HTML page, a JSON list, or a field of the wrong kind each get
        // their own reason instead of one generic failure.
        guard let document = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw AppleManifestClientError.manifestNotJSON
        }
        guard let object = document as? [String: Any] else {
            throw AppleManifestClientError.manifestNotObject
        }
        try Self.checkFieldShapes(object)
        guard let manifest = try? JSONDecoder().decode(AppleStremioManifest.self, from: data) else {
            throw AppleManifestClientError.invalidManifest
        }
        guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleManifestClientError.manifestMissingField("id")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleManifestClientError.manifestMissingField("name")
        }
        guard !manifest.requiresConfiguration else {
            throw AppleManifestClientError.manifestNeedsConfiguration
        }
        return (url, manifest)
    }

    private static func checkFieldShapes(_ object: [String: Any]) throws {
        for field in ["id", "name"] {
            if let value = object[field], !(value is NSNull), !(value is String) {
                throw AppleManifestClientError.manifestFieldWrongType(field, "text")
            }
        }
        for field in ["resources", "catalogs"] {
            if let value = object[field], !(value is NSNull), !(value is [Any]) {
                throw AppleManifestClientError.manifestFieldWrongType(field, "a list")
            }
        }
    }

    private func isRetryable(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500 ... 599).contains(status)
    }

    private func backoff(for attempt: Int) -> Duration {
        switch attempt {
        case 0: .milliseconds(250)
        case 1: .milliseconds(500)
        default: .seconds(1)
        }
    }

    public static func liveLoader(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStream/1.0 Apple", forHTTPHeaderField: "User-Agent")
        do {
            return try await AppleBoundedHTTPDataLoader.load(request, maximumBytes: 2_000_000)
        } catch AppleBoundedHTTPError.responseTooLarge {
            throw AppleManifestClientError.responseTooLarge
        }
    }

    public static func liveSleeper(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

@MainActor
@Observable
public final class AppleSourceStore {
    public private(set) var sources: [AppleSource]
    public private(set) var credentialError: String?

    private let defaults: UserDefaults
    private let storageKey: String
    private let keychain: any AppleCredentialStoring
    private let managedImportsDirectory: URL
    private let manifestClient: AppleManifestClient
    private let logoBackfillDelay: Duration
    private var protectsStoredBlobWhenEmpty: Bool
    private var preservedUnknownSourcePayloads: [Data]
    private var pendingCredentialCleanupReferences: [String]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "openstream.sources.v1",
        keychain: any AppleCredentialStoring = AppleKeychainStore(service: "com.orgista.openstream.instances"),
        documentsDirectory: URL? = nil,
        manifestClient: AppleManifestClient = AppleManifestClient(),
        logoBackfillDelay: Duration = .seconds(2)
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.keychain = keychain
        self.manifestClient = manifestClient
        self.logoBackfillDelay = logoBackfillDelay
        managedImportsDirectory = (documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
        credentialError = nil
        preservedUnknownSourcePayloads = []
        pendingCredentialCleanupReferences = defaults.stringArray(
            forKey: storageKey + ".pending-keychain-removals"
        ) ?? []
        if let data = defaults.data(forKey: storageKey) {
            if let decoded = try? AppleSourceLossyList(data: data) {
                sources = decoded.values.sorted { $0.addedAt < $1.addedAt }
                preservedUnknownSourcePayloads = decoded.unknownPayloads
                protectsStoredBlobWhenEmpty = decoded.values.isEmpty && !Self.isEmptyStoredList(data)
            } else {
                sources = []
                protectsStoredBlobWhenEmpty = !Self.isEmptyStoredList(data)
            }
        } else {
            sources = []
            protectsStoredBlobWhenEmpty = false
        }
        retryPendingCredentialCleanup()
        hydrateProtectedTransportURLs()
        migrateLegacyIPTVCredentials()
        relocateManagedImports()
        scheduleLogoBackfill()
    }

    @discardableResult
    public func addStremio(manifestURL: URL, name: String) throws -> AppleSource {
        let normalizedURL = try AppleManifestURLPolicy.normalize(manifestURL.absoluteString)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? (normalizedURL.host ?? "Add-on") : cleanName

        if let index = sources.firstIndex(where: { $0.kind == .stremio && $0.url == normalizedURL }) {
            sources[index].name = displayName
            sources[index].isEnabled = true
            sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
            persist()
            return sources[index]
        }

        let source = try securedTransportSource(
            AppleSource(kind: .stremio, name: displayName, url: normalizedURL)
        )
        sources.append(source)
        persist()
        return source
    }

    @discardableResult
    public func addStremio(manifestURL: URL, manifest: AppleStremioManifest) throws -> AppleSource {
        let normalizedURL = try AppleManifestURLPolicy.normalize(manifestURL.absoluteString)
        let cleanID = String(manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let cleanName = String(manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let cleanVersion = manifest.version?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(40)) }
        let cleanManifest = AppleStremioManifest(
            id: cleanID,
            name: cleanName,
            version: cleanVersion,
            logoURL: manifest.logoURL,
            resources: manifest.resources,
            catalogs: manifest.catalogs
        )
        guard !cleanID.isEmpty else { throw AppleManifestClientError.manifestMissingField("id") }
        guard !cleanName.isEmpty else { throw AppleManifestClientError.manifestMissingField("name") }

        if let index = sources.firstIndex(where: { $0.kind == .stremio && $0.manifestID == cleanID }) {
            let existing = sources[index]
            sources[index] = try securedTransportSource(AppleSource(
                id: existing.id,
                kind: .stremio,
                name: cleanName,
                url: normalizedURL,
                isEnabled: true,
                addedAt: existing.addedAt,
                manifestID: cleanID,
                version: cleanVersion,
                resources: cleanManifest.resources,
                catalogs: cleanManifest.catalogs,
                logoURL: cleanManifest.logoURL,
                transportReference: existing.transportReference,
                configurationRevision: nextConfigurationRevision(existing.configurationRevision),
                lastValidatedAt: .now,
                validationSummary: "Manifest validated",
                lastValidationFailureAt: existing.lastValidationFailureAt,
                validationFailureSummary: existing.validationFailureSummary,
                capabilities: cleanManifest.resources.map { $0.capitalized }
            ))
            persist()
            return sources[index]
        }

        let source = try securedTransportSource(AppleSource(
            kind: .stremio,
            name: cleanName,
            url: normalizedURL,
            manifestID: cleanID,
            version: cleanVersion,
            resources: cleanManifest.resources,
            catalogs: cleanManifest.catalogs,
            logoURL: cleanManifest.logoURL,
            lastValidatedAt: .now,
            validationSummary: "Manifest validated",
            capabilities: cleanManifest.resources.map { $0.capitalized }
        ))
        sources.append(source)
        persist()
        return source
    }

    @discardableResult
    public func addStremio(
        manifestValue: String,
        client: AppleManifestClient = AppleManifestClient()
    ) async throws -> AppleSource {
        let (url, manifest) = try await client.load(manifestValue)
        try Task.checkCancellation()
        return try addStremio(manifestURL: url, manifest: manifest)
    }

    /// Re-derives the manifest-owned fields of an add-on source (logo,
    /// version, resources, capabilities, and the name when it came from a
    /// manifest) from a freshly fetched manifest. The logo passes through the
    /// same sanitizer as on add, so a plain `http://` logo that an older
    /// build dropped is stored now. A manifest without a logo keeps whatever
    /// logo is already saved. Returns `true` when something changed and was
    /// persisted; applying the same manifest twice is a no-op.
    @discardableResult
    public func applyManifest(_ manifest: AppleStremioManifest, to id: AppleSource.ID) -> Bool {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              sources[index].kind == .stremio else { return false }
        let clean = AppleStremioManifest(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            logoURL: manifest.logoURL,
            resources: manifest.resources,
            catalogs: manifest.catalogs
        )
        guard !clean.id.isEmpty, !clean.name.isEmpty else { return false }
        var updated = sources[index]
        if let storedID = updated.manifestID {
            // Another add-on answering at the saved address must not take
            // over this entry's identity; an owner-named entry (no manifest
            // id) keeps its name.
            guard storedID == clean.id else { return false }
            updated.name = clean.name
        }
        updated.version = clean.version
        if let logoURL = clean.logoURL { updated.logoURL = logoURL }
        updated.resources = clean.resources
        updated.capabilities = boundedCapabilities(clean.resources.map { $0.capitalized })
        guard updated != sources[index] else { return false }
        sources[index] = updated
        persist()
        return true
    }

    /// Fetches the add-on's manifest again and applies it. Fail-open: a
    /// transport or shape failure leaves the source exactly as it was.
    /// Add-ons every tester should start with (owner, 2026-09-17: "add
    /// AIOmetadata add-on for testing"). Seeded once per install in DEBUG and
    /// TestFlight builds; a tester who deletes one never sees it come back.
    public static var testCatalogManifests: [String] {
        // Personal catalog addresses are supplied by local build configuration.
        Bundle.main.object(forInfoDictionaryKey: "OpenStreamTestCatalogManifests") as? [String] ?? []
    }

    public static var seedsTestCatalogs: Bool {
        #if DEBUG
        true
        #else
        AppleBuildChannel.isTestFlight
        #endif
    }

    /// Adds each test catalog the first time it succeeds; a manifest that
    /// fails to load (offline) is retried on the next launch.
    ///
    /// Passes the store's own `manifestClient` explicitly. Letting
    /// `addStremio(manifestValue:)` build its default `AppleManifestClient()`
    /// from inside this async method crashed the 2026-09-17 gate with "freed
    /// pointer was not the last allocation" (signal 6, deterministic) — and
    /// bypassed the stub client in tests. Bisected in `AppleTestCatalogSeedTests`.
    public func seedTestCatalogsIfNeeded(force: Bool = false, manifests: [String]? = nil) async {
        guard force || Self.seedsTestCatalogs else { return }
        let pending = pendingTestCatalogs(manifests: manifests ?? Self.testCatalogManifests)
        var index = 0
        while index < pending.count {
            let value = pending[index]
            index += 1
            if await seedTestCatalog(value) { markTestCatalogSeeded(value) }
        }
    }

    private var testCatalogSeedKey: String { storageKey + ".seeded-test-catalogs.v1" }

    private func seededTestCatalogs() -> [String] {
        defaults.stringArray(forKey: testCatalogSeedKey) ?? []
    }

    private func pendingTestCatalogs(manifests: [String]) -> [String] {
        let done = seededTestCatalogs()
        return manifests.filter { !done.contains($0) }
    }

    private func markTestCatalogSeeded(_ value: String) {
        var done = seededTestCatalogs()
        guard !done.contains(value) else { return }
        done.append(value)
        defaults.set(done, forKey: testCatalogSeedKey)
    }

    private func seedTestCatalog(_ value: String) async -> Bool {
        do {
            // The store's own client — the default argument builds a fresh live
            // client, which also bypassed the stub in tests.
            _ = try await addStremio(manifestValue: value, client: manifestClient)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func refreshManifest(id: AppleSource.ID) async -> Bool {
        guard let source = sources.first(where: { $0.id == id }), source.kind == .stremio else { return false }
        guard let loaded = try? await manifestClient.load(source.url.absoluteString) else { return false }
        return applyManifest(loaded.1, to: id)
    }

    public func setEnabled(_ enabled: Bool, id: AppleSource.ID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        guard sources[index].isEnabled != enabled else { return }
        sources[index].isEnabled = enabled
        sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
        persist()
    }

    @discardableResult
    public func addIPTV(
        name: String,
        type: AppleIPTVSourceType,
        endpoint: String,
        username: String = "",
        password: String = "",
        epgURL: String? = nil,
        lastValidatedAt: Date? = nil,
        validationSummary: String? = nil,
        discoveredItemCount: Int? = nil,
        capabilities: [String] = []
    ) throws -> AppleSource {
        let url = try AppleIPTVEndpointPolicy.normalize(endpoint)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? "My TV" : cleanName
        let cleanUsername = String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        let cleanPassword = String(password.prefix(512))
        let cleanEPGURL: URL?
        if let epgURL, !epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanEPGURL = try AppleIPTVEndpointPolicy.normalize(epgURL)
        } else {
            cleanEPGURL = nil
        }
        let cleanValidationSummary = validationSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(200)) }
        if type == .xtream, cleanUsername.isEmpty || cleanPassword.isEmpty {
            throw AppleIPTVError.missingCredentials
        }

        if let index = sources.firstIndex(where: { candidate in
            guard candidate.kind == .liveTV, candidate.iptvType == type, candidate.url == url else { return false }
            return type == .m3u || (try? iptvCredentials(for: candidate))?.username == cleanUsername
        }) {
            let existing = sources[index]
            let reference = existing.id.uuidString.lowercased()
            try updateIPTVCredentials(
                type: type,
                reference: reference,
                username: cleanUsername,
                password: cleanPassword
            )
            sources[index] = try securedTransportSource(AppleSource(
                id: existing.id,
                kind: .liveTV,
                name: displayName,
                url: url,
                isEnabled: true,
                addedAt: existing.addedAt,
                iptvType: type,
                epgURL: cleanEPGURL,
                credentialReference: type == .xtream ? reference : nil,
                transportReference: existing.transportReference,
                configurationRevision: nextConfigurationRevision(existing.configurationRevision),
                lastValidatedAt: lastValidatedAt,
                validationSummary: cleanValidationSummary,
                lastValidationFailureAt: existing.lastValidationFailureAt,
                validationFailureSummary: existing.validationFailureSummary,
                discoveredItemCount: discoveredItemCount,
                capabilities: capabilities
            ))
            persist()
            return sources[index]
        }

        let id = UUID()
        let reference = id.uuidString.lowercased()
        try updateIPTVCredentials(
            type: type,
            reference: reference,
            username: cleanUsername,
            password: cleanPassword
        )
        let source = try securedTransportSource(AppleSource(
            id: id,
            kind: .liveTV,
            name: displayName,
            url: url,
            iptvType: type,
            epgURL: cleanEPGURL,
            credentialReference: type == .xtream ? reference : nil,
            lastValidatedAt: lastValidatedAt,
            validationSummary: cleanValidationSummary,
            discoveredItemCount: discoveredItemCount,
            capabilities: capabilities
        ))
        sources.append(source)
        persist()
        return source
    }

    @discardableResult
    public func addLibraryFolder(name: String, url: URL, bookmarkData: Data?) throws -> AppleSource {
        guard url.isFileURL else { throw AppleLibrarySourceError.invalidFolder }
        let url = url.standardizedFileURL
        let isManagedImports = url == managedImportsDirectory
        let bookmarkData = isManagedImports ? nil : bookmarkData
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? url.lastPathComponent : cleanName
        if let index = sources.firstIndex(where: { $0.kind == .library && $0.url == url }) {
            sources[index].name = displayName
            sources[index].isEnabled = true
            sources[index].bookmarkData = bookmarkData
            sources[index].isManagedImports = isManagedImports
            sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
            sources[index].lastValidatedAt = .now
            sources[index].validationSummary = "Folder access granted"
            sources[index].capabilities = ["Files", "Playback"]
            persist()
            return sources[index]
        }
        let source = AppleSource(
            kind: .library,
            name: displayName,
            url: url,
            bookmarkData: bookmarkData,
            isManagedImports: isManagedImports,
            lastValidatedAt: .now,
            validationSummary: "Folder access granted",
            capabilities: ["Files", "Playback"]
        )
        sources.append(source)
        persist()
        return source
    }

    @discardableResult
    public func addNetworkShare(
        name: String,
        host: String,
        port: Int = 445,
        share: String,
        path: String = "",
        username: String = "",
        password: String = "",
        domain: String = "",
        displayHost: String? = nil,
        lastValidatedAt: Date? = nil,
        validationSummary: String? = nil,
        discoveredItemCount: Int? = nil,
        capabilities: [String] = []
    ) throws -> AppleSource {
        let url = try AppleSMBEndpointPolicy.makeURL(host: host, port: port, share: share, path: path)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? share : cleanName
        let cleanDisplayHost = (displayHost ?? host)
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedDisplayHost = cleanDisplayHost.isEmpty ? nil : String(cleanDisplayHost.prefix(256))
        let credentials = AppleSMBCredentials(
            username: String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512)),
            password: String(password.prefix(512)),
            domain: String(domain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        )
        let cleanValidationSummary = validationSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(200)) }

        if let index = sources.firstIndex(where: { $0.kind == .nas && $0.url == url }) {
            let reference = sources[index].credentialReference ?? sources[index].id.uuidString.lowercased()
            try updateNetworkCredentials(credentials, reference: reference)
            sources[index].name = displayName
            sources[index].isEnabled = true
            sources[index].credentialReference = reference
            sources[index].networkDisplayHost = boundedDisplayHost
            sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
            sources[index].lastValidatedAt = lastValidatedAt
            sources[index].validationSummary = cleanValidationSummary
            sources[index].discoveredItemCount = discoveredItemCount.map { min(max($0, 0), 1_000_000) }
            sources[index].capabilities = boundedCapabilities(capabilities)
            persist()
            return sources[index]
        }

        let id = UUID()
        let reference = id.uuidString.lowercased()
        try updateNetworkCredentials(credentials, reference: reference)
        let source = AppleSource(
            id: id,
            kind: .nas,
            name: displayName,
            url: url,
            credentialReference: reference,
            lastValidatedAt: lastValidatedAt,
            validationSummary: cleanValidationSummary,
            discoveredItemCount: discoveredItemCount,
            capabilities: capabilities,
            networkDisplayHost: boundedDisplayHost
        )
        sources.append(source)
        persist()
        return source
    }

    public func recordValidationSuccess(
        id: AppleSource.ID,
        summary: String,
        discoveredItemCount: Int? = nil,
        capabilities: [String]? = nil,
        at date: Date = .now
    ) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].lastValidatedAt = date
        sources[index].validationSummary = boundedStatus(summary)
        sources[index].discoveredItemCount = discoveredItemCount.map { min(max($0, 0), 1_000_000) }
        if let capabilities {
            sources[index].capabilities = boundedCapabilities(capabilities)
        }
        persist()
    }

    public func recordValidationFailure(
        id: AppleSource.ID,
        summary: String,
        at date: Date = .now
    ) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].lastValidationFailureAt = date
        sources[index].validationFailureSummary = boundedStatus(summary) ?? "Connection failed"
        persist()
    }

    @discardableResult
    public func remove(id: AppleSource.ID) -> Bool {
        guard let source = sources.first(where: { $0.id == id }) else {
            appleTrace("remove source \(id): not in the list")
            return false
        }
        appleTrace("remove source \"\(source.name)\" (\(source.kind))")
        let references = [source.credentialReference, source.transportReference].compactMap { $0 }
        pendingCredentialCleanupReferences.append(contentsOf: references)
        pendingCredentialCleanupReferences = Array(Set(pendingCredentialCleanupReferences)).sorted()
        persistPendingCredentialCleanup()
        sources.removeAll { $0.id == id }
        persist()
        retryPendingCredentialCleanup()
        if source.kind == .nas {
            Task { await AppleSMBRangeServer.shared.removeAllSessions() }
        }
        return true
    }

    public func iptvCredentials(for source: AppleSource) throws -> AppleIPTVCredentials? {
        guard source.kind == .liveTV, source.iptvType == .xtream else { return nil }

        var references: [String] = []
        if let reference = source.credentialReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty,
           !references.contains(reference) {
            references.append(reference)
        }
        if let transportReference = source.transportReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transportReference.isEmpty,
           !references.contains(transportReference) {
            references.append(transportReference)
        }
        let sourceReference = source.id.uuidString.lowercased()
        if !references.contains(sourceReference) {
            references.append(sourceReference)
        }

        var lastLookupError: (any Swift.Error)?
        for reference in references {
            do {
                guard let value = try keychain.string(for: reference),
                      let data = value.data(using: .utf8) else { continue }
                let credentials = try JSONDecoder().decode(AppleIPTVCredentials.self, from: data)
                if source.credentialReference != reference, let index = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[index].credentialReference = reference
                    sources[index].legacyUsername = nil
                    sources[index].legacyPassword = nil
                    persist()
                }
                return credentials
            } catch is DecodingError {
                lastLookupError = AppleKeychainStoreError.invalidData
            } catch {
                lastLookupError = error
            }
        }

        let legacyUsername = source.legacyUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyPassword = source.legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !legacyUsername.isEmpty && !legacyPassword.isEmpty {
            let reference = source.credentialReference ?? sourceReference
            try updateIPTVCredentials(type: .xtream, reference: reference, username: legacyUsername, password: legacyPassword)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].credentialReference = reference
                sources[index].legacyUsername = nil
                sources[index].legacyPassword = nil
                persist()
            }
            return AppleIPTVCredentials(username: legacyUsername, password: legacyPassword)
        }

        if let lastLookupError { credentialError = lastLookupError.localizedDescription }
        return nil
    }

    public func networkCredentials(for source: AppleSource) throws -> AppleSMBCredentials? {
        guard source.kind == .nas,
              let reference = source.credentialReference,
              let value = try keychain.string(for: reference),
              let data = value.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(AppleSMBCredentials.self, from: data)
    }

    private func updateIPTVCredentials(
        type: AppleIPTVSourceType,
        reference: String,
        username: String,
        password: String
    ) throws {
        if type == .xtream {
            let credentials = AppleIPTVCredentials(username: username, password: password)
            let data = try JSONEncoder().encode(credentials)
            guard let value = String(data: data, encoding: .utf8) else {
                throw AppleKeychainStoreError.invalidData
            }
            try keychain.set(value, for: reference)
        } else {
            try keychain.remove(reference)
        }
        credentialError = nil
    }

    private func updateNetworkCredentials(_ credentials: AppleSMBCredentials, reference: String) throws {
        let data = try JSONEncoder().encode(credentials)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AppleKeychainStoreError.invalidData
        }
        try keychain.set(value, for: reference)
        credentialError = nil
    }

    private func boundedStatus(_ value: String) -> String? {
        value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map(AppleDiagnosticRedactor.redact)
            .map { String($0.prefix(200)) }
    }

    private func boundedCapabilities(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let bounded = String(clean.prefix(40))
            guard seen.insert(bounded.lowercased()).inserted else { return nil }
            return bounded
        }.prefix(16).map { $0 }
    }

    private func nextConfigurationRevision(_ current: Int) -> Int {
        current == .max ? 1 : max(current + 1, 1)
    }

    private func migrateLegacyIPTVCredentials() {
        var didMigrate = false
        for index in sources.indices {
            guard sources[index].kind == .liveTV,
                  sources[index].iptvType == .xtream,
                  let username = sources[index].legacyUsername,
                  !username.isEmpty,
                  let password = sources[index].legacyPassword,
                  !password.isEmpty else { continue }
            let reference = sources[index].credentialReference
                ?? sources[index].id.uuidString.lowercased()
            do {
                try updateIPTVCredentials(
                    type: .xtream,
                    reference: reference,
                    username: username,
                    password: password
                )
                sources[index].credentialReference = reference
                sources[index].legacyUsername = nil
                sources[index].legacyPassword = nil
                didMigrate = true
            } catch {
                credentialError = error.localizedDescription
            }
        }
        if didMigrate { persist() }
    }

    private var logoBackfillKey: String { storageKey + ".logo-backfill" }

    /// One-time fill for add-ons saved before plain `http://` logos were
    /// accepted: fetch each logo-less manifest in the background and store
    /// its logo through `applyManifest`. A source whose manifest answered is
    /// not asked again (with or without a logo); a transport failure retries
    /// on the next load. Nothing is surfaced in the UI. The delay lets a
    /// short-lived store (one built only to read `sources`) go away before
    /// any request is made.
    private func scheduleLogoBackfill() {
        let attempted = Set(defaults.stringArray(forKey: logoBackfillKey) ?? [])
        let pending = sources
            .filter { $0.kind == .stremio && $0.logoURL == nil && !attempted.contains($0.id.uuidString) }
            .map(\.id)
        guard !pending.isEmpty else { return }
        Task { [weak self, delay = logoBackfillDelay] in
            try? await Task.sleep(for: delay)
            for id in pending {
                guard let self, !Task.isCancelled else { return }
                await self.backfillLogo(id: id)
            }
        }
    }

    private func backfillLogo(id: AppleSource.ID) async {
        guard let source = sources.first(where: { $0.id == id }),
              source.kind == .stremio,
              source.logoURL == nil else { return }
        guard let loaded = try? await manifestClient.load(source.url.absoluteString) else { return }
        applyManifest(loaded.1, to: id)
        var attempted = Set(defaults.stringArray(forKey: logoBackfillKey) ?? [])
        attempted.insert(id.uuidString)
        let live = Set(sources.map { $0.id.uuidString })
        defaults.set(attempted.intersection(live).sorted(), forKey: logoBackfillKey)
    }

    private func relocateManagedImports() {
        var changed = false
        for index in sources.indices where sources[index].kind == .library {
            let source = sources[index]
            let parts = source.url.standardizedFileURL.pathComponents
            // Older portal imports had no bookmark or ownership marker. Only
            // recognize the app-container Documents/Imports layout, never an
            // arbitrary external folder named Imports or a granted bookmark.
            let legacyImports = source.bookmarkData == nil && source.url.isFileURL
                && parts.count >= 7
                && Array(parts.suffix(6).prefix(3)) == ["Containers", "Data", "Application"]
                && UUID(uuidString: parts[parts.count - 3]) != nil
                && Array(parts.suffix(2)) == ["Documents", "Imports"]
            guard source.isManagedImports || legacyImports else { continue }
            guard source.url != managedImportsDirectory || !source.isManagedImports || source.bookmarkData != nil else { continue }
            sources[index].url = managedImportsDirectory
            sources[index].isManagedImports = true
            sources[index].bookmarkData = nil
            sources[index].configurationRevision = nextConfigurationRevision(source.configurationRevision)
            changed = true
        }
        if changed { persist() }
    }

    private func securedTransportSource(_ source: AppleSource) throws -> AppleSource {
        guard Self.protectsTransportURL(source) else { return source }
        var secured = source
        let reference = source.transportReference ?? "transport.\(source.id.uuidString.lowercased())"
        try keychain.set(source.url.absoluteString, for: reference)
        secured.transportReference = reference
        return secured
    }

    private func hydrateProtectedTransportURLs() {
        var migrated = false
        for index in sources.indices where Self.protectsTransportURL(sources[index]) {
            if let reference = sources[index].transportReference {
                do {
                    guard let stored = try keychain.string(for: reference),
                          let url = URL(string: stored),
                          url.scheme != nil else {
                        credentialError = "A saved source address is unavailable. Re-add that source."
                        continue
                    }
                    sources[index].url = url
                } catch {
                    credentialError = error.localizedDescription
                }
                continue
            }
            do {
                sources[index] = try securedTransportSource(sources[index])
                migrated = true
            } catch {
                credentialError = error.localizedDescription
            }
        }
        if migrated { persist() }
    }

    private func retryPendingCredentialCleanup() {
        guard !pendingCredentialCleanupReferences.isEmpty else { return }
        let activeReferences = Set(sources.flatMap { source in
            [source.credentialReference, source.transportReference].compactMap { $0 }
        })
        var failed: [String] = []
        for reference in pendingCredentialCleanupReferences {
            guard !activeReferences.contains(reference) else {
                failed.append(reference)
                continue
            }
            do {
                try keychain.remove(reference)
            } catch {
                failed.append(reference)
                credentialError = error.localizedDescription
            }
        }
        pendingCredentialCleanupReferences = failed
        persistPendingCredentialCleanup()
        if failed.isEmpty { credentialError = nil }
    }

    private func persistPendingCredentialCleanup() {
        let key = storageKey + ".pending-keychain-removals"
        if pendingCredentialCleanupReferences.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(pendingCredentialCleanupReferences, forKey: key)
        }
    }

    private func persist() {
        // Each of these refusals is correct — they protect a stored list from
        // being replaced by an empty or credential-leaking one — but they are
        // also indistinguishable from a successful save until the next launch
        // shows the source gone. Say which one fired.
        guard !(protectsStoredBlobWhenEmpty && sources.isEmpty) else {
            appleTraceFailure("sources not saved: refusing to overwrite the stored list with an empty one")
            return
        }
        guard !sources.contains(where: { $0.legacyUsername != nil || $0.legacyPassword != nil }) else {
            appleTraceFailure("sources not saved: a source still holds legacy inline credentials")
            return
        }
        guard !sources.contains(where: {
            Self.protectsTransportURL($0) && $0.transportReference == nil
        }) else {
            appleTraceFailure("sources not saved: a protected source has no transport reference")
            return
        }
        let persistedSources = sources.map { source -> AppleSource in
            guard Self.protectsTransportURL(source) else { return source }
            var sanitized = source
            sanitized.url = Self.sanitizedTransportURL(source)
            return sanitized
        }
        var members: [Any] = persistedSources.compactMap { source in
            guard let data = try? JSONEncoder().encode(source) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        members.append(contentsOf: preservedUnknownSourcePayloads.compactMap {
            try? JSONSerialization.jsonObject(with: $0)
        })
        guard let encoded = try? JSONSerialization.data(withJSONObject: members) else {
            appleTraceFailure("sources not saved: the list could not be encoded")
            return
        }
        defaults.set(encoded, forKey: storageKey)
        protectsStoredBlobWhenEmpty = false
        appleTrace("sources saved: \(sources.count)")
    }

    private static func protectsTransportURL(_ source: AppleSource) -> Bool {
        source.kind == .stremio || source.kind == .liveTV
    }

    private static func sanitizedTransportURL(_ source: AppleSource) -> URL {
        guard var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false) else {
            return URL(string: "https://source.invalid/")!
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = source.kind == .stremio ? "/manifest.json" : "/"
        return components.url ?? URL(string: "https://source.invalid/")!
    }

    private static func isEmptyStoredList(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "[]"
    }
}

private extension String {
    var nonEmptyAppleSourceString: String? { isEmpty ? nil : self }
}

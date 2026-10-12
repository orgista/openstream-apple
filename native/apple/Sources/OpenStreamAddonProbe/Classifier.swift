#if OPENSTREAM_ADDONS
import Foundation
import OpenStreamApple

/// Turns the app's errors plus the recorded raw response into a groupable
/// cause. It never re-decides validity for the app: the app's client has
/// already said pass or fail; this only explains the failure.
///
/// Cause families:
/// - `decode:…`       the add-on answered 2xx with JSON the app rejected
///                    (the DECODE FAILURES section; app-side suspects)
/// - `bad-response:…` the add-on answered 2xx with something unusable
/// - `http:N`, `transport:…`, `timeout`, `url-policy:…`, `manifest:…`
enum Classifier {
    static func cause(of error: any Error) -> String {
        switch error {
        case is ProbeTimeout:
            return "timeout"
        case is CancellationError:
            return "cancelled"
        case let value as AppleManifestURLPolicy.Error:
            return "url-policy:\(caseName(value))"
        case let value as AppleManifestClientError:
            if case .requestFailed(let status) = value { return "http:\(status)" }
            return "manifest:\(caseName(value))"
        case let value as AppleStremioCatalogError:
            if case .requestFailed(let status) = value { return "http:\(status)" }
            return "catalog:\(caseName(value))"
        case let value as AppleStremioPlaybackError:
            if case .requestFailed(let status) = value { return "http:\(status)" }
            return "playback:\(caseName(value))"
        case let value as URLError:
            return "transport:\(urlErrorName(value.code))"
        default:
            let nsError = error as NSError
            return "other:\(nsError.domain):\(nsError.code)"
        }
    }

    /// `requestFailed(404)` → `requestFailed`; `manifestMissingField("id")` → `manifestMissingField(id)`.
    static func caseName(_ value: Any) -> String {
        String(describing: value).replacingOccurrences(of: "\"", with: "")
    }

    static func urlErrorName(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timedOut"
        case .cannotFindHost: "cannotFindHost"
        case .cannotConnectToHost: "cannotConnectToHost"
        case .networkConnectionLost: "connectionLost"
        case .dnsLookupFailed: "dnsLookupFailed"
        case .secureConnectionFailed: "tlsFailed"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: "badCertificate"
        case .badServerResponse: "badServerResponse"
        case .httpTooManyRedirects: "tooManyRedirects"
        case .redirectToNonExistentLocation: "badRedirect"
        case .appTransportSecurityRequiresSecureConnection: "atsBlockedHTTP"
        case .cancelled: "cancelled"
        case .badURL, .unsupportedURL: "badURL"
        case .zeroByteResource: "zeroByteResource"
        case .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse: "cannotParseResponse"
        case .dataLengthExceedsMaximum: "tooLarge"
        default: "urlError\(code.rawValue)"
        }
    }

    /// The HTTP / transport failure hidden behind a generic app error, taken
    /// from what the recorder saw.
    static func transportCause(_ exchange: RecordedExchange?) -> String? {
        guard let exchange else { return nil }
        if let error = exchange.error { return error }
        if let status = exchange.status, !(200 ... 299).contains(status) { return "http:\(status)" }
        return nil
    }

    static func json(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func looksLikeHTML(_ exchange: RecordedExchange?) -> Bool {
        if exchange?.contentType?.lowercased().contains("html") == true { return true }
        guard let data = exchange?.body?.prefix(256), let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html")
    }

    /// For a response body the app refused: not JSON / HTML / wrong root / missing key.
    static func bodyShape(_ exchange: RecordedExchange?, expectedKey: String) -> String {
        guard let exchange, let body = exchange.body else { return "bad-response:no-body" }
        if body.isEmpty { return "bad-response:empty-body" }
        guard let document = json(body) else {
            return looksLikeHTML(exchange) ? "bad-response:html-page" : "bad-response:not-json"
        }
        guard let object = document as? [String: Any] else { return "bad-response:root-not-object" }
        guard let value = object[expectedKey], !(value is NSNull) else {
            if object["err"] != nil || object["error"] != nil { return "bad-response:error-object" }
            return "bad-response:no-\(expectedKey)-key"
        }
        if expectedKey == "meta" {
            return value is [String: Any] ? "decode:\(expectedKey)-rejected" : "bad-response:\(expectedKey)-not-object"
        }
        return value is [Any] ? "decode:\(expectedKey)-rejected" : "bad-response:\(expectedKey)-not-list"
    }
}

// MARK: - Raw manifest reading (observation only; the app's decoder decides)

struct RawManifest {
    let object: [String: Any]

    init?(_ data: Data?) {
        guard let object = Classifier.json(data) as? [String: Any] else { return nil }
        self.object = object
    }

    var types: [String] { strings(object["types"]) }
    var idPrefixes: [String] { strings(object["idPrefixes"]) }

    var resourceNames: [String] {
        (object["resources"] as? [Any] ?? []).compactMap { entry in
            if let name = entry as? String { return name }
            return (entry as? [String: Any])?["name"] as? String
        }
    }

    var catalogs: [[String: Any]] { (object["catalogs"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    /// Stremio's spec: `id`, `name`, `version` strings; `resources`, `types`, `catalogs` lists.
    var isSpecValid: Bool {
        ["id", "name", "version"].allSatisfy { (object[$0] as? String)?.isEmpty == false }
            && object["resources"] is [Any]
            && object["types"] is [Any]
            && (object["catalogs"] == nil || object["catalogs"] is [Any])
    }

    /// Whether the add-on says `resource` serves `id` of `type`, per the
    /// resource object's own `types`/`idPrefixes` or the manifest's top level.
    func serves(_ resource: String, type: String, id: String) -> Bool {
        let entries = object["resources"] as? [Any] ?? []
        for entry in entries {
            if let name = entry as? String, name.lowercased() == resource {
                return matches(types: types, prefixes: object["idPrefixes"] == nil ? nil : idPrefixes, type: type, id: id)
            }
            if let dict = entry as? [String: Any], (dict["name"] as? String)?.lowercased() == resource {
                let resourceTypes = dict["types"] == nil ? types : strings(dict["types"])
                let prefixes: [String]? = dict["idPrefixes"] != nil ? strings(dict["idPrefixes"])
                    : (object["idPrefixes"] == nil ? nil : idPrefixes)
                return matches(types: resourceTypes, prefixes: prefixes, type: type, id: id)
            }
        }
        return false
    }

    /// The id prefixes for `resource` (resource-level first), empty when unrestricted.
    func prefixes(for resource: String) -> [String] {
        for entry in object["resources"] as? [Any] ?? [] {
            if let dict = entry as? [String: Any], (dict["name"] as? String)?.lowercased() == resource,
               dict["idPrefixes"] != nil {
                return strings(dict["idPrefixes"])
            }
        }
        return idPrefixes
    }

    private func matches(types: [String], prefixes: [String]?, type: String, id: String) -> Bool {
        let typeOK = types.isEmpty || types.contains { $0.lowercased() == type }
        let prefixOK = prefixes.map { list in list.contains { !$0.isEmpty && id.hasPrefix($0) } } ?? true
        return typeOK && prefixOK
    }

    private func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }
}

// MARK: - Catalog item drop reasons (observation only)

enum CatalogDropAnalysis {
    /// Explains why raw `metas` entries did not become items. The app's decoder
    /// already decided; this assigns each raw entry its first visible reason.
    static func reasons(raw: [Any], catalogType: String, decodedCount: Int) -> [String: Int] {
        var reasons: [String: Int] = [:]
        var seen = Set<String>()
        var accepted = 0
        for (offset, entry) in raw.enumerated() {
            if offset >= 400 { reasons["beyond-400-inspected", default: 0] += 1; continue }
            guard let object = entry as? [String: Any] else { reasons["entry-not-object", default: 0] += 1; continue }
            let idValue = object["id"]
            if let idValue, !(idValue is NSNull), !(idValue is String) {
                reasons["id-not-string", default: 0] += 1; continue
            }
            let id = ((idValue as? String) ?? (object["imdb_id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { reasons["id-missing", default: 0] += 1; continue }
            // The app keeps a poster-only entry; it drops one with neither.
            let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let poster = (object["poster"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasPoster = poster.lowercased().hasPrefix("https://") || poster.lowercased().hasPrefix("http://")
            if name.isEmpty, !hasPoster {
                reasons[object["name"] == nil ? "name-and-poster-missing" : "name-empty-no-poster", default: 0] += 1; continue
            }
            let typeValue = ((object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 } ?? catalogType
            let type = typeValue.lowercased()
            let fits = AppleCatalogDiscoveryPolicy.isTitleType(catalogType)
                ? AppleCatalogDiscoveryPolicy.isTitleType(type) : AppleCatalogDiscoveryPolicy.isShelfType(type)
            if !fits { reasons["item-type-\(type.prefix(20))", default: 0] += 1; continue }
            if !seen.insert("\(type):\(id)").inserted { reasons["duplicate", default: 0] += 1; continue }
            accepted += 1
        }
        let cap = AppleCatalogDiscoveryPolicy.maximumItemsPerCatalog
        if accepted > decodedCount, decodedCount == cap {
            reasons["cap-\(cap)", default: 0] += accepted - decodedCount
        } else if accepted > decodedCount {
            reasons["unexplained", default: 0] += accepted - decodedCount
        }
        return reasons
    }
}

#endif

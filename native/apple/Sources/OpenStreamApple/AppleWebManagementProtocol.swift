import Darwin
import Foundation

public struct AppleWebManagementSession: Equatable, Sendable {
    public let url: URL
    public let friendlyURL: URL
    public let expiresAt: Date
    public let token: String
    public let pairingCode: String

    public init(
        url: URL,
        friendlyURL: URL,
        expiresAt: Date,
        token: String,
        pairingCode: String? = nil
    ) {
        self.url = url
        self.friendlyURL = friendlyURL
        self.expiresAt = expiresAt
        self.token = token
        self.pairingCode = pairingCode ?? token
    }

    public var isExpired: Bool { expiresAt <= .now }

    /// The private bootstrap URL is kept for backwards-compatible callers;
    /// the app UI and QR code must use `url`, which never contains a token.
    public var privateURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url ?? url
    }
}

public enum AppleWebManagementProtocol {
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(32)

        for _ in 0 ..< 16 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0f)])
        }

        return String(decoding: encoded, as: UTF8.self)
    }

    public static func makePairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0 ..< 8).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public static func parseForm(_ body: String) -> [String: String] {
        body.split(separator: "&", omittingEmptySubsequences: false).reduce(into: [:]) { result, rawPair in
            let pair = String(rawPair)
            guard let separator = pair.firstIndex(of: "=") else { return }
            let rawKey = String(pair[..<separator])
            let rawValue = String(pair[pair.index(after: separator)...])
            guard let key = formDecode(rawKey), let value = formDecode(rawValue) else { return }
            result[key] = value
        }
    }

    /// Decodes a browser form body by its declared content type. Browsers post
    /// `application/x-www-form-urlencoded` by default; `multipart/form-data`
    /// arrives from forms that declare it and from some in-app browsers.
    /// File parts are ignored; only named text fields are returned.
    public static func parseForm(body: Data, contentType: String?) -> [String: String] {
        if let contentType, let boundary = multipartBoundary(contentType) {
            return parseMultipart(body, boundary: boundary)
        }
        return parseForm(String(decoding: body, as: UTF8.self))
    }

    static func multipartBoundary(_ contentType: String) -> String? {
        let parts = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first?.lowercased() == "multipart/form-data" else { return nil }
        for part in parts.dropFirst() where part.lowercased().hasPrefix("boundary=") {
            var value = String(part.dropFirst("boundary=".count))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty, value.utf8.count <= 70,
                  !value.contains("\r"), !value.contains("\n") else { return nil }
            return value
        }
        return nil
    }

    static func parseMultipart(_ body: Data, boundary: String) -> [String: String] {
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        var delimiters: [Range<Data.Index>] = []
        var cursor = body.startIndex
        while cursor < body.endIndex, let found = body.range(of: delimiter, in: cursor ..< body.endIndex) {
            delimiters.append(found)
            cursor = found.upperBound
        }

        var fields: [String: String] = [:]
        for (index, delimiterRange) in delimiters.enumerated() {
            let partEnd = index + 1 < delimiters.count ? delimiters[index + 1].lowerBound : body.endIndex
            var part = body[delimiterRange.upperBound ..< partEnd]
            if part.starts(with: Data("--".utf8)) { break }
            guard part.starts(with: crlf) else { continue }
            part = part.dropFirst(2)
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerText = String(decoding: part[part.startIndex ..< headerEnd.lowerBound], as: UTF8.self)
            var value = part[headerEnd.upperBound ..< part.endIndex]
            if value.count >= 2, value.suffix(2).elementsEqual(crlf) {
                value = value.dropLast(2)
            }
            guard let name = multipartFieldName(headerText) else { continue }
            fields[name] = String(decoding: value, as: UTF8.self)
        }
        return fields
    }

    private static func multipartFieldName(_ headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            let segments = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.first?.lowercased() == "content-disposition: form-data" else { continue }
            if segments.dropFirst().contains(where: { $0.lowercased().hasPrefix("filename=") }) {
                return nil
            }
            for segment in segments.dropFirst() where segment.lowercased().hasPrefix("name=") {
                var value = String(segment.dropFirst("name=".count))
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    public static func isAllowedClient(host: String) -> Bool {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        normalized = normalized.split(separator: "%", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if normalized == "localhost" { return true }
        if normalized.hasPrefix("::ffff:") {
            return isAllowedClient(host: String(normalized.dropFirst("::ffff:".count)))
        }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        if components.count == 4 {
            let octets = components.compactMap { UInt8($0) }
            guard octets.count == components.count else { return false }
            return switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168): true
            case (172, 16 ... 31): true
            default: false
            }
        }

        var address = in6_addr()
        let parsed = normalized.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
            return loopback || uniqueLocal
        }
    }

    public static func isValidOrigin(_ value: String?, session: AppleWebManagementSession) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.lowercased() != "null", let origin = URLComponents(string: trimmed) else { return false }
        guard let scheme = origin.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard origin.user == nil, origin.password == nil else { return false }
        guard let host = origin.host?.lowercased() else { return false }

        let allowed = [session.url, session.friendlyURL]
        return allowed.contains { candidate in
            candidate.scheme?.lowercased() == scheme
                && candidate.host?.lowercased() == host
                && effectivePort(candidate) == effectivePort(origin)
        }
    }

    public static func isValidHost(_ value: String?, session: AppleWebManagementSession) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let authority = URLComponents(string: "http://\(trimmed)"),
              authority.user == nil,
              authority.password == nil,
              authority.path.isEmpty,
              authority.query == nil,
              authority.fragment == nil,
              let host = authority.host?.lowercased() else { return false }
        return [session.url, session.friendlyURL].contains { candidate in
            candidate.host?.lowercased() == host
                && effectivePort(candidate) == (authority.port ?? 80)
        }
    }

    /// State-changing browser requests require a concrete same-origin source.
    /// A capability token alone cannot distinguish the intended browser from a
    /// DNS-rebinding page that learned the token from an unauthenticated GET.
    public static func isValidRequestSource(
        origin: String?,
        referer: String?,
        session: AppleWebManagementSession
    ) -> Bool {
        if let origin = meaningfulBrowserSource(origin),
           origin.caseInsensitiveCompare("null") != .orderedSame {
            return isValidOrigin(origin, session: session)
        }
        if let referer = meaningfulBrowserSource(referer),
           referer.caseInsensitiveCompare("about:blank") != .orderedSame,
           referer.caseInsensitiveCompare("null") != .orderedSame {
            return isValidOrigin(referer, session: session)
        }
        return false
    }

    /// Accepts a request whose browser source is either the portal itself or
    /// absent. Safari suppresses `Referer` on same-origin form posts and some
    /// browsers send no `Origin` at all, so demanding one of them rejected
    /// ordinary phone submissions. Absence is safe here because the caller has
    /// already required a LAN client, a matching `Host` header, and a valid
    /// token or pairing code; a rebinding page cannot satisfy the `Host` check,
    /// and it would send its own `Origin`, which is still rejected.
    public static func isTrustedRequestSource(
        origin: String?,
        referer: String?,
        session: AppleWebManagementSession
    ) -> Bool {
        guard meaningfulBrowserSource(origin) != nil || meaningfulBrowserSource(referer) != nil else {
            return true
        }
        return isValidRequestSource(origin: origin, referer: referer, session: session)
    }

    public static func hasValidToken(
        form: [String: String],
        headers: [String: String],
        query: [String: String],
        session: AppleWebManagementSession
    ) -> Bool {
        let normalizedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let cookie = normalizedHeaders["cookie"].flatMap(cookieToken)
        let candidate = form["token"] ?? normalizedHeaders["x-setup-token"] ?? cookie
        guard let candidate else { return false }
        return constantTimeEqual(candidate, session.token)
    }

    public static func hasValidPairingCode(
        form: [String: String],
        session: AppleWebManagementSession
    ) -> Bool {
        guard let candidate = form["pairingCode"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return false }
        return constantTimeEqual(candidate.uppercased(), session.pairingCode.uppercased())
    }

    private static func formDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func meaningfulBrowserSource(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func effectivePort(_ components: URLComponents) -> Int {
        components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func cookieToken(_ value: String) -> String? {
        cookieValue("openstream_token", in: value)
    }

    /// One named cookie out of a `Cookie:` header, or nil.
    public static func cookieValue(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        let wanted = name.lowercased()
        return header.split(separator: ";").lazy.compactMap { pair -> String? in
            let value = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = value.firstIndex(of: "=") else { return nil }
            guard value[..<separator].lowercased() == wanted else { return nil }
            return String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }.first
    }

    /// Constant-time comparison for anything secret, exposed so callers outside
    /// this type compare the same way rather than reaching for `==`.
    public static func secretsMatch(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(lhs, rhs)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8.zero) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

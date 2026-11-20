import Foundation

/// Non-secret connection fields survive independently of device-local credentials.
public struct AppleSourceConnectionConfiguration: Codable, Equatable, Sendable {
    public var username: String?
    public var domain: String?
    public var requiresCredentials: Bool?

    public init(username: String? = nil, domain: String? = nil, requiresCredentials: Bool? = nil) {
        self.username = username
        self.domain = domain
        self.requiresCredentials = requiresCredentials
    }

    init(credentials: AppleSMBCredentials) {
        self.init(username: credentials.username, domain: credentials.domain,
                  requiresCredentials: !credentials.username.isEmpty || !credentials.password.isEmpty)
    }

    init(session: AppleMediaServerSession) {
        self.init(username: session.userName)
    }

    func fillingMissingFields(from local: Self?) -> Self {
        var result = self
        result.username = username ?? local?.username
        result.domain = domain ?? local?.domain
        result.requiresCredentials = requiresCredentials ?? local?.requiresCredentials
        return result
    }

    static func publicURL(_ url: URL) -> URL? {
        guard ["http", "https", "smb"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, host != "source.invalid",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return nil }
        if url.scheme?.lowercased() == "smb" {
            guard (try? AppleSMBEndpointPolicy.parts(from: url)) != nil else { return nil }
        } else {
            let path = url.path.lowercased().split(separator: "/").map(String.init)
            for (index, component) in path.enumerated() {
                if ["live", "movie", "series"].contains(component), path.count - index >= 4 { return nil }
                if ["playlist", "m3u", "xmltv"].contains(component), path.count - index >= 3 { return nil }
                if ["token", "password", "secret", "signature", "credential", "auth", "key"].contains(where: component.contains) { return nil }
            }
        }
        return url
    }
}

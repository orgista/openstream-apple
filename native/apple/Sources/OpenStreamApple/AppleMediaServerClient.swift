import Foundation

public enum AppleMediaServerKind: String, Codable, CaseIterable, Sendable {
    case jellyfin
    case emby
    case plex

    public var title: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        }
    }
}

public struct AppleMediaServerSession: Codable, Equatable, Sendable {
    public let kind: AppleMediaServerKind
    public let baseURL: URL
    public let accessToken: String
    public let userID: String
    public let serverID: String?
    public let serverName: String?
    public let userName: String?
    public var accountToken: String?

    public init(
        kind: AppleMediaServerKind,
        baseURL: URL,
        accessToken: String,
        userID: String,
        serverID: String? = nil,
        serverName: String? = nil,
        userName: String? = nil,
        accountToken: String? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userID = userID
        self.serverID = serverID
        self.serverName = serverName
        self.userName = userName
        self.accountToken = accountToken
    }
}

public struct AppleMediaServerPublicInfo: Codable, Equatable, Sendable {
    public let serverName: String?
    public let version: String?
    public let id: String?
    public let productName: String?

    public var detectedKind: AppleMediaServerKind? {
        if let name = productName, name.localizedCaseInsensitiveContains("Jellyfin") {
            return .jellyfin
        }
        if serverName != nil || version != nil || id != nil || productName != nil {
            return .emby
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
        case productName = "ProductName"
    }

    public init(
        serverName: String? = nil,
        version: String? = nil,
        id: String? = nil,
        productName: String? = nil
    ) {
        self.serverName = serverName
        self.version = version
        self.id = id
        self.productName = productName
    }
}

public enum AppleMediaServerError: Error, Equatable, Sendable {
    case invalidCredentials
    case server(status: Int)
    case malformedResponse
    case unreachable
    case unsupported
    case downloadNotAllowed
}

public struct AppleQuickConnectTicket: Equatable, Sendable {
    public let secret: String
    public let code: String
}

public struct AppleEmbyConnectAccount: Equatable, Sendable {
    public let userID: String
    public let accessToken: String
}

public struct AppleEmbyConnectServer: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: String
    public let localAddress: String
    public let accessKey: String
    
    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case url = "Url"
        case localAddress = "LocalAddress"
        case accessKey = "AccessKey"
    }
}

public struct AppleMediaServerClient: Sendable {
    /// The MediaBrowser header wants a device name; the platform name is enough
    /// and needs no UIKit or `Host` (macOS-only), so this compiles everywhere.
    public static var platformDeviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(visionOS)
        return "Apple Vision Pro"
        #elseif os(macOS)
        return "Mac"
        #else
        return "iPhone or iPad"
        #endif
    }

    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let loader: Loader
    private let deviceID: String
    private let clientName: String
    private let deviceName: String
    private let appVersion: String

    public init(
        loader: @escaping Loader = URLSession.shared.data(for:),
        deviceID: String? = nil,
        clientName: String = "oStream",
        deviceName: String = AppleMediaServerClient.platformDeviceName,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    ) {
        self.loader = loader
        if let id = deviceID {
            self.deviceID = id
        } else {
            if let existing = UserDefaults.standard.string(forKey: "openstream.mediaServer.deviceID.v1") {
                self.deviceID = existing
            } else {
                let new = UUID().uuidString
                UserDefaults.standard.set(new, forKey: "openstream.mediaServer.deviceID.v1")
                self.deviceID = new
            }
        }
        self.clientName = clientName
        self.deviceName = deviceName
        self.appVersion = appVersion
    }

    func normalizedURL(base: URL, path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        var baseStr = base.absoluteString
        if !baseStr.hasSuffix("/") {
            baseStr += "/"
        }
        guard let normalizedBase = URL(string: baseStr),
              var components = URLComponents(url: normalizedBase.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AppleMediaServerError.unreachable
        }
        if let queryItems = queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let finalURL = components.url else {
            throw AppleMediaServerError.unreachable
        }
        return finalURL
    }

    func request(url: URL, method: String = "GET", token: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if url.path.contains("/QuickConnect/") || url.path.hasSuffix("/AuthenticateWithQuickConnect") { req.timeoutInterval = 10 }
        let auth = authorizationHeaderValue(token: token)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        if let t = token {
            req.setValue(t, forHTTPHeaderField: "X-Emby-Token")
        }
        return req
    }

    func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(request)
        } catch {
            throw AppleMediaServerError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppleMediaServerError.malformedResponse
        }
        if http.statusCode == 401 {
            throw AppleMediaServerError.invalidCredentials
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppleMediaServerError.server(status: http.statusCode)
        }
        return data
    }

    func authorizationHeaderValue(token: String?) -> String {
        func escape(_ value: String) -> String {
            return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var base = "MediaBrowser Client=\"\(escape(clientName))\", Device=\"\(escape(deviceName))\", DeviceId=\"\(escape(deviceID))\", Version=\"\(escape(appVersion))\""
        if let token = token {
            base += ", Token=\"\(escape(token))\""
        }
        return base
    }

    public func publicInfo(baseURL: URL) async throws -> AppleMediaServerPublicInfo {
        let url = try normalizedURL(base: baseURL, path: "System/Info/Public")
        let req = request(url: url)
        let data = try await perform(req)
        do {
            return try JSONDecoder().decode(AppleMediaServerPublicInfo.self, from: data)
        } catch {
            throw AppleMediaServerError.malformedResponse
        }
    }

    public func authenticate(baseURL: URL, kind: AppleMediaServerKind, username: String, password: String) async throws -> AppleMediaServerSession {
        let url = try normalizedURL(base: baseURL, path: "Users/AuthenticateByName")
        var req = request(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["Username": username, "Pw": password]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AppleMediaServerError.malformedResponse
        }
        let data = try await perform(req)
        return try decodeSession(from: data, baseURL: baseURL, kind: kind)
    }

    private func decodeSession(from data: Data, baseURL: URL, kind: AppleMediaServerKind) throws -> AppleMediaServerSession {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["User"] as? [String: Any],
              let userID = user["Id"] as? String,
              let accessToken = json["AccessToken"] as? String else {
            throw AppleMediaServerError.malformedResponse
        }
        let userName = user["Name"] as? String
        let serverID = json["ServerId"] as? String
        return AppleMediaServerSession(kind: kind, baseURL: baseURL, accessToken: accessToken, userID: userID, serverID: serverID, serverName: nil, userName: userName)
    }

    public func quickConnectEnabled(baseURL: URL) async throws -> Bool {
        let url = try normalizedURL(base: baseURL, path: "QuickConnect/Enabled")
        let req = request(url: url)
        let data: Data
        do { data = try await perform(req) }
        catch AppleMediaServerError.server(let status) where status == 404 || status == 405 { return false }
        catch AppleMediaServerError.unsupported { return false }
        guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw AppleMediaServerError.malformedResponse
        }
        guard string == "true" || string == "false" else { throw AppleMediaServerError.malformedResponse }
        return string == "true"
    }

    public func quickConnectInitiate(baseURL: URL) async throws -> AppleQuickConnectTicket {
        let url = try normalizedURL(base: baseURL, path: "QuickConnect/Initiate")
        let req = request(url: url, method: "POST")
        let data = try await perform(req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = json["Secret"] as? String,
              let code = json["Code"] as? String else {
            throw AppleMediaServerError.malformedResponse
        }
        return AppleQuickConnectTicket(secret: secret, code: code)
    }

    public func quickConnectState(baseURL: URL, secret: String) async throws -> Bool {
        let url = try normalizedURL(base: baseURL, path: "QuickConnect/Connect", queryItems: [URLQueryItem(name: "secret", value: secret)])
        let req = request(url: url)
        let data = try await perform(req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authenticated = json["Authenticated"] as? Bool else {
            throw AppleMediaServerError.malformedResponse
        }
        return authenticated
    }

    /// Bounded polling with cooperative cancellation. Authentication errors
    /// are surfaced immediately rather than minting a second session.
    public func waitForQuickConnect(
        baseURL: URL, ticket: AppleQuickConnectTicket,
        pollInterval: Duration = .seconds(3), maximumPolls: Int = 40
    ) async throws -> AppleMediaServerSession {
        var consecutiveFailures = 0
        let deadline = ContinuousClock.now + .seconds(120)
        for _ in 0..<max(0, maximumPolls) {
            try await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AppleMediaServerError.unsupported }
            let authenticated: Bool
            do {
                authenticated = try await quickConnectState(baseURL: baseURL, secret: ticket.secret)
                consecutiveFailures = 0
            } catch {
                try Task.checkCancellation()
                consecutiveFailures += 1
                if consecutiveFailures >= 5 { throw error }
                continue
            }
            if authenticated {
                try Task.checkCancellation()
                let session = try await authenticateWithQuickConnect(baseURL: baseURL, secret: ticket.secret)
                try Task.checkCancellation()
                return session
            }
        }
        throw AppleMediaServerError.unsupported
    }

    public func authenticateWithQuickConnect(baseURL: URL, secret: String) async throws -> AppleMediaServerSession {
        let url = try normalizedURL(base: baseURL, path: "Users/AuthenticateWithQuickConnect")
        var req = request(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["Secret": secret]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AppleMediaServerError.malformedResponse
        }
        let data = try await perform(req)
        return try decodeSession(from: data, baseURL: baseURL, kind: .jellyfin)
    }

    // MARK: Emby Connect
    public func embyConnectSignIn(email: String, password: String) async throws -> AppleEmbyConnectAccount {
        guard let url = URL(string: "https://connect.emby.media/service/user/authenticate") else {
            throw AppleMediaServerError.unreachable
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("OpenStream/\(appVersion)", forHTTPHeaderField: "X-Application")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var comp = URLComponents()
        comp.queryItems = [
            URLQueryItem(name: "nameOrEmail", value: email),
            URLQueryItem(name: "rawpw", value: password)
        ]
        let query = comp.query ?? ""
        req.httpBody = query.data(using: .utf8)
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(req)
        } catch {
            throw AppleMediaServerError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppleMediaServerError.malformedResponse
        }
        if http.statusCode == 401 {
            throw AppleMediaServerError.invalidCredentials
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppleMediaServerError.server(status: http.statusCode)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["AccessToken"] as? String,
              let user = json["User"] as? [String: Any],
              let id = user["Id"] as? String else {
            throw AppleMediaServerError.malformedResponse
        }
        return AppleEmbyConnectAccount(userID: id, accessToken: accessToken)
    }

    public func embyConnectServers(account: AppleEmbyConnectAccount) async throws -> [AppleEmbyConnectServer] {
        guard var comp = URLComponents(string: "https://connect.emby.media/service/servers") else {
            throw AppleMediaServerError.unreachable
        }
        comp.queryItems = [URLQueryItem(name: "userId", value: account.userID)]
        guard let url = comp.url else { throw AppleMediaServerError.unreachable }
        
        var req = URLRequest(url: url)
        req.setValue(account.accessToken, forHTTPHeaderField: "X-Connect-UserToken")
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(req)
        } catch {
            throw AppleMediaServerError.unreachable
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppleMediaServerError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        do {
            return try JSONDecoder().decode([AppleEmbyConnectServer].self, from: data)
        } catch {
            throw AppleMediaServerError.malformedResponse
        }
    }

    public func embyConnectExchange(server: AppleEmbyConnectServer, account: AppleEmbyConnectAccount) async throws -> AppleMediaServerSession {
        let serverURLStr = server.url.isEmpty ? server.localAddress : server.url
        guard let base = URL(string: serverURLStr) else { throw AppleMediaServerError.unreachable }
        let url = try normalizedURL(base: base, path: "Connect/Exchange", queryItems: [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "ConnectUserId", value: account.userID)
        ])
        
        var req = URLRequest(url: url)
        req.setValue(server.accessKey, forHTTPHeaderField: "X-Emby-Token")
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(req)
        } catch {
            throw AppleMediaServerError.unreachable
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AppleMediaServerError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let localUserId = json["LocalUserId"] as? String,
              let accessToken = json["AccessToken"] as? String else {
            throw AppleMediaServerError.malformedResponse
        }
        
        return AppleMediaServerSession(
            kind: .emby,
            baseURL: base,
            accessToken: accessToken,
            userID: localUserId,
            serverID: server.id,
            serverName: server.name,
            userName: nil
        )
    }
}


extension AppleMediaServerClient {
    public func downloadsAllowed(session: AppleMediaServerSession) async throws -> Bool {
        let url = try normalizedURL(base: session.baseURL, path: "Users/\(session.userID)")
        let data = try await perform(request(url: url, token: session.accessToken))
        let user = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (user?["Policy"] as? [String: Any])?["EnableContentDownloading"] as? Bool == true
    }

    public func downloadRequest(session: AppleMediaServerSession, itemID: String, allowed: Bool) throws -> URLRequest {
        guard allowed else { throw AppleMediaServerError.downloadNotAllowed }
        guard session.kind != .plex, !itemID.isEmpty,
              !itemID.contains("/"), !itemID.contains("..") else { throw AppleMediaServerError.unsupported }
        let url = try normalizedURL(base: session.baseURL, path: "Items/\(itemID)/Download")
        return request(url: url, token: session.accessToken)
    }
}

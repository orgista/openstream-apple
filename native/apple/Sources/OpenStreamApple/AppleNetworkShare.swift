import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

#if canImport(AMSMB2)
import AMSMB2
#endif

public struct AppleSMBCredentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String
    public let domain: String

    public init(username: String, password: String, domain: String = "") {
        self.username = username
        self.password = password
        self.domain = domain
    }
}

public struct AppleSMBServer: Identifiable, Equatable, Sendable {
    public var id: String { "\(name.lowercased())|\(host.lowercased())|\(port)" }
    public let name: String
    /// Numeric endpoint used for every SMB connection. Bonjour names are not
    /// reliable inputs to AMSMB2, even when they are good display labels.
    public let host: String
    public let displayHost: String
    public let port: Int

    public init(name: String, host: String, port: Int = 445, displayHost: String? = nil) {
        self.name = name
        self.host = AppleSMBEndpointPolicy.normalizedHost(host)
        self.displayHost = AppleSMBEndpointPolicy.normalizedHost(displayHost ?? host)
        self.port = port
    }
}

public struct AppleSMBEndpointInput: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let share: String
    public let path: String

    public init(host: String, port: Int, share: String, path: String) {
        self.host = AppleSMBEndpointPolicy.normalizedHost(host)
        self.port = port
        self.share = share
        self.path = path
    }
}

public struct AppleSMBBonjourService: Equatable, Sendable {
    public let name: String
    public let type: String
    public let domain: String

    public init(name: String, type: String = "_smb._tcp", domain: String = "local") {
        self.name = name
        self.type = type
        self.domain = domain
    }
}

public struct AppleSMBShare: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let comment: String

    public init(name: String, comment: String = "") {
        self.name = name
        self.comment = comment
    }
}

public struct AppleSMBDirectoryEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let modifiedAt: Date?

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        sizeBytes: Int64 = 0,
        modifiedAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

enum AppleSMBDirectoryWalker {
    static func walk(
        root: [AppleSMBDirectoryEntry],
        load: @Sendable (String) async throws -> [AppleSMBDirectoryEntry]
    ) async throws -> [AppleSMBDirectoryEntry] {
        var valuesByPath = Dictionary(uniqueKeysWithValues: root.map { ($0.path, $0) })
        var pending = root.filter(\.isDirectory).map(\.path).sorted(by: localizedPathOrder)
        var visited = Set<String>()
        while let path = pending.first {
            pending.removeFirst()
            guard visited.insert(path).inserted else { continue }
            let nested = try await load(path).sorted(by: { localizedPathOrder($0.path, $1.path) })
            for entry in nested where valuesByPath[entry.path] == nil {
                valuesByPath[entry.path] = entry
            }
            pending = Array(Set(pending + nested.filter(\.isDirectory).map(\.path)))
                .filter { !visited.contains($0) }
                .sorted(by: localizedPathOrder)
        }
        return valuesByPath.values.sorted { localizedPathOrder($0.path, $1.path) }
    }

    private static func localizedPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.localizedStandardCompare(rhs)
        return result == .orderedAscending || (result == .orderedSame && lhs < rhs)
    }
}

public enum AppleSMBError: Error, Equatable, LocalizedError, Sendable {
    case invalidHost
    case invalidPort
    case invalidShare
    case unavailableOnPlatform
    case authenticationFailed
    case accessDenied
    case serverUnreachable
    case connectionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidHost: "Enter a valid SMB server name or IP address."
        case .invalidPort: "The SMB port must be between 1 and 65535."
        case .invalidShare: "Choose an SMB share."
        case .unavailableOnPlatform: "Direct SMB access is unavailable on this platform."
        case .authenticationFailed: "SMB authentication failed. Check the username and password."
        case .accessDenied: "The server refused access to that share. Check the share name and the account’s permissions on the server."
        case .serverUnreachable: "The SMB server is unreachable. Check the host, port, and network connection."
        case .connectionFailed: "OpenStream couldn’t connect to that network share. Check the server, share, and account."
        }
    }

    static func mapped(from error: any Error) -> Self {
        if let error = error as? Self { return error }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           [
               NSURLErrorCannotConnectToHost,
               NSURLErrorTimedOut,
               NSURLErrorNetworkConnectionLost,
               NSURLErrorNotConnectedToInternet
            ].contains(nsError.code) {
            return .serverUnreachable
        }
        // libsmb2 folds NT statuses into errno values in a way that hides the
        // real cause: LOGON_FAILURE becomes ECONNREFUSED and several
        // non-credential statuses become EPERM. Read the status text first.
        let description = "\(error.localizedDescription) \(String(reflecting: error))".lowercased()
        if [
            "logon_failure", "wrong_password", "authentication", "unauthorized",
            "invalid credentials", "password_expired", "account_disabled", "account_locked"
        ].contains(where: description.contains) {
            return .authenticationFailed
        }
        if ["access_denied", "permission denied", "bad_network_name", "privilege_not_held"]
            .contains(where: description.contains) {
            return .accessDenied
        }
        if nsError.domain == NSPOSIXErrorDomain, [EPERM, EACCES].contains(Int32(nsError.code)) {
            return .accessDenied
        }
        if [
            "timed out", "timedout", "host is down", "network is down", "network is unreachable",
            "connection refused", "no route to host", "not connected", "could not connect"
        ].contains(where: description.contains) {
            return .serverUnreachable
        }
        return .connectionFailed
    }
}

public enum AppleSMBEndpointPolicy {
    /// Network.framework can append an interface to IPv4 descriptions. SMB
    /// must receive the numeric address; IPv6 zone identifiers stay intact.
    static func normalizedHost(_ host: String) -> String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix = value.firstIndex(of: "%"),
              IPv4Address(String(value[..<suffix])) != nil else { return value }
        return String(value[..<suffix])
    }

    public static func parseInput(
        host: String,
        port: Int,
        share: String,
        path: String,
        requiresShare: Bool = true
    ) throws -> AppleSMBEndpointInput {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { throw AppleSMBError.invalidHost }

        if cleanHost.contains("://") {
            guard let url = URL(string: cleanHost), url.scheme?.lowercased() == "smb",
                  let serverHost = url.host, !serverHost.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw AppleSMBError.invalidHost
            }
            let pieces = url.path.split(separator: "/").map(String.init)
            let suppliedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
            let suppliedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = AppleSMBEndpointInput(
                host: serverHost,
                port: url.port ?? 445,
                share: suppliedShare.isEmpty ? pieces.first ?? "" : suppliedShare,
                path: suppliedPath.isEmpty ? pieces.dropFirst().joined(separator: "/") : suppliedPath
            )
            try validate(result, requiresShare: requiresShare)
            return result
        }

        let result = AppleSMBEndpointInput(host: cleanHost, port: port, share: share, path: path)
        try validate(result, requiresShare: requiresShare)
        return result
    }

    private static func validate(_ input: AppleSMBEndpointInput, requiresShare: Bool) throws {
        if requiresShare || !input.share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try makeURL(host: input.host, port: input.port, share: input.share, path: input.path)
        } else {
            _ = try serverComponents(host: input.host, port: input.port)
        }
    }

    public static func bonjourService(from host: String) -> AppleSMBBonjourService? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = "._smb._tcp.local"
        guard cleanHost.lowercased().hasSuffix(suffix) else { return nil }
        let instance = String(cleanHost.dropLast(suffix.count))
        guard !instance.isEmpty, !instance.contains("/") else { return nil }
        return AppleSMBBonjourService(name: instance)
    }

    /// Selects the readable endpoint label. The returned hostname is never
    /// used as the SMB connection host when a numeric address is available.
    static func preferredHost(
        bonjourHost: String?,
        ipv4Host: String?,
        ipv6Host: String?
    ) -> String? {
        for candidate in [bonjourHost, ipv4Host, ipv6Host].compactMap({ $0 }) {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !value.isEmpty, !value.contains("/"), !value.contains("@") else { continue }
            return value
        }
        return nil
    }

    /// Selects the host that AMSMB2 should connect to. Numeric IPv4 is the
    /// preferred address, with scoped IPv6 as the fallback.
    static func connectionHost(ipv4Host: String?, ipv6Host: String?) -> String? {
        [ipv4Host, ipv6Host].compactMap { $0 }.first { candidate in
            let value = normalizedHost(candidate)
            return !value.isEmpty && !value.contains("/") && !value.contains("@")
        }.map(normalizedHost)
    }

    static func endpointLabel(host: String, port: Int) -> String {
        let value = host.contains(":") ? "[\(host)]" : host
        return port == 445 ? value : "\(value):\(port)"
    }

    public static func makeURL(host: String, port: Int, share: String, path: String = "") throws -> URL {
        var components = try serverComponents(host: host, port: port)
        let cleanShare = share.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "/")
        ))
        guard !cleanShare.isEmpty, !cleanShare.contains("/") else { throw AppleSMBError.invalidShare }
        let cleanPath = path
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        components.path = "/" + ([cleanShare] + (cleanPath.isEmpty ? [] : [cleanPath])).joined(separator: "/")
        guard let url = components.url else { throw AppleSMBError.invalidHost }
        return url
    }

    private static func serverComponents(host: String, port: Int) throws -> URLComponents {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.lowercased().hasPrefix("smb://") {
            cleanHost = String(cleanHost.dropFirst(6))
        }
        cleanHost = normalizedHost(cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !cleanHost.isEmpty, !cleanHost.contains("@"), !cleanHost.contains("/") else {
            throw AppleSMBError.invalidHost
        }
        guard (1 ... 65_535).contains(port) else { throw AppleSMBError.invalidPort }

        var components = URLComponents()
        components.scheme = "smb"
        if cleanHost.contains(":") {
            // URLComponents requires scoped IPv6 literals to be bracketed and
            // percent-escaped. Bonjour may resolve an SMB service to a link-local
            // address such as fe80::1%en0; dropping the scope makes the endpoint
            // unusable, while passing the raw literal makes URL construction fail.
            let escaped = cleanHost.replacingOccurrences(of: "%", with: "%25")
            components.host = escaped.hasPrefix("[") ? escaped : "[\(escaped)]"
        } else {
            components.host = cleanHost
        }
        if port != 445 { components.port = port }
        guard let url = components.url, url.user == nil, url.password == nil else {
            throw AppleSMBError.invalidHost
        }
        return components
    }

    public static func parts(from url: URL) throws -> (host: String, port: Int, share: String, path: String) {
        guard url.scheme?.lowercased() == "smb", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw AppleSMBError.invalidHost }
        let pieces = url.path.split(separator: "/").map(String.init)
        guard let share = pieces.first, !share.isEmpty else { throw AppleSMBError.invalidShare }
        return (host, url.port ?? 445, share, pieces.dropFirst().joined(separator: "/"))
    }
}

public protocol AppleNetworkShareClient: Sendable {
    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare]
    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws
        -> [AppleSMBDirectoryEntry]
    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data
    func closeAll() async
}

public extension AppleNetworkShareClient {
    func closeAll() async {}
}

public actor AppleSMBClient: AppleNetworkShareClient {
    #if canImport(AMSMB2)
    private struct ConnectionKey: Hashable {
        let host: String
        let port: Int
        let share: String
        let credentialFingerprint: String
    }

    private struct CachedConnection {
        let manager: SMB2Manager
        var lastUsed: Date
    }

    private var connections: [ConnectionKey: CachedConnection] = [:]
    private var pendingConnections: [ConnectionKey: UUID] = [:]
    private var connectionGeneration = 0
    private var idleCleanupTask: Task<Void, Never>?
    #endif

    public init() {}

    public func listShares(
        host: String,
        port: Int = 445,
        credentials: AppleSMBCredentials
    ) async throws -> [AppleSMBShare] {
        #if canImport(AMSMB2)
        do {
            return try await listShares(
                host: host,
                port: port,
                credentials: credentials,
                guestUsername: credentials.username.isEmpty ? "guest" : nil
            )
        } catch {
            guard credentials.username.isEmpty, credentials.password.isEmpty else {
                throw AppleSMBError.mapped(from: error)
            }
            do {
                // Samba configurations vary: some accept the literal guest
                // account, while others map an unknown account to guest.
                return try await listShares(
                    host: host,
                    port: port,
                    credentials: credentials,
                    guestUsername: "anonymous"
                )
            } catch {
                throw AppleSMBError.mapped(from: error)
            }
        }
        #else
        throw AppleSMBError.unavailableOnPlatform
        #endif
    }

    public func listDirectory(
        url: URL,
        credentials: AppleSMBCredentials,
        recursive: Bool = false
    ) async throws -> [AppleSMBDirectoryEntry] {
        #if canImport(AMSMB2)
        let parts = try AppleSMBEndpointPolicy.parts(from: url)
        let key = connectionKey(parts: parts, credentials: credentials)
        let manager = try await connectedManager(key: key, credentials: credentials)
        do {
            var values = try await directoryEntries(manager: manager, path: parts.path)
            if recursive {
                values = try await AppleSMBDirectoryWalker.walk(root: values) { path in
                    try await directoryEntries(manager: manager, path: path)
                }
            }
            connections[key]?.lastUsed = .now
            scheduleIdleCleanup()
            return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let error as AppleSMBError {
            throw error
        } catch {
            await invalidateConnection(key)
            throw AppleSMBError.mapped(from: error)
        }
        #else
        throw AppleSMBError.unavailableOnPlatform
        #endif
    }

    public func read(
        url: URL,
        credentials: AppleSMBCredentials,
        range: Range<UInt64>
    ) async throws -> Data {
        #if canImport(AMSMB2)
        guard range.count <= 8 * 1_024 * 1_024 else { throw AppleSMBError.connectionFailed }
        let parts = try AppleSMBEndpointPolicy.parts(from: url)
        let key = connectionKey(parts: parts, credentials: credentials)
        var lastError: (any Error) = AppleSMBError.connectionFailed
        for attempt in 0 ... 1 {
            try Task.checkCancellation()
            let manager = try await connectedManager(key: key, credentials: credentials)
            do {
                let data = try await manager.contents(atPath: parts.path, range: range)
                try Task.checkCancellation()
                connections[key]?.lastUsed = .now
                scheduleIdleCleanup()
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try Task.checkCancellation()
                await invalidateConnection(key)
                if attempt == 1 { throw AppleSMBError.mapped(from: error) }
            }
        }
        throw AppleSMBError.mapped(from: lastError)
        #else
        throw AppleSMBError.unavailableOnPlatform
        #endif
    }

    public func closeAll() async {
        #if canImport(AMSMB2)
        idleCleanupTask?.cancel()
        idleCleanupTask = nil
        connectionGeneration = connectionGeneration == .max ? 0 : connectionGeneration + 1
        pendingConnections.removeAll()
        let cached = Array(connections.values)
        connections.removeAll()
        for connection in cached {
            try? await connection.manager.disconnectShare()
        }
        #endif
    }

    #if canImport(AMSMB2)
    private func listShares(
        host: String,
        port: Int,
        credentials: AppleSMBCredentials,
        guestUsername: String?
    ) async throws -> [AppleSMBShare] {
        let manager = try manager(
            host: host,
            port: port,
            credentials: credentials,
            usernameOverride: guestUsername
        )
        let shares = try await manager.listShares()
        return shares.map { AppleSMBShare(name: $0.name, comment: $0.comment) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func directoryEntries(manager: SMB2Manager, path: String) async throws -> [AppleSMBDirectoryEntry] {
        let values = try await manager.contentsOfDirectory(atPath: path, recursive: false)
        return values.compactMap { value in
            guard let name = value[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let entryPath = [cleanPath, name].filter { !$0.isEmpty }.joined(separator: "/")
            let isDirectory = Self.isDirectory(value)
            return AppleSMBDirectoryEntry(
                name: name,
                path: entryPath,
                isDirectory: isDirectory,
                sizeBytes: (value[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: value[.contentModificationDateKey] as? Date
            )
        }
    }

    static func isDirectory(_ value: [URLResourceKey: Any]) -> Bool {
        // AMSMB2 publishes isDirectoryKey as NSNumber. Check it before the
        // Swift Bool bridge, which can otherwise turn a true NSNumber into a
        // failed/false cast on some Foundation runtimes.
        if let number = value[.isDirectoryKey] as? NSNumber {
            return number.boolValue
        }
        if let bool = value[.isDirectoryKey] as? Bool {
            return bool
        }
        if let type = value[.fileResourceTypeKey] as? URLFileResourceType,
           type == .directory {
            return true
        }
        if let type = value[.fileResourceTypeKey] as? String,
           type == URLFileResourceType.directory.rawValue {
            return true
        }
        // A few SMB servers omit the resource type but do provide the
        // regular-file bit. This is a safe fallback for ordinary files and
        // directories; symbolic links remain non-directories.
        if let regular = value[.isRegularFileKey] as? NSNumber {
            let symbolic = (value[.isSymbolicLinkKey] as? NSNumber)?.boolValue ?? false
            return !regular.boolValue && !symbolic
        }
        return false
    }

    private func connectionKey(
        parts: (host: String, port: Int, share: String, path: String),
        credentials: AppleSMBCredentials
    ) -> ConnectionKey {
        ConnectionKey(
            host: parts.host.lowercased(),
            port: parts.port,
            share: parts.share,
            credentialFingerprint: ApplePlaybackIdentity.digest(for:
                "\(credentials.domain)|\(credentials.username)|\(credentials.password)"
            )
        )
    }

    private func connectedManager(
        key: ConnectionKey,
        credentials: AppleSMBCredentials
    ) async throws -> SMB2Manager {
        await pruneConnections()
        if let cached = connections[key] {
            connections[key]?.lastUsed = .now
            scheduleIdleCleanup()
            return cached.manager
        }
        guard pendingConnections[key] == nil,
              connections.count + pendingConnections.count < 8 else {
            throw AppleSMBError.connectionFailed
        }
        let generation = connectionGeneration
        let reservation = UUID()
        pendingConnections[key] = reservation
        defer {
            if pendingConnections[key] == reservation {
                pendingConnections.removeValue(forKey: key)
            }
        }
        let manager = try manager(host: key.host, port: key.port, credentials: credentials)
        do {
            try await manager.connectShare(name: key.share)
            guard generation == connectionGeneration else {
                throw AppleSMBError.connectionFailed
            }
            connections[key] = CachedConnection(manager: manager, lastUsed: .now)
            scheduleIdleCleanup()
            return manager
        } catch {
            try? await manager.disconnectShare()
            guard credentials.username.isEmpty, credentials.password.isEmpty else {
                throw AppleSMBError.mapped(from: error)
            }
            do {
                let guestManager = try self.manager(
                    host: key.host,
                    port: key.port,
                    credentials: credentials,
                    usernameOverride: "anonymous"
                )
                try await guestManager.connectShare(name: key.share)
                guard generation == connectionGeneration else {
                    throw AppleSMBError.connectionFailed
                }
                connections[key] = CachedConnection(manager: guestManager, lastUsed: .now)
                scheduleIdleCleanup()
                return guestManager
            } catch {
                throw AppleSMBError.mapped(from: error)
            }
        }
    }

    private func pruneConnections() async {
        let cutoff = Date.now.addingTimeInterval(-5 * 60)
        let stale = connections.filter { $0.value.lastUsed < cutoff }.map(\.key)
        for key in stale { await invalidateConnection(key) }
    }

    private func invalidateConnection(_ key: ConnectionKey) async {
        guard let cached = connections.removeValue(forKey: key) else { return }
        try? await cached.manager.disconnectShare()
    }

    private func scheduleIdleCleanup() {
        idleCleanupTask?.cancel()
        idleCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
            await self?.expireIdleConnections()
        }
    }

    private func expireIdleConnections() async {
        idleCleanupTask = nil
        await pruneConnections()
        if !connections.isEmpty { scheduleIdleCleanup() }
    }

    private func manager(
        host: String,
        port: Int,
        credentials: AppleSMBCredentials,
        usernameOverride: String? = nil
    ) throws -> SMB2Manager {
        let serverURL = try AppleSMBEndpointPolicy.makeURL(host: host, port: port, share: "IPC$")
        let credential = URLCredential(
            user: usernameOverride ?? (credentials.username.isEmpty ? "guest" : credentials.username),
            password: credentials.password,
            persistence: .none
        )
        guard let manager = SMB2Manager(url: serverURL, domain: credentials.domain, credential: credential) else {
            throw AppleSMBError.invalidHost
        }
        manager.timeout = 8
        return manager
    }
    #endif
}

/// Builds the library projection from a non-recursive SMB client. Keeping the
/// walk here makes the view independent of task lifetime and gives every
/// client (including test doubles) the same deterministic traversal.
struct AppleSMBNetworkLibraryScanner: Sendable {
    private let client: any AppleNetworkShareClient

    init(client: any AppleNetworkShareClient) {
        self.client = client
    }

    func scan(source: AppleSource, credentials: AppleSMBCredentials) async throws -> [AppleLibraryItem] {
        let parts = try AppleSMBEndpointPolicy.parts(from: source.url)
        let root = try await client.listDirectory(
            url: source.url,
            credentials: credentials,
            recursive: false
        )
        let entries = try await AppleSMBDirectoryWalker.walk(root: root) { path in
            let url = try AppleSMBEndpointPolicy.makeURL(
                host: parts.host,
                port: parts.port,
                share: parts.share,
                path: path
            )
            return try await client.listDirectory(url: url, credentials: credentials, recursive: false)
        }
        return try entries.compactMap { entry in
            guard !entry.isDirectory,
                  AppleLibraryScanner.supportedExtensions.contains(
                    URL(fileURLWithPath: entry.name).pathExtension.lowercased()
                  ) else { return nil }
            let url = try AppleSMBEndpointPolicy.makeURL(
                host: parts.host,
                port: parts.port,
                share: parts.share,
                path: entry.path
            )
            return AppleLibraryItem(
                sourceID: source.id,
                name: entry.name,
                url: url,
                relativePath: entry.path,
                sizeBytes: entry.sizeBytes
            )
        }
    }
}

struct AppleSMBDiscoveryReport: Sendable {
    let servers: [AppleSMBServer]
    let permissionDenied: Bool
    let advertisedCount: Int

    var message: String {
        if permissionDenied { return "Allow Local Network access for OpenStream in Settings, then tap Find Servers." }
        if !servers.isEmpty { return "Found \(servers.count) server\(servers.count == 1 ? "" : "s")." }
        if advertisedCount > 0 { return "Found nearby servers but couldn’t connect. Check that file sharing is enabled, or enter the server address." }
        return "No SMB shares found. Use the same Wi-Fi network and enable file sharing, or enter a host or IP address."
    }
}

public struct AppleSMBDiscovery: Sendable {
    public init() {}

    public func resolve(service: AppleSMBBonjourService) async -> AppleSMBServer? {
        await Self.resolve(.service(
            name: service.name,
            type: service.type,
            domain: service.domain,
            interface: nil
        ))
    }

    public func discover(for duration: Duration = .seconds(6)) async -> [AppleSMBServer] {
        await discoverReport(for: duration).servers
    }

    func discoverReport(for duration: Duration = .seconds(6)) async -> AppleSMBDiscoveryReport {
        let collector = AppleSMBDiscoveryCollector()
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in collector.replace(with: results.map(\.endpoint)) }
        browser.stateUpdateHandler = { collector.record($0) }
        browser.start(queue: DispatchQueue(label: "com.orgista.openstream.smb-discovery"))
        defer { browser.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var readyAt: ContinuousClock.Instant?
        while clock.now < deadline, !Task.isCancelled, !collector.permissionDenied {
            if collector.isReady, readyAt == nil { readyAt = clock.now }
            if let readyAt, readyAt.duration(to: clock.now) >= max(.zero, min(duration, .seconds(10))) { break }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        guard !Task.isCancelled else { return .init(servers: [], permissionDenied: false, advertisedCount: 0) }
        let endpoints = collector.endpoints
        let values = await withTaskGroup(of: AppleSMBServer?.self, returning: [AppleSMBServer].self) { group in
            for endpoint in endpoints.prefix(32) { group.addTask { await Self.resolve(endpoint) } }
            var values: [AppleSMBServer] = []
            for await value in group { if let value { values.append(value) } }
            return Dictionary(grouping: values, by: \.id).compactMap { $0.value.first }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return .init(servers: values, permissionDenied: collector.permissionDenied, advertisedCount: endpoints.count)
    }

    private static func resolve(_ endpoint: NWEndpoint) async -> AppleSMBServer? {
        guard case let .service(name, type, domain, _) = endpoint else { return nil }
        let state = AppleSMBResolutionState()
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { update in state.record(update) }
        connection.start(queue: DispatchQueue(label: "com.orgista.openstream.smb-resolution"))
        defer { connection.cancel() }
        for _ in 0 ..< 80 {
            if Task.isCancelled { return nil }
            if state.failed { return nil }
            if state.ready,
               case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                let fallbackHost = String(describing: host)
                guard !fallbackHost.isEmpty else { return nil }
                let serviceResolution = await AppleSMBBonjourResolver.resolve(
                    name: name,
                    type: type,
                    domain: domain,
                    port: Int(port.rawValue)
                )
                let fallbackIPv4 = IPv4Address(fallbackHost) == nil ? nil : fallbackHost
                let fallbackIPv6 = fallbackIPv4 == nil ? fallbackHost : nil
                let connectionHost = AppleSMBEndpointPolicy.connectionHost(
                    ipv4Host: serviceResolution?.ipv4Host ?? fallbackIPv4,
                    ipv6Host: serviceResolution?.ipv6Host ?? fallbackIPv6
                )
                guard let connectionHost else { return nil }
                let displayHost = AppleSMBEndpointPolicy.preferredHost(
                    bonjourHost: serviceResolution?.hostName,
                    ipv4Host: connectionHost,
                    ipv6Host: nil
                ) ?? connectionHost
                return AppleSMBServer(
                    name: name,
                    host: connectionHost,
                    port: Int(port.rawValue),
                    displayHost: displayHost
                )
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

private struct AppleSMBBonjourResolution: Sendable {
    let hostName: String?
    let ipv4Host: String?
    let ipv6Host: String?
}

private final class AppleSMBBonjourResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppleSMBBonjourResolution?, Never>?
    private var runLoop: RunLoop?

    private init(name: String, type: String, domain: String, port: Int) {
        let cleanType = type.hasSuffix(".") ? type : type + "."
        let cleanDomain = domain.hasSuffix(".") ? domain : domain + "."
        // A zero port makes this a resolver for an existing Bonjour service;
        // the advertised port is obtained from the Network.framework path.
        service = NetService(domain: cleanDomain, type: cleanType, name: name, port: 0)
        super.init()
        service.delegate = self
    }

    static func resolve(
        name: String,
        type: String,
        domain: String,
        port: Int
    ) async -> AppleSMBBonjourResolution? {
        let resolver = AppleSMBBonjourResolver(name: name, type: type, domain: domain, port: port)
        return await resolver.resolve()
    }

    private func resolve() async -> AppleSMBBonjourResolution? {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let runLoop = RunLoop.current
                self.lock.withLock { self.runLoop = runLoop }
                self.service.schedule(in: runLoop, forMode: .default)
                self.service.resolve(withTimeout: 2)
                let deadline = Date.now.addingTimeInterval(2.25)
                while self.isPending, Date.now < deadline {
                    runLoop.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
                }
                self.finish(nil)
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let addresses = sender.addresses ?? []
        var ipv4Host: String?
        var ipv6Host: String?
        for address in addresses {
            guard let value = Self.numericHost(from: address) else { continue }
            if Self.isIPv4(address) { ipv4Host = ipv4Host ?? value }
            else { ipv6Host = ipv6Host ?? value }
        }
        let hostName = sender.hostName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        finish(.init(hostName: hostName, ipv4Host: ipv4Host, ipv6Host: ipv6Host))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }

    private func finish(_ result: AppleSMBBonjourResolution?) {
        let continuation = lock.withLock { () -> CheckedContinuation<AppleSMBBonjourResolution?, Never>? in
            let value = self.continuation
            self.continuation = nil
            return value
        }
        guard let continuation else { return }
        service.stop()
        if let runLoop {
            service.remove(from: runLoop, forMode: .default)
        }
        self.runLoop = nil
        continuation.resume(returning: result)
    }

    private var isPending: Bool {
        lock.withLock { continuation != nil }
    }

    private static func isIPv4(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard rawBuffer.count >= MemoryLayout<sockaddr>.size else { return false }
            return rawBuffer.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET)
        }
    }

    private static func numericHost(from data: Data) -> String? {
        #if canImport(Darwin)
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        var storage = sockaddr_storage()
        let copied = min(data.count, MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutableBytes(of: &storage) { destination in
            data.copyBytes(to: destination.bindMemory(to: UInt8.self), count: copied)
        }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getnameinfo(
                    address,
                    socklen_t(data.count),
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard result == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        #else
        return nil
        #endif
    }
}

private final class AppleSMBDiscoveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NWEndpoint] = []
    private var ready = false
    private var denied = false
    var isReady: Bool { lock.withLock { ready } }
    var permissionDenied: Bool { lock.withLock { denied } }

    func record(_ state: NWBrowser.State) {
        lock.withLock {
            switch state {
            case .ready: ready = true
            case .waiting(let error), .failed(let error):
                // dns_sd.h: kDNSServiceErr_PolicyDenied, local-network privacy.
                if case .dns(let code) = error, code == -65570 { denied = true }
            default: break
            }
        }
    }

    var endpoints: [NWEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func replace(with values: [NWEndpoint]) {
        lock.lock()
        storage = values
        lock.unlock()
    }
}

private final class AppleSMBResolutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentIsReady = false
    private var currentFailed = false

    var ready: Bool { lock.withLock { currentIsReady } }
    var failed: Bool { lock.withLock { currentFailed } }

    func record(_ state: NWConnection.State) {
        lock.withLock {
            if case .ready = state { currentIsReady = true }
            if case .failed = state { currentFailed = true }
            if case .cancelled = state { currentFailed = true }
        }
    }
}

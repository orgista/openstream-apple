import Foundation
import Observation

/// How the viewer signs in to an SMB server.
enum AppleNetworkShareAccount: String, CaseIterable, Identifiable, Sendable {
    case guest
    case registered

    var id: Self { self }

    var title: String {
        switch self {
        case .guest: "Guest"
        case .registered: "Registered User"
        }
    }
}

/// The server a setup flow connects to. `host` is what SMB dials (numeric
/// once Bonjour has resolved it); `name` and `displayHost` are for people.
struct AppleNetworkShareServer: Hashable, Sendable {
    let name: String
    let host: String
    let port: Int
    let displayHost: String

    init(name: String, host: String, port: Int = 445, displayHost: String? = nil) {
        let cleanHost = AppleSMBEndpointPolicy.normalizedHost(host)
        self.host = cleanHost
        self.port = port
        self.displayHost = AppleSMBEndpointPolicy.normalizedHost(displayHost ?? cleanHost)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanName.isEmpty ? self.displayHost : cleanName
    }

    init(_ server: AppleSMBServer) {
        self.init(name: server.name, host: server.host, port: server.port, displayHost: server.displayHost)
    }

    var endpointLabel: String {
        AppleSMBEndpointPolicy.endpointLabel(host: displayHost, port: port)
    }
}

/// A folder on a share. An empty `path` is the share itself.
struct AppleNetworkShareLocation: Hashable, Sendable {
    let share: String
    let path: String

    init(share: String, path: String = "") {
        self.share = share
        self.path = path.split(separator: "/").joined(separator: "/")
    }

    var isShareRoot: Bool { path.isEmpty }

    var folderName: String {
        path.split(separator: "/").last.map(String.init) ?? share
    }

    func appending(_ name: String) -> Self {
        Self(share: share, path: path.isEmpty ? name : "\(path)/\(name)")
    }
}

struct AppleNetworkShareFolder: Identifiable, Hashable, Sendable {
    let name: String
    let location: AppleNetworkShareLocation

    var id: String { location.path }
}

/// One level of the folder browser: its subfolders, and how many playable
/// files sit directly in it.
struct AppleNetworkShareListing: Equatable, Sendable {
    let folders: [AppleNetworkShareFolder]
    let videoCount: Int
}

/// Pure rules for the step-by-step network share setup.
enum AppleNetworkSharePolicy {
    /// Folders every NAS keeps for itself; none of them hold a library.
    private static let systemFolderNames: Set<String> = [
        "@eadir", "#recycle", "#snapshot", "$recycle.bin", "system volume information", "lost+found",
    ]

    /// Administrative and IPC shares (`IPC$`, `ADMIN$`, `C$`, `print$`) end in
    /// `$`; Windows hides them too.
    static func visibleShares(_ shares: [AppleSMBShare]) -> [AppleSMBShare] {
        var seen = Set<String>()
        return shares
            .filter { share in
                let name = share.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return !name.isEmpty && !name.hasSuffix("$") && seen.insert(name.lowercased()).inserted
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func listing(
        for entries: [AppleSMBDirectoryEntry],
        in location: AppleNetworkShareLocation
    ) -> AppleNetworkShareListing {
        let folders = entries
            .filter { entry in
                guard entry.isDirectory else { return false }
                let name = entry.name
                return !name.isEmpty
                    && !name.hasPrefix(".")
                    && !name.contains("/")
                    && !systemFolderNames.contains(name.lowercased())
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { AppleNetworkShareFolder(name: $0.name, location: location.appending($0.name)) }
        let videoCount = entries.count { entry in
            !entry.isDirectory && AppleLibraryScanner.supportedExtensions.contains(
                URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            )
        }
        return AppleNetworkShareListing(folders: folders, videoCount: videoCount)
    }

    static func sourceURL(server: AppleNetworkShareServer, location: AppleNetworkShareLocation) throws -> URL {
        try AppleSMBEndpointPolicy.makeURL(
            host: server.host,
            port: server.port,
            share: location.share,
            path: location.path
        )
    }

    static func defaultName(location: AppleNetworkShareLocation, server: AppleNetworkShareServer) -> String {
        "\(location.folderName) on \(server.name)"
    }

    static func credentials(
        account: AppleNetworkShareAccount,
        username: String,
        password: String,
        domain: String
    ) -> AppleSMBCredentials {
        switch account {
        case .guest:
            AppleSMBCredentials(username: "", password: "")
        case .registered:
            AppleSMBCredentials(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                domain: domain.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func account(for credentials: AppleSMBCredentials) -> AppleNetworkShareAccount {
        credentials.username.isEmpty && credentials.password.isEmpty ? .guest : .registered
    }

    /// A typed "server or IP" (optionally `host:port`, `[v6]:port` or
    /// `smb://host`), with the Advanced port used only when the address
    /// carries none of its own.
    static func server(address: String, port: String) throws -> AppleNetworkShareServer {
        guard let parsed = parseAddress(address) else { throw AppleSMBError.invalidHost }
        let resolvedPort: Int
        if let explicit = parsed.port {
            resolvedPort = explicit
        } else {
            let typed = port.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed.isEmpty {
                resolvedPort = 445
            } else {
                guard let value = Int(typed) else { throw AppleSMBError.invalidPort }
                resolvedPort = value
            }
        }
        let input = try AppleSMBEndpointPolicy.parseInput(
            host: parsed.host,
            port: resolvedPort,
            share: "",
            path: "",
            requiresShare: false
        )
        let name = AppleSMBEndpointPolicy.bonjourService(from: input.host)?.name ?? input.host
        return AppleNetworkShareServer(name: name, host: input.host, port: input.port)
    }

    static func parseAddress(_ value: String) -> (host: String, port: Int?)? {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("smb://") {
            guard let url = URL(string: clean), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            return (host, url.port)
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        if clean.hasPrefix("["), let close = clean.firstIndex(of: "]") {
            let host = String(clean[clean.index(after: clean.startIndex)..<close])
            let suffix = clean[clean.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if suffix.isEmpty { return (host, nil) }
            guard suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()), (1 ... 65_535).contains(port) else {
                return nil
            }
            return (host, port)
        }
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains("@"), !clean.contains(" ") else { return nil }
        let colons = clean.count { $0 == ":" }
        if colons == 1, let separator = clean.firstIndex(of: ":") {
            let host = String(clean[..<separator])
            guard !host.isEmpty, let port = Int(clean[clean.index(after: separator)...]),
                  (1 ... 65_535).contains(port) else { return nil }
            return (host, port)
        }
        // A bare IPv6 literal (several colons) or a plain name.
        return (clean, nil)
    }

    /// A saved share on the same server whose account can be reused, so a
    /// server the viewer already signed in to skips straight to its folders.
    static func savedCredentials(
        for server: AppleNetworkShareServer,
        in sources: [AppleSource],
        lookup: (AppleSource) -> AppleSMBCredentials?
    ) -> AppleSMBCredentials? {
        for source in sources where sameServer(source, as: server) {
            if let credentials = lookup(source) { return credentials }
        }
        return nil
    }
}

/// A selected folder's editable name. This is setup state, never a stored schema.
struct AppleNetworkShareNamedFolder: Identifiable, Sendable {
    let location: AppleNetworkShareLocation
    var name: String
    var id: AppleNetworkShareLocation { location }
}

enum AppleNetworkShareSelectionState: Equatable, Sendable {
    case available, selected, added, overlap

    var isChecked: Bool { self == .selected || self == .added }
    var canToggle: Bool { self == .available || self == .selected }
}

enum AppleNetworkShareSelectionError: LocalizedError, Equatable {
    case overlap
    var errorDescription: String? { "These folders overlap a folder already selected or added." }
}

struct AppleNetworkShareGroup: Identifiable {
    let server: AppleNetworkShareServer
    let share: String
    var sources: [AppleSource]
    var id: String { "\(server.endpointLabel.lowercased())/\(share.lowercased())" }
    var title: String { "\(share) on \(server.endpointLabel)" }
}

extension AppleNetworkSharePolicy {
    static func sameServer(_ source: AppleSource, as server: AppleNetworkShareServer) -> Bool {
        guard source.kind == .nas, let parts = try? AppleSMBEndpointPolicy.parts(from: source.url),
              parts.port == server.port else { return false }
        let hosts = Set([server.host, server.displayHost].map { AppleSMBEndpointPolicy.normalizedHost($0).lowercased() })
        return hosts.contains(AppleSMBEndpointPolicy.normalizedHost(parts.host).lowercased())
            || source.networkDisplayHost.map { hosts.contains(AppleSMBEndpointPolicy.normalizedHost($0).lowercased()) } == true
    }

    static func overlaps(_ first: AppleNetworkShareLocation, _ second: AppleNetworkShareLocation) -> Bool {
        guard first.share.lowercased() == second.share.lowercased() else { return false }
        let a = first.path.lowercased().split(separator: "/")
        let b = second.path.lowercased().split(separator: "/")
        return a.starts(with: b) || b.starts(with: a)
    }

    static func sameLocation(_ first: AppleNetworkShareLocation, _ second: AppleNetworkShareLocation) -> Bool {
        first.share.lowercased() == second.share.lowercased() && first.path.lowercased() == second.path.lowercased()
    }

    static func locations(on server: AppleNetworkShareServer, in sources: [AppleSource], excluding id: UUID? = nil) -> [AppleNetworkShareLocation] {
        sources.compactMap { source in
            guard source.id != id, sameServer(source, as: server),
                  let parts = try? AppleSMBEndpointPolicy.parts(from: source.url) else { return nil }
            return AppleNetworkShareLocation(share: parts.share, path: parts.path)
        }
    }

    static func groups(in sources: [AppleSource]) -> [AppleNetworkShareGroup] {
        var groups: [AppleNetworkShareGroup] = []
        for source in sources where source.kind == .nas {
            guard let parts = try? AppleSMBEndpointPolicy.parts(from: source.url) else { continue }
            if let index = groups.firstIndex(where: {
                sameServer(source, as: $0.server) && $0.share.lowercased() == parts.share.lowercased()
            }) {
                groups[index].sources.append(source)
            } else {
                let host = source.networkDisplayHost ?? parts.host
                groups.append(AppleNetworkShareGroup(server: .init(name: host, host: parts.host, port: parts.port, displayHost: host),
                    share: parts.share, sources: [source]))
            }
        }
        return groups
    }
}

/// The state behind the Connect → Browse → Add pages. One instance lives for
/// one pass through the flow; the pages share it.
@MainActor
@Observable
final class AppleNetworkShareSetup {
    enum Purpose: Equatable, Sendable {
        case add
        case editServer(AppleSource.ID)
        case editFolder(AppleSource.ID)
        case editAccount(AppleSource.ID)

        var sourceID: AppleSource.ID? {
            switch self {
            case .add: nil
            case .editServer(let id), .editFolder(let id), .editAccount(let id): id
            }
        }
    }

    /// Where Connect leads once it succeeds.
    enum ConnectOutcome: Equatable, Sendable {
        case browse
        case saveAccount
    }

    typealias Resolver = @Sendable (AppleSMBBonjourService) async -> AppleSMBServer?

    let purpose: Purpose
    /// A discovered or already-saved server: its address is shown, not typed.
    let fixedServer: AppleNetworkShareServer?
    /// The folder an edited source points at today.
    let currentLocation: AppleNetworkShareLocation?
    /// The edited source's server and name as saved, for the proposed name.
    private let originalServer: AppleNetworkShareServer?
    private let existingName: String?
    var address: String
    var port: String
    var account: AppleNetworkShareAccount
    var username: String
    var password: String
    var domain: String

    private(set) var isConnecting = false
    private(set) var connectError: String?
    private(set) var server: AppleNetworkShareServer?
    private(set) var credentials: AppleSMBCredentials?
    private(set) var shares: [AppleSMBShare] = []
    private(set) var videoCounts: [AppleNetworkShareLocation: Int] = [:]

    private var existingSources: [AppleSource]
    let initialBrowseLocation: AppleNetworkShareLocation?

    private(set) var selectedLocations: [AppleNetworkShareLocation] = []

    var allowsMultipleFolders: Bool { purpose == .add }

    func selectionState(for location: AppleNetworkShareLocation) -> AppleNetworkShareSelectionState {
        let added = server.map { AppleNetworkSharePolicy.locations(on: $0, in: existingSources, excluding: purpose.sourceID) } ?? []
        if added.contains(where: { AppleNetworkSharePolicy.sameLocation($0, location) }) { return .added }
        if selectedLocations.contains(where: { AppleNetworkSharePolicy.sameLocation($0, location) }) { return .selected }
        if (added + selectedLocations).contains(where: { AppleNetworkSharePolicy.overlaps($0, location) }) { return .overlap }
        return .available
    }

    func toggleSelection(_ location: AppleNetworkShareLocation) {
        switch selectionState(for: location) {
        case .selected: selectedLocations.removeAll { AppleNetworkSharePolicy.sameLocation($0, location) }
        case .available: selectedLocations.append(location)
        case .added, .overlap: break
        }
    }

    @discardableResult
    func saveFolders(_ folders: [AppleNetworkShareNamedFolder], to store: AppleSourceStore) throws -> [AppleSource] {
        guard let server else { throw AppleSMBError.connectionFailed }
        guard !folders.isEmpty, allowsMultipleFolders || folders.count == 1 else { throw AppleSMBError.invalidShare }
        var reserved = AppleNetworkSharePolicy.locations(on: server, in: store.sources, excluding: purpose.sourceID)
        for folder in folders {
            guard !reserved.contains(where: { AppleNetworkSharePolicy.overlaps($0, folder.location) }) else {
                throw AppleNetworkShareSelectionError.overlap
            }
            reserved.append(folder.location)
        }
        var added: [AppleSource] = []
        do {
            for folder in folders { added.append(try save(location: folder.location, name: folder.name, to: store)) }
            return added
        } catch {
            // Only add flows create new identities. Undo this batch if Keychain
            // becomes unavailable partway through, so Retry cannot double-add.
            if allowsMultipleFolders {
                for source in added.reversed() { _ = store.remove(id: source.id) }
            }
            throw error
        }
    }

    private let savedCredentials: AppleSMBCredentials?
    private var triedSavedCredentials = false
    private let client: any AppleNetworkShareClient
    private let resolve: Resolver

    init(
        purpose: Purpose = .add,
        server: AppleNetworkShareServer? = nil,
        currentLocation: AppleNetworkShareLocation? = nil,
        existingName: String? = nil,
        savedCredentials: AppleSMBCredentials? = nil,
        existingSources: [AppleSource] = [],
        initialBrowseLocation: AppleNetworkShareLocation? = nil,
        client: any AppleNetworkShareClient,
        resolve: @escaping Resolver = { _ in nil }
    ) {
        self.existingSources = existingSources
        self.initialBrowseLocation = initialBrowseLocation
        self.purpose = purpose
        self.currentLocation = currentLocation
        self.originalServer = server
        self.existingName = existingName
        self.savedCredentials = savedCredentials
        self.client = client
        self.resolve = resolve
        if case .editServer = purpose {
            // The address is the thing being edited, so it stays a field.
            fixedServer = nil
            address = server.map { AppleSMBEndpointPolicy.endpointLabel(host: $0.host, port: 445) } ?? ""
            port = server.map { String($0.port) } ?? "445"
        } else {
            fixedServer = server
            address = ""
            port = "445"
        }
        let saved = savedCredentials ?? AppleSMBCredentials(username: "", password: "")
        account = savedCredentials.map(AppleNetworkSharePolicy.account(for:)) ?? .guest
        username = saved.username
        password = saved.password
        domain = saved.domain
    }

    func updateExistingSources(_ sources: [AppleSource]) {
        existingSources = sources
        guard let server else { return }
        let added = AppleNetworkSharePolicy.locations(on: server, in: sources, excluding: purpose.sourceID)
        selectedLocations.removeAll { selected in
            added.contains { AppleNetworkSharePolicy.overlaps($0, selected) }
        }
    }

    var outcome: ConnectOutcome {
        if case .editAccount = purpose { return .saveAccount }
        return .browse
    }

    /// Registered User needs a name before Connect can do anything useful.
    var canConnect: Bool {
        guard !isConnecting else { return false }
        if fixedServer == nil,
           address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return account == .guest || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the page should try the saved account on its own, once. Only
    /// when the server is known and the viewer did not come to change it.
    var shouldConnectAutomatically: Bool {
        guard !triedSavedCredentials, savedCredentials != nil, fixedServer != nil else { return false }
        switch purpose {
        case .add, .editFolder: return true
        case .editServer, .editAccount: return false
        }
    }

    /// Tries the saved account for this server. Returns true when it worked
    /// and the flow can go straight to the folders; a failure leaves the
    /// reason on the Connect page with the account filled in.
    func connectWithSavedCredentials() async -> Bool {
        guard shouldConnectAutomatically else { return false }
        triedSavedCredentials = true
        return await connect()
    }

    /// Connecting is the test: it lists the server's shares with the chosen
    /// account, and only a success moves the flow on.
    @discardableResult
    func connect() async -> Bool {
        guard !isConnecting else { return false }
        connectError = nil
        if account == .registered, username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectError = "Enter a username, or connect as Guest."
            return false
        }
        let target: AppleNetworkShareServer
        do {
            target = try fixedServer ?? AppleNetworkSharePolicy.server(address: address, port: port)
        } catch {
            connectError = AppleSMBError.mapped(from: error).localizedDescription
            return false
        }
        let submitted = AppleNetworkSharePolicy.credentials(
            account: account,
            username: username,
            password: password,
            domain: domain
        )
        isConnecting = true
        defer { isConnecting = false }
        do {
            let resolved = try await resolvedServer(target)
            let listed = try await client.listShares(host: resolved.host, port: resolved.port, credentials: submitted)
            try Task.checkCancellation()
            if outcome == .saveAccount, let currentLocation {
                // A changed password is proven against the folder the source
                // actually reads, not just the server's share list.
                let url = try AppleNetworkSharePolicy.sourceURL(server: resolved, location: currentLocation)
                _ = try await client.listDirectory(url: url, credentials: submitted, recursive: false)
                try Task.checkCancellation()
            }
            if server != resolved { selectedLocations = [] }
            server = resolved
            credentials = submitted
            shares = AppleNetworkSharePolicy.visibleShares(listed)
            videoCounts = [:]
            return true
        } catch is CancellationError {
            return false
        } catch {
            connectError = AppleSMBError.mapped(from: error).localizedDescription
            return false
        }
    }

    func listing(at location: AppleNetworkShareLocation) async throws -> AppleNetworkShareListing {
        guard let server, let credentials else { throw AppleSMBError.connectionFailed }
        let url = try AppleNetworkSharePolicy.sourceURL(server: server, location: location)
        do {
            let entries = try await client.listDirectory(url: url, credentials: credentials, recursive: false)
            let listing = AppleNetworkSharePolicy.listing(for: entries, in: location)
            videoCounts[location] = listing.videoCount
            return listing
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppleSMBError.mapped(from: error)
        }
    }

    /// Playable files directly inside a folder, for the row badge. Cached, and
    /// silent on failure: a folder that can't be read just shows no badge.
    func loadVideoCount(at location: AppleNetworkShareLocation) async {
        guard videoCounts[location] == nil else { return }
        _ = try? await listing(at: location)
    }

    func defaultName(for location: AppleNetworkShareLocation) -> String {
        guard let server else { return location.folderName }
        return AppleNetworkSharePolicy.defaultName(location: location, server: server)
    }

    /// The name the Add page starts with. An edited source keeps a name the
    /// viewer chose; one that was only ever the automatic name follows the
    /// new folder.
    func proposedName(for location: AppleNetworkShareLocation) -> String {
        if let existingName, !existingName.isEmpty {
            var automatic: Set<String> = []
            if let currentLocation {
                automatic.insert(currentLocation.share)
                if let originalServer {
                    automatic.insert(AppleNetworkSharePolicy.defaultName(location: currentLocation, server: originalServer))
                }
            }
            if !automatic.contains(existingName) { return existingName }
        }
        return defaultName(for: location)
    }

    /// Saves the chosen folder: a new source, or the edited one in place.
    @discardableResult
    func save(location: AppleNetworkShareLocation?, name: String, to store: AppleSourceStore) throws -> AppleSource {
        guard let server, let credentials else { throw AppleSMBError.connectionFailed }
        let target = location ?? currentLocation
        guard let target else { throw AppleSMBError.invalidShare }
        let summary = "Connected"
        if let id = purpose.sourceID {
            return try store.updateNetworkShare(
                id: id,
                name: name,
                host: server.host,
                port: server.port,
                share: target.share,
                path: target.path,
                credentials: credentials,
                displayHost: server.displayHost,
                validationSummary: summary
            )
        }
        return try store.addNetworkShare(
            name: name,
            host: server.host,
            port: server.port,
            share: target.share,
            path: target.path,
            username: credentials.username,
            password: credentials.password,
            domain: credentials.domain,
            displayHost: server.displayHost,
            lastValidatedAt: .now,
            validationSummary: summary,
            capabilities: ["Browse", "Playback", "Seeking"]
        )
    }

    /// Account-only edits save as soon as Connect proves the new account.
    func saveAccount(to store: AppleSourceStore) -> Bool {
        guard let currentLocation else { return false }
        do {
            try save(location: currentLocation, name: proposedName(for: currentLocation), to: store)
            return true
        } catch {
            connectError = error.localizedDescription
            return false
        }
    }

    private func resolvedServer(_ target: AppleNetworkShareServer) async throws -> AppleNetworkShareServer {
        guard let service = AppleSMBEndpointPolicy.bonjourService(from: target.host) else { return target }
        guard let found = await resolve(service) else { throw AppleSMBError.serverUnreachable }
        return AppleNetworkShareServer(name: service.name, host: found.host, port: found.port, displayHost: found.displayHost)
    }
}

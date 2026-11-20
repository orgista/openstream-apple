import Foundation
import Testing
@testable import OpenStreamApple

/// A scripted SMB server: shares and folders from a table, one account that
/// is accepted, everything recorded. Never touches the network.
private actor SetupFakeClient: AppleNetworkShareClient {
    let shares: [AppleSMBShare]
    let directories: [String: [AppleSMBDirectoryEntry]]
    let acceptedUsername: String?
    let shareError: AppleSMBError?
    private(set) var shareRequests: [(host: String, port: Int, credentials: AppleSMBCredentials)] = []
    private(set) var directoryRequests: [URL] = []

    init(
        shares: [AppleSMBShare] = [],
        directories: [String: [AppleSMBDirectoryEntry]] = [:],
        acceptedUsername: String? = nil,
        shareError: AppleSMBError? = nil
    ) {
        self.shares = shares
        self.directories = directories
        self.acceptedUsername = acceptedUsername
        self.shareError = shareError
    }

    func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] {
        shareRequests.append((host, port, credentials))
        if let shareError { throw shareError }
        if let acceptedUsername, credentials.username != acceptedUsername { throw AppleSMBError.authenticationFailed }
        return shares
    }

    func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] {
        #expect(!recursive)
        directoryRequests.append(url)
        let parts = try AppleSMBEndpointPolicy.parts(from: url)
        let key = parts.path.isEmpty ? parts.share : "\(parts.share)/\(parts.path)"
        guard let entries = directories[key] else { throw AppleSMBError.accessDenied }
        return entries
    }

    func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data { Data() }
}

private final class SetupCredentialStore: AppleCredentialStoring {
    var values: [String: String] = [:]
    var failOnRead: Int?
    private var reads = 0
    func string(for account: String) throws -> String? {
        reads += 1
        if reads == failOnRead { throw AppleKeychainStoreError.invalidData }
        return values[account]
    }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

private let fixtureServer = AppleNetworkShareServer(name: "Fixture NAS", host: "127.0.0.1", displayHost: "fixture.example")

private func entry(_ name: String, directory: Bool = false) -> AppleSMBDirectoryEntry {
    AppleSMBDirectoryEntry(name: name, path: name, isDirectory: directory)
}

@MainActor
private func makeStore() throws -> (AppleSourceStore, SetupCredentialStore, () -> Void) {
    let suite = "AppleNetworkShareSetupTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let keychain = SetupCredentialStore()
    let store = AppleSourceStore(defaults: defaults, keychain: keychain)
    return (store, keychain, { defaults.removePersistentDomain(forName: suite) })
}

@Suite("Network share setup flow")
@MainActor
struct AppleNetworkShareSetupTests {
    @Test func guestConnectsWithEmptyCredentialsAndMovesOn() async throws {
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")])
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: client)
        setup.username = "ignored-for-guest"

        #expect(setup.account == .guest)
        #expect(await setup.connect())
        #expect(setup.outcome == .browse)
        let request = try #require(await client.shareRequests.first)
        #expect(request.credentials == AppleSMBCredentials(username: "", password: ""))
        #expect(request.host == "127.0.0.1")
        #expect(setup.credentials == AppleSMBCredentials(username: "", password: ""))
    }

    @Test func registeredUserSendsTheAccountAndNeedsAUsername() async throws {
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "fixture-user")
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: client)
        setup.account = .registered

        #expect(!setup.canConnect)
        #expect(!(await setup.connect()))
        #expect(setup.connectError != nil)
        #expect(await client.shareRequests.isEmpty)

        setup.username = "  fixture-user "
        setup.password = "fixture-password"
        setup.domain = "WORKGROUP"
        #expect(setup.canConnect)
        #expect(await setup.connect())
        let request = try #require(await client.shareRequests.last)
        #expect(request.credentials == AppleSMBCredentials(
            username: "fixture-user",
            password: "fixture-password",
            domain: "WORKGROUP"
        ))
    }

    @Test(arguments: [AppleSMBError.authenticationFailed, .accessDenied, .serverUnreachable])
    func failureStaysOnConnectWithTheExactReason(_ failure: AppleSMBError) async {
        let client = SetupFakeClient(shareError: failure)
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: client)

        #expect(!(await setup.connect()))
        #expect(setup.connectError == failure.localizedDescription)
        #expect(setup.server == nil)
        #expect(setup.credentials == nil)
        #expect(!setup.isConnecting)
    }

    @Test func typedAddressUsesItsOwnPortBeforeTheAdvancedOne() async throws {
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")])
        let setup = AppleNetworkShareSetup(client: client)
        #expect(!setup.canConnect)

        setup.address = "127.0.0.1:1445"
        setup.port = "445"
        #expect(await setup.connect())
        #expect(await client.shareRequests.last?.port == 1445)

        setup.address = "fixture.example"
        setup.port = "2445"
        #expect(await setup.connect())
        #expect(await client.shareRequests.last?.host == "fixture.example")
        #expect(await client.shareRequests.last?.port == 2445)
    }

    @Test func badAddressFailsWithoutDialling() async {
        let client = SetupFakeClient()
        let setup = AppleNetworkShareSetup(client: client)
        setup.address = "user@fixture.example"

        #expect(!(await setup.connect()))
        #expect(setup.connectError == AppleSMBError.invalidHost.localizedDescription)
        #expect(await client.shareRequests.isEmpty)
    }

    @Test func savedCredentialsSkipStraightToTheFoldersOnce() async throws {
        let saved = AppleSMBCredentials(username: "fixture-user", password: "fixture-password")
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "fixture-user")
        let setup = AppleNetworkShareSetup(server: fixtureServer, savedCredentials: saved, client: client)

        #expect(setup.account == .registered)
        #expect(setup.username == "fixture-user")
        #expect(setup.shouldConnectAutomatically)
        #expect(await setup.connectWithSavedCredentials())
        // Coming back to Connect must not bounce straight forward again.
        #expect(!setup.shouldConnectAutomatically)
        #expect(!(await setup.connectWithSavedCredentials()))
        #expect(await client.shareRequests.count == 1)
    }

    @Test func noSavedCredentialsOrTypedServerNeverConnectsAutomatically() async {
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")])
        #expect(!AppleNetworkShareSetup(server: fixtureServer, client: client).shouldConnectAutomatically)
        let typed = AppleNetworkShareSetup(
            savedCredentials: AppleSMBCredentials(username: "fixture-user", password: ""),
            client: client
        )
        #expect(!typed.shouldConnectAutomatically)
        #expect(!(await typed.connectWithSavedCredentials()))
        #expect(await client.shareRequests.isEmpty)
    }

    @Test func staleSavedCredentialsLeaveTheReasonOnConnect() async {
        let saved = AppleSMBCredentials(username: "old-user", password: "old-password")
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "fixture-user")
        let setup = AppleNetworkShareSetup(server: fixtureServer, savedCredentials: saved, client: client)

        #expect(!(await setup.connectWithSavedCredentials()))
        #expect(setup.connectError == AppleSMBError.authenticationFailed.localizedDescription)
        #expect(setup.username == "old-user")
    }

    @Test func savedCredentialsAreFoundByHostPortOrDisplayName() throws {
        let saved = AppleSMBCredentials(username: "fixture-user", password: "fixture-password")
        let match = AppleSource(kind: .nas, name: "A", url: URL(string: "smb://127.0.0.1/Media")!)
        let otherPort = AppleSource(kind: .nas, name: "B", url: URL(string: "smb://127.0.0.1:1445/Media")!)
        let byName = AppleSource(
            kind: .nas,
            name: "C",
            url: URL(string: "smb://127.0.0.2/Media")!,
            networkDisplayHost: "FIXTURE.example"
        )
        let lookup: (AppleSource) -> AppleSMBCredentials? = { _ in saved }

        #expect(AppleNetworkSharePolicy.savedCredentials(for: fixtureServer, in: [otherPort], lookup: lookup) == nil)
        #expect(AppleNetworkSharePolicy.savedCredentials(for: fixtureServer, in: [otherPort, match], lookup: lookup) == saved)
        let moved = AppleNetworkShareServer(name: "NAS", host: "127.0.0.9", displayHost: "fixture.example")
        #expect(AppleNetworkSharePolicy.savedCredentials(for: moved, in: [byName], lookup: lookup) == saved)
        #expect(AppleNetworkSharePolicy.savedCredentials(for: fixtureServer, in: [match], lookup: { _ in nil }) == nil)
    }

    @Test func hiddenAndAdministrativeSharesAreFiltered() {
        let visible = AppleNetworkSharePolicy.visibleShares([
            AppleSMBShare(name: "IPC$"),
            AppleSMBShare(name: "ADMIN$"),
            AppleSMBShare(name: "C$"),
            AppleSMBShare(name: "print$"),
            AppleSMBShare(name: "movies"),
            AppleSMBShare(name: "Media", comment: "Library"),
            AppleSMBShare(name: "MEDIA"),
            AppleSMBShare(name: " "),
        ])
        #expect(visible.map(\.name) == ["Media", "movies"])
    }

    @Test func browsingListsFoldersOnlyAndCountsVideosHere() async throws {
        let client = SetupFakeClient(
            shares: [AppleSMBShare(name: "IPC$"), AppleSMBShare(name: "Media")],
            directories: [
                "Media": [
                    entry("TV Shows", directory: true),
                    entry("Movies", directory: true),
                    entry(".hidden", directory: true),
                    entry("@eaDir", directory: true),
                    entry("#recycle", directory: true),
                    entry("trailer.mkv"),
                    entry("clip.MP4"),
                    entry("notes.txt"),
                ],
            ]
        )
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: client)
        #expect(await setup.connect())
        #expect(setup.shares.map(\.name) == ["Media"])

        let root = AppleNetworkShareLocation(share: "Media")
        let listing = try await setup.listing(at: root)
        #expect(listing.folders.map(\.name) == ["Movies", "TV Shows"])
        #expect(listing.folders.first?.location == AppleNetworkShareLocation(share: "Media", path: "Movies"))
        #expect(listing.videoCount == 2)
        #expect(setup.videoCounts[root] == 2)
    }

    @Test func unreadableFolderReportsTheReasonAndLeavesNoBadge() async throws {
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")], directories: [:])
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: client)
        #expect(await setup.connect())
        let folder = AppleNetworkShareLocation(share: "Media", path: "Private")

        await #expect(throws: AppleSMBError.accessDenied) { try await setup.listing(at: folder) }
        await setup.loadVideoCount(at: folder)
        #expect(setup.videoCounts[folder] == nil)
    }

    @Test func addThisFolderBuildsTheShareOrSubfolderURL() throws {
        let shareRoot = AppleNetworkShareLocation(share: "Media")
        let subfolder = shareRoot.appending("Movies").appending("4K")
        #expect(shareRoot.isShareRoot)
        #expect(subfolder.path == "Movies/4K")
        #expect(try AppleNetworkSharePolicy.sourceURL(server: fixtureServer, location: shareRoot).absoluteString
            == "smb://127.0.0.1/Media")
        #expect(try AppleNetworkSharePolicy.sourceURL(server: fixtureServer, location: subfolder).absoluteString
            == "smb://127.0.0.1/Media/Movies/4K")
        let otherPort = AppleNetworkShareServer(name: "NAS", host: "127.0.0.1", port: 1445)
        #expect(try AppleNetworkSharePolicy.sourceURL(server: otherPort, location: shareRoot).absoluteString
            == "smb://127.0.0.1:1445/Media")
    }

    @Test func defaultNameIsFolderOnServer() {
        let shareRoot = AppleNetworkShareLocation(share: "Media")
        #expect(AppleNetworkSharePolicy.defaultName(location: shareRoot, server: fixtureServer) == "Media on Fixture NAS")
        #expect(AppleNetworkSharePolicy.defaultName(location: shareRoot.appending("Movies"), server: fixtureServer)
            == "Movies on Fixture NAS")
        let typed = try? AppleNetworkSharePolicy.server(address: "127.0.0.1", port: "")
        #expect(typed.map { AppleNetworkSharePolicy.defaultName(location: shareRoot, server: $0) } == "Media on 127.0.0.1")
    }

    @Test func addingSavesTheFolderAndAccount() async throws {
        let (store, keychain, cleanup) = try makeStore()
        defer { cleanup() }
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "fixture-user")
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: client)
        setup.account = .registered
        setup.username = "fixture-user"
        setup.password = "fixture-password"
        #expect(await setup.connect())

        let folder = AppleNetworkShareLocation(share: "Media", path: "Movies")
        let source = try setup.save(location: folder, name: setup.proposedName(for: folder), to: store)
        #expect(source.kind == .nas)
        #expect(source.name == "Movies on Fixture NAS")
        #expect(source.url.absoluteString == "smb://127.0.0.1/Media/Movies")
        #expect(source.networkDisplayHost == "fixture.example")
        #expect(try store.networkCredentials(for: source)?.username == "fixture-user")
        #expect(keychain.values.values.allSatisfy { !$0.isEmpty })
    }

    @Test func editingTheFolderKeepsTheSourceIdentity() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try store.addNetworkShare(
            name: "Media on Fixture NAS",
            host: "127.0.0.1",
            share: "Media",
            displayHost: "fixture.example"
        )
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")])
        let setup = AppleNetworkShareSetup(
            purpose: .editFolder(original.id),
            server: fixtureServer,
            currentLocation: AppleNetworkShareLocation(share: "Media"),
            existingName: original.name,
            savedCredentials: AppleSMBCredentials(username: "", password: ""),
            client: client
        )
        #expect(setup.shouldConnectAutomatically)
        #expect(await setup.connectWithSavedCredentials())

        let folder = AppleNetworkShareLocation(share: "Media", path: "Movies")
        // The automatic name follows the new folder.
        #expect(setup.proposedName(for: folder) == "Movies on Fixture NAS")
        let saved = try setup.save(location: folder, name: setup.proposedName(for: folder), to: store)
        #expect(saved.id == original.id)
        #expect(store.sources.count == 1)
        #expect(saved.url.absoluteString == "smb://127.0.0.1/Media/Movies")
        #expect(saved.configurationRevision > original.configurationRevision)
    }

    @Test func aChosenNameSurvivesAFolderEdit() {
        let setup = AppleNetworkShareSetup(
            purpose: .editFolder(UUID()),
            server: fixtureServer,
            currentLocation: AppleNetworkShareLocation(share: "Media"),
            existingName: "Living Room",
            client: SetupFakeClient()
        )
        #expect(setup.proposedName(for: AppleNetworkShareLocation(share: "Media", path: "Movies")) == "Living Room")
    }

    @Test func accountEditProvesTheFolderThenSavesInPlace() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let original = try store.addNetworkShare(
            name: "Media on Fixture NAS",
            host: "127.0.0.1",
            share: "Media",
            path: "Movies",
            username: "old-user",
            password: "old-password",
            displayHost: "fixture.example"
        )
        let client = SetupFakeClient(
            shares: [AppleSMBShare(name: "Media")],
            directories: ["Media/Movies": []],
            acceptedUsername: "fixture-user"
        )
        let setup = AppleNetworkShareSetup(
            purpose: .editAccount(original.id),
            server: fixtureServer,
            currentLocation: AppleNetworkShareLocation(share: "Media", path: "Movies"),
            existingName: original.name,
            savedCredentials: try store.networkCredentials(for: original),
            client: client
        )
        #expect(setup.outcome == .saveAccount)
        #expect(!setup.shouldConnectAutomatically)
        #expect(setup.fixedServer == fixtureServer)

        setup.username = "fixture-user"
        setup.password = "fixture-password"
        #expect(await setup.connect())
        #expect(await client.directoryRequests.map(\.absoluteString) == ["smb://127.0.0.1/Media/Movies"])
        #expect(setup.saveAccount(to: store))
        let saved = try #require(store.sources.first)
        #expect(saved.id == original.id)
        #expect(saved.url == original.url)
        #expect(try store.networkCredentials(for: saved)?.username == "fixture-user")
    }

    @Test func serverEditMakesTheAddressEditable() {
        let setup = AppleNetworkShareSetup(
            purpose: .editServer(UUID()),
            server: AppleNetworkShareServer(name: "NAS", host: "127.0.0.1", port: 1445),
            currentLocation: AppleNetworkShareLocation(share: "Media"),
            client: SetupFakeClient()
        )
        #expect(setup.fixedServer == nil)
        #expect(setup.address == "127.0.0.1")
        #expect(setup.port == "1445")
        #expect(setup.outcome == .browse)
    }

    @Test(arguments: [
        ("127.0.0.1", "127.0.0.1", 445),
        ("127.0.0.1:1445", "127.0.0.1", 1445),
        ("smb://fixture.example:2445/Media", "fixture.example", 2445),
        ("\\\\fixture.example", "fixture.example", 445),
        ("[fe80::1]:1445", "fe80::1", 1445),
        ("fe80::1", "fe80::1", 445),
    ])
    func addressParsing(_ value: String, _ host: String, _ port: Int) throws {
        let server = try AppleNetworkSharePolicy.server(address: value, port: "")
        #expect(server.host == host)
        #expect(server.port == port)
    }

    @Test(arguments: ["", "  ", "user@fixture.example", "fixture.example/Media", "127.0.0.1:99999"])
    func invalidAddressesAreRejected(_ value: String) {
        #expect(throws: AppleSMBError.self) { try AppleNetworkSharePolicy.server(address: value, port: "") }
    }

    @Test func advancedPortMustBeANumberInRange() {
        #expect(throws: AppleSMBError.invalidPort) { try AppleNetworkSharePolicy.server(address: "127.0.0.1", port: "abc") }
        #expect(throws: AppleSMBError.invalidPort) { try AppleNetworkSharePolicy.server(address: "127.0.0.1", port: "0") }
    }
    @Test func selectionsSurviveBrowsingAndRejectOverlaps() async throws {
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: SetupFakeClient(
            shares: [AppleSMBShare(name: "Media")], directories: ["Media": [], "Media/TV": []]))
        #expect(await setup.connect())
        let movies = AppleNetworkShareLocation(share: "Media", path: "Movies")
        let episodeFolder = AppleNetworkShareLocation(share: "Media", path: "TV/Show")
        setup.toggleSelection(movies)
        _ = try await setup.listing(at: AppleNetworkShareLocation(share: "Media"))
        _ = try await setup.listing(at: AppleNetworkShareLocation(share: "Media", path: "TV"))
        setup.toggleSelection(episodeFolder)
        #expect(setup.selectedLocations == [movies, episodeFolder])
        #expect(setup.selectionState(for: movies) == .selected)
        #expect(setup.selectionState(for: movies.appending("4K")) == .overlap)
        #expect(setup.selectionState(for: AppleNetworkShareLocation(share: "Media")) == .overlap)
        #expect(setup.selectionState(for: AppleNetworkShareLocation(share: "Media", path: "Movies2")) == .available)
        #expect(setup.selectionState(for: AppleNetworkShareLocation(share: "Other", path: "Movies")) == .available)
        setup.toggleSelection(movies.appending("4K"))
        #expect(setup.selectedLocations.count == 2)
        setup.toggleSelection(movies)
        #expect(setup.selectionState(for: movies.appending("4K")) == .available)
        #expect(setup.selectedLocations == [episodeFolder])
    }

    @Test func alreadyAddedFoldersAreCheckedAndBlockParentsAndChildren() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let saved = try store.addNetworkShare(name: "Movies", host: "127.0.0.1", share: "Media", path: "Movies")
        let setup = AppleNetworkShareSetup(server: fixtureServer, existingSources: store.sources, client: SetupFakeClient())
        #expect(await setup.connect())
        #expect(setup.selectionState(for: .init(share: "MEDIA", path: "movies")) == .added)
        #expect(setup.selectionState(for: .init(share: "Media")) == .overlap)
        #expect(setup.selectionState(for: .init(share: "Media", path: "Movies/4K")) == .overlap)
        setup.toggleSelection(.init(share: "Media", path: "Movies"))
        #expect(setup.selectedLocations.isEmpty)
        let editing = AppleNetworkShareSetup(purpose: .editFolder(saved.id), server: fixtureServer,
            existingSources: store.sources, client: SetupFakeClient())
        #expect(await editing.connect())
        #expect(editing.selectionState(for: .init(share: "Media")) == .available)
    }

    @Test func severalFoldersSaveWithOneCredentialAndRemovalKeepsItUntilLastSource() async throws {
        let (store, keychain, cleanup) = try makeStore()
        defer { cleanup() }
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: SetupFakeClient())
        setup.account = .registered
        setup.username = "fixture-user"
        setup.password = "fixture-password"
        #expect(await setup.connect())
        let folders = [AppleNetworkShareLocation(share: "Media", path: "Movies"),
                       AppleNetworkShareLocation(share: "Media", path: "TV/Shows")]
        let drafts = folders.map { AppleNetworkShareNamedFolder(location: $0, name: setup.defaultName(for: $0)) }
        let added = try setup.saveFolders(drafts, to: store)
        try #require(added.count == 2)
        #expect(added.map(\.name) == ["Movies on Fixture NAS", "Shows on Fixture NAS"])
        let reference = try #require(added.first?.credentialReference)
        #expect(added.allSatisfy { $0.credentialReference == reference })
        #expect(keychain.values.count == 1)
        #expect(store.remove(id: added[0].id))
        #expect(try store.networkCredentials(for: added[1])?.password == "fixture-password")
        #expect(keychain.values[reference] != nil)
        #expect(store.remove(id: added[1].id))
        #expect(keychain.values[reference] == nil)
    }

    @Test func saveRechecksFoldersAddedWhileTheBrowserWasOpen() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: SetupFakeClient())
        #expect(await setup.connect())
        setup.toggleSelection(.init(share: "Media", path: "Movies/4K"))
        _ = try store.addNetworkShare(name: "Movies", host: "127.0.0.1", share: "Media", path: "Movies")
        #expect(throws: AppleNetworkShareSelectionError.overlap) {
            try setup.saveFolders([.init(location: .init(share: "Media", path: "Movies/4K"), name: "4K")], to: store)
        }
        #expect(store.sources.count == 1)
        setup.updateExistingSources(store.sources)
        #expect(setup.selectedLocations.isEmpty)
        #expect(setup.selectionState(for: .init(share: "Media", path: "Movies/4K")) == .overlap)
        setup.toggleSelection(.init(share: "Media", path: "Shows"))
        #expect(setup.selectedLocations == [.init(share: "Media", path: "Shows")])
    }

    @Test func groupUsesServerPortAndShareAndPreservesFolderRows() throws {
        let movie = AppleSource(kind: .nas, name: "Movies", url: try #require(URL(string: "smb://fixture.example/Media/Movies")))
        let tv = AppleSource(kind: .nas, name: "TV", url: try #require(URL(string: "smb://FIXTURE.example/media/TV")))
        let otherShare = AppleSource(kind: .nas, name: "Archive", url: try #require(URL(string: "smb://fixture.example/Archive")))
        let otherPort = AppleSource(kind: .nas, name: "Other", url: try #require(URL(string: "smb://fixture.example:1445/Media")))
        let live = AppleSource(kind: .liveTV, name: "Live", url: try #require(URL(string: "https://fixture.example/")))
        let groups = AppleNetworkSharePolicy.groups(in: [movie, live, tv, otherShare, otherPort])
        try #require(groups.count == 3)
        #expect(groups[0].sources.map(\.id) == [movie.id, tv.id])
        #expect(groups[0].title == "Media on fixture.example")
        #expect(groups[1].sources.map(\.id) == [otherShare.id])
        #expect(groups[2].sources.map(\.id) == [otherPort.id])
    }

    @Test(arguments: [("127.0.0.1", "other-user"), ("127.0.0.2", "fixture-user")])
    func changingSharedAccountOrServerDoesNotOverwriteSiblingCredentials(_ host: String, _ username: String) throws {
        let (store, keychain, cleanup) = try makeStore()
        defer { cleanup() }
        let first = try store.addNetworkShare(name: "Movies", host: "127.0.0.1", share: "Media", path: "Movies",
            username: "fixture-user", password: "fixture-password")
        let second = try store.addNetworkShare(name: "Shows", host: "127.0.0.1", share: "Media", path: "Shows",
            username: "fixture-user", password: "fixture-password")
        #expect(first.credentialReference == second.credentialReference)
        let edited = try store.updateNetworkShare(id: first.id, name: first.name, host: host, port: 445,
            share: "Media", path: "Movies", credentials: .init(username: username, password: "other-password"),
            displayHost: nil, validationSummary: "Connected")
        #expect(edited.credentialReference != second.credentialReference)
        #expect(try store.networkCredentials(for: second)?.username == "fixture-user")
        #expect(try store.networkCredentials(for: second)?.password == "fixture-password")
        #expect(try store.networkCredentials(for: edited)?.username == username)
        let detachedReference = try #require(edited.credentialReference)
        let rejoined = try store.updateNetworkShare(id: first.id, name: first.name, host: "127.0.0.1", port: 445,
            share: "Media", path: "Movies", credentials: .init(username: "fixture-user", password: "fixture-password"),
            displayHost: nil, validationSummary: "Connected")
        #expect(rejoined.credentialReference == second.credentialReference)
        #expect(keychain.values[detachedReference] == nil)
        #expect(store.remove(id: rejoined.id))
        #expect(try store.networkCredentials(for: second)?.password == "fixture-password")
    }

    @Test func anUnreadableSiblingCredentialDoesNotBlockAddingAFolder() async throws {
        let (store, keychain, cleanup) = try makeStore()
        defer { cleanup() }
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: SetupFakeClient())
        #expect(await setup.connect())
        // Read 1 is the first folder's own entry; read 2 is the sibling lookup for the second.
        keychain.failOnRead = 2
        let added = try setup.saveFolders([
            .init(location: .init(share: "Media", path: "Movies"), name: "Movies"),
            .init(location: .init(share: "Media", path: "TV"), name: "TV"),
        ], to: store)
        #expect(added.count == 2)
        #expect(store.sources.count == 2)
        // The unreadable sibling isn't a key to share, so the second folder keeps its own.
        #expect(added[0].credentialReference != added[1].credentialReference)
        #expect(keychain.values.count == 2)
    }

    @Test func aKeychainFailureRollsBackTheWholeFolderBatch() async throws {
        let (store, keychain, cleanup) = try makeStore()
        defer { cleanup() }
        let setup = AppleNetworkShareSetup(server: fixtureServer, client: SetupFakeClient())
        #expect(await setup.connect())
        // Read 3 is the second folder's own entry (the sibling lookup at read 2 may fail quietly).
        keychain.failOnRead = 3
        #expect(throws: AppleKeychainStoreError.self) {
            try setup.saveFolders([
                .init(location: .init(share: "Media", path: "Movies"), name: "Movies"),
                .init(location: .init(share: "Media", path: "TV"), name: "TV"),
            ], to: store)
        }
        #expect(store.sources.isEmpty)
        #expect(keychain.values.isEmpty)
        keychain.failOnRead = nil
        let retry = try setup.saveFolders([
            .init(location: .init(share: "Media", path: "Movies"), name: "Movies"),
            .init(location: .init(share: "Media", path: "TV"), name: "TV"),
        ], to: store)
        #expect(retry.count == 2)
        #expect(store.sources.count == 2)
    }

    @Test func addFolderStartsAtItsShareWithTheSavedAccount() async throws {
        let (store, keychain, cleanup) = try makeStore()
        defer { cleanup() }
        let source = try store.addNetworkShare(name: "Movies", host: "127.0.0.1", share: "Media", path: "Movies",
            username: "fixture-user", password: "fixture-password")
        let client = SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "fixture-user")
        let setup = try #require(AppleNetworkShareSetup.make(for: .addFolder(source.id), sourceStore: store, client: client))
        #expect(setup.shouldConnectAutomatically)
        #expect(await setup.connectWithSavedCredentials())
        #expect(setup.initialBrowseLocation == AppleNetworkShareLocation(share: "Media"))
        #expect(setup.selectionState(for: .init(share: "Media", path: "Movies")) == .added)
        #expect(setup.selectedLocations.isEmpty)
        #expect(setup.credentials?.username == "fixture-user")
        _ = try store.addNetworkShare(name: "Shows", host: "127.0.0.1", share: "Media", path: "Shows",
            username: "second-user", password: "fixture-password")
        let reference = try #require(source.credentialReference)
        keychain.values.removeValue(forKey: reference)
        let fallback = try #require(AppleNetworkShareSetup.make(for: .addFolder(source.id), sourceStore: store,
            client: SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "second-user")))
        #expect(fallback.shouldConnectAutomatically)
        #expect(await fallback.connectWithSavedCredentials())
        #expect(fallback.credentials?.username == "second-user")
    }

    @Test func addingTVFromMoviesSettingsPreservesBothFolders() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let movies = try store.addNetworkShare(name: "Movies", host: "127.0.0.1", share: "Media", path: "Movies",
            username: "fixture-user", password: "fixture-password")
        let setup = try #require(AppleNetworkShareSetup.make(for: .addFolder(movies.id), sourceStore: store,
            client: SetupFakeClient(shares: [AppleSMBShare(name: "Media")], acceptedUsername: "fixture-user")))
        #expect(await setup.connectWithSavedCredentials())
        let added = try setup.saveFolders([.init(location: .init(share: "Media", path: "TV"), name: "TV")], to: store)
        #expect(added.count == 1)
        #expect(store.sources.first { $0.id == movies.id }?.url == movies.url)
        #expect(Set(store.sources.compactMap { try? AppleSMBEndpointPolicy.parts(from: $0.url).path }) == ["Movies", "TV"])
        let tv = try #require(store.sources.first { $0.id != movies.id })
        #expect(try store.networkCredentials(for: tv)?.username == "fixture-user")
    }

    @Test func aNewPasswordForTheSameServerAccountReusesItsCredentialAndInvalidatesSiblings() throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let first = try store.addNetworkShare(name: "Movies", host: "127.0.0.1", share: "Media", path: "Movies",
            username: "fixture-user", password: "fixture-password")
        let second = try store.addNetworkShare(name: "Shows", host: "127.0.0.1", share: "Media", path: "Shows",
            username: "fixture-user", password: "new-fixture-password")
        #expect(first.credentialReference == second.credentialReference)
        #expect(try store.networkCredentials(for: first)?.password == "new-fixture-password")
        let updated = try #require(store.sources.first { $0.id == first.id })
        #expect(updated.configurationRevision > first.configurationRevision)
    }

}

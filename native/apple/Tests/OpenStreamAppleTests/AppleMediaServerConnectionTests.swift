import Foundation
import Synchronization
import Testing
@testable import OpenStreamApple

@Suite("Media server connection authentication")
struct AppleMediaServerConnectionTests {
    @Test(arguments: [AppleMediaServerKind.jellyfin, .emby], [false, true])
    func passwordTestAuthenticatesAfterPublicInfo(kind: AppleMediaServerKind, accepted: Bool) async throws {
        let paths = Mutex<[String]>([])
        let client = AppleMediaServerClient(loader: { request in
            let url = try #require(request.url)
            paths.withLock { $0.append(url.path) }
            if url.path.hasSuffix("System/Info/Public") {
                return try Self.reply(request, body: #"{"ServerName":"Fixture","Version":"1"}"#)
            }
            #expect(request.httpMethod == "POST")
            let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
            #expect(body["Username"] == "fixture-user")
            #expect(body["Pw"] == (accepted ? "fixture-password" : "incorrect"))
            return try Self.reply(request, status: accepted ? 200 : 401,
                body: #"{"User":{"Id":"fixture-user"},"AccessToken":"fixture-token"}"#)
        }, deviceID: "fixture")
        if accepted {
            let session = try await client.authenticate(address: "https://fixture.example/jf", kind: kind,
                username: "fixture-user", password: "fixture-password")
            #expect(session.kind == kind)
            #expect(session.userID == "fixture-user")
            #expect(session.serverName == "Fixture")
        } else {
            await #expect(throws: AppleMediaServerError.invalidCredentials) {
                try await client.authenticate(address: "https://fixture.example/jf", kind: kind,
                    username: "fixture-user", password: "incorrect")
            }
        }
        #expect(paths.withLock { $0 } == ["/jf/System/Info/Public", "/jf/Users/AuthenticateByName"])
    }

    @Test(arguments: AppleMediaServerKind.allCases, [200, 401, 403, 500, 503])
    func storedTokenMustReachAProtectedEndpoint(kind: AppleMediaServerKind, status: Int) async throws {
        let loader: AppleMediaServerClient.Loader = { request in
            if kind == .plex {
                #expect(request.url?.path == "/jf/library/sections")
                #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "fixture-token")
                return try Self.reply(request, status: status, body: #"{"MediaContainer":{"Directory":[]}}"#)
            }
            #expect(["/jf/Users/Me", "/jf/Users/fixture-user"].contains(request.url?.path))
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
            return try Self.reply(request, status: status, body: #"{"Id":"fixture-user"}"#)
        }
        let client = AppleMediaServerClient(loader: loader, deviceID: "fixture")
        let session = try Self.session(kind)
        if status == 200 {
            try await client.validateSession(session, plexClient: .init(loader: loader))
        } else {
            await #expect(throws: status == 401 ? AppleMediaServerError.invalidCredentials : .server(status: status)) {
                try await client.validateSession(session, plexClient: .init(loader: loader))
            }
        }
    }

    /// Rill answers Users/Me but has no Users/{id}; a server without Users/Me still validates through Users/{id}.
    @Test(arguments: [(meStatus: 200, expectedPaths: ["/jf/Users/Me"]),
                      (meStatus: 404, expectedPaths: ["/jf/Users/Me", "/jf/Users/fixture-user"])])
    func sessionCheckPrefersUsersMe(meStatus: Int, expectedPaths: [String]) async throws {
        let paths = Mutex<[String]>([])
        let loader: AppleMediaServerClient.Loader = { request in
            let path = request.url?.path ?? ""
            paths.withLock { $0.append(path) }
            let status = path == "/jf/Users/Me" ? meStatus : 200
            return try Self.reply(request, status: status, body: #"{"Id":"fixture-user"}"#)
        }
        let client = AppleMediaServerClient(loader: loader, deviceID: "fixture")
        try await client.validateSession(Self.session(.jellyfin), plexClient: .init(loader: loader))
        #expect(paths.withLock { $0 } == expectedPaths)
    }

    @Test(arguments: AppleMediaServerKind.allCases,
          [URLError.Code.cannotConnectToHost, .timedOut, .serverCertificateUntrusted, .secureConnectionFailed,
           .appTransportSecurityRequiresSecureConnection])
    func transportFailuresStayDistinct(kind: AppleMediaServerKind, code: URLError.Code) async throws {
        let loader: AppleMediaServerClient.Loader = { _ in throw URLError(code) }
        let client = AppleMediaServerClient(loader: loader, deviceID: "fixture")
        let expected: AppleMediaServerError = code == .serverCertificateUntrusted || code == .secureConnectionFailed
            ? .tlsFailure : .unreachable
        await #expect(throws: expected) {
            try await client.validateSession(Self.session(kind), plexClient: .init(loader: loader))
        }
        #expect(AppleMediaServerFormPolicy.message(for: .tlsFailure)
            != AppleMediaServerFormPolicy.message(for: .unreachable))
        #expect(AppleMediaServerFormPolicy.message(for: .tlsFailure)
            != AppleMediaServerFormPolicy.message(for: .invalidCredentials))
    }

    @Test func certificateFailureDoesNotDowngradeToHTTP() async {
        let client = AppleMediaServerClient(loader: { request in
            #expect(request.url?.scheme == "https")
            throw URLError(.serverCertificateUntrusted)
        }, deviceID: "fixture")
        await #expect(throws: AppleMediaServerError.tlsFailure) {
            try await client.authenticate(address: "fixture.example", kind: .jellyfin,
                username: "fixture-user", password: "fixture-password")
        }
    }

    @Test(arguments: [401, 403])
    func plexPublicIdentityCannotHideARejectedToken(status: Int) async throws {
        let client = ApplePlexClient(loader: { request in
            #expect(request.url?.path == "/library/sections")
            return try Self.reply(request, status: request.url?.path == "/identity" ? 200 : status)
        })
        let resource = ApplePlexResource(name: "Fixture", clientIdentifier: "fixture-server", provides: "server",
            accessToken: "fixture-token", owned: true, connections: [
                .init(uri: "https://fixture.example", protocol: "https", address: "fixture.example",
                      port: 443, local: true, relay: false)
            ])
        await #expect(throws: status == 401 ? AppleMediaServerError.invalidCredentials : .server(status: status)) {
            try await client.firstReachableConnection(for: resource)
        }
    }

    @MainActor @Test(arguments: AppleMediaServerKind.allCases, [false, true])
    func disabledSourceReusesKeychainAcrossRelaunch(kind: AppleMediaServerKind, staleSignIn: Bool) async throws {
        let suite = "media-server-enable-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = ConnectionTestCredentials()
        var store = AppleSourceStore(defaults: defaults, keychain: keys)
        let session = try Self.session(kind)
        let added = try store.addMediaServer(kind: kind, name: "Fixture", session: session)
        try await store.setEnabled(false, id: added.id)
        let savedCredentials = keys.values
        if staleSignIn {
            var portable = AppleConfigurationSnapshot.portableSource(try #require(store.sources.first))
            portable.isEnabled = false
            defaults.set(try JSONEncoder().encode([portable]), forKey: AppleSourceStore.defaultStorageKey)
        }
        store = AppleSourceStore(defaults: defaults, keychain: keys)
        let disabled = try #require(store.sources.first)
        #expect(!disabled.isEnabled)
        #expect(added.credentialReference == AppleSourceStore.mediaServerCredentialReference(for: added.id))
        if staleSignIn {
            #expect(disabled.needsSignIn)
            #expect(disabled.credentialReference == nil)
            #expect(keys.values[AppleSourceStore.mediaServerCredentialReference(for: disabled.id)] != nil)
        }
        #expect(AppleSourceEnableControl.control(for: disabled,
            hasSavedMediaServerSession: try await store.hasSavedMediaServerSession(for: disabled)) == .toggle)
        let loader: AppleMediaServerClient.Loader = { request in
            #expect(request.httpMethod == "GET")
            return try Self.reply(request, body: kind == .plex
                ? #"{"MediaContainer":{"Directory":[]}}"# : #"{"Id":"fixture-user"}"#)
        }
        try await store.setEnabled(true, id: added.id, client: .init(loader: loader), plexClient: .init(loader: loader))
        let enabled = try #require(store.sources.first)
        #expect(enabled.isEnabled)
        #expect(!enabled.needsSignIn)
        #expect(enabled.url == session.baseURL)
        #expect(try store.mediaServerSession(for: enabled) == session)
        #expect(keys.values == savedCredentials)
        #expect(keys.removals.isEmpty)
        store = AppleSourceStore(defaults: defaults, keychain: keys)
        #expect(store.sources.first?.isEnabled == true)
        #expect(store.sources.first?.needsSignIn == false)
    }

    @MainActor @Test(arguments: AppleMediaServerKind.allCases, [0, 401, 403, 500, 503, -1001, -1202, -999])
    func enableOnlyRequestsSignInForMissingOrRejectedCredentials(kind: AppleMediaServerKind, status: Int) async throws {
        let suite = "media-server-rejection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = ConnectionTestCredentials()
        var store = AppleSourceStore(defaults: defaults, keychain: keys)
        let added = try store.addMediaServer(kind: kind, name: "Fixture", session: Self.session(kind))
        try await store.setEnabled(false, id: added.id)
        if status == 0 { keys.values.removeValue(forKey: try #require(added.credentialReference)) }
        let savedCredentials = keys.values
        let loader: AppleMediaServerClient.Loader = { request in
            #expect(status != 0)
            if status < 0 { throw URLError(URLError.Code(rawValue: status)) }
            return try Self.reply(request, status: status)
        }
        await #expect(throws: (any Error).self) {
            try await store.setEnabled(true, id: added.id, client: .init(loader: loader), plexClient: .init(loader: loader))
        }
        let source = try #require(store.sources.first)
        #expect(!source.isEnabled)
        #expect(source.needsSignIn == (status == 0 || status == 401))
        #expect(keys.removals.isEmpty)
        #expect(keys.values == savedCredentials)
        if status != 0 { #expect(try store.mediaServerSession(for: source) != nil) }
        if status == 0 || status == 401 {
            store = AppleSourceStore(defaults: defaults, keychain: keys)
            let reloaded = try #require(store.sources.first)
            #expect(reloaded.needsSignIn)
            #expect(AppleSourceEnableControl.control(for: reloaded, hasSavedMediaServerSession: nil) == .signIn)
            #expect(AppleSourceEnableControl.control(for: reloaded,
                hasSavedMediaServerSession: try await store.hasSavedMediaServerSession(for: reloaded)) == .signIn)
        }
        if [403, 500, 503].contains(status) {
            let retry: AppleMediaServerClient.Loader = { request in
                try Self.reply(request, body: kind == .plex
                    ? #"{"MediaContainer":{}}"# : #"{"Id":"fixture-user"}"#)
            }
            try await store.setEnabled(true, id: source.id, client: .init(loader: retry), plexClient: .init(loader: retry))
            #expect(store.sources.first?.isEnabled == true)
            #expect(store.sources.first?.needsSignIn == false)
            #expect(keys.values == savedCredentials)
        }
    }

    @MainActor @Test(arguments: AppleMediaServerKind.allCases)
    func reconnectingUpdatesTheSameSourceEvenWhenAddressAndAccountChange(kind: AppleMediaServerKind) throws {
        let suite = "media-server-reconnect-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = ConnectionTestCredentials()
        var store = AppleSourceStore(defaults: defaults, keychain: keys)
        let original = try store.addMediaServer(kind: kind, name: "Fixture", session: Self.session(kind))
        var portable = AppleConfigurationSnapshot.portableSource(original)
        portable.isEnabled = false
        defaults.set(try JSONEncoder().encode([portable]), forKey: AppleSourceStore.defaultStorageKey)
        store = AppleSourceStore(defaults: defaults, keychain: keys)
        let replacement = AppleMediaServerSession(kind: kind,
            baseURL: try #require(URL(string: "https://moved.fixture.example/server")),
            accessToken: "replacement-token", userID: "replacement-user")
        let updated = try store.addMediaServer(kind: kind, name: "Reconnected", session: replacement,
            reconnecting: original.id)
        #expect(store.sources.count == 1)
        #expect(updated.id == original.id)
        #expect(updated.addedAt == original.addedAt)
        #expect(updated.isEnabled)
        #expect(!updated.needsSignIn)
        #expect(updated.configurationRevision > original.configurationRevision)
        #expect(try store.mediaServerSession(for: updated) == replacement)
        store = AppleSourceStore(defaults: defaults, keychain: keys)
        #expect(store.sources.map(\.id) == [original.id])
        #expect(try store.mediaServerSession(for: #require(store.sources.first)) == replacement)
    }

    @MainActor @Test(arguments: AppleMediaServerKind.allCases, [200, 401])
    func configurationChangesDuringValidationAreReported(kind: AppleMediaServerKind, status: Int) async throws {
        let suite = "media-server-race-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = ConnectionTestCredentials()
        let store = AppleSourceStore(defaults: defaults, keychain: keys)
        let source = try store.addMediaServer(kind: kind, name: "Fixture", session: Self.session(kind))
        try await store.setEnabled(false, id: source.id)
        let savedSession = try store.mediaServerSession(for: source)
        let loader: AppleMediaServerClient.Loader = { request in
            _ = try await MainActor.run {
                try store.addMediaServer(kind: kind, name: "Updated Fixture", session: Self.session(kind))
            }
            return try Self.reply(request, status: status, body: kind == .plex
                ? #"{"MediaContainer":{}}"# : #"{"Id":"fixture-user"}"#)
        }
        await #expect(throws: AppleMediaServerError.configurationChanged) {
            try await store.enableMediaServer(id: source.id, client: .init(loader: loader), plexClient: .init(loader: loader))
        }
        #expect(store.sources.first?.isEnabled == false)
        #expect(store.sources.first?.needsSignIn == false)
        #expect(try store.mediaServerSession(for: source) == savedSession)
    }

    @MainActor @Test(arguments: [true, false])
    func savedSessionLookupHasANeutralInitialState(needsSignIn: Bool) throws {
        var source = AppleSource(kind: .mediaServer, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example")), serverKind: .jellyfin)
        source.needsSignIn = needsSignIn
        #expect(AppleSourceEnableControl.control(for: source, hasSavedMediaServerSession: nil) == .checking)
        #expect(AppleSourceEnableControl.control(for: source, hasSavedMediaServerSession: true) == .toggle)
        #expect(AppleSourceEnableControl.control(for: source, hasSavedMediaServerSession: false)
            == (needsSignIn ? .signIn : .toggle))
    }

    @MainActor @Test(arguments: AppleMediaServerKind.allCases)
    func rejectedImportedSessionStillRequiresSignInAfterRelaunch(kind: AppleMediaServerKind) async throws {
        let suite = "media-server-import-rejected-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = ConnectionTestCredentials()
        var store = AppleSourceStore(defaults: defaults, keychain: keys)
        let added = try store.addMediaServer(kind: kind, name: "Fixture", session: Self.session(kind))
        var portable = AppleConfigurationSnapshot.portableSource(added)
        portable.isEnabled = false
        defaults.set(try JSONEncoder().encode([portable]), forKey: AppleSourceStore.defaultStorageKey)
        store = AppleSourceStore(defaults: defaults, keychain: keys)
        let loader: AppleMediaServerClient.Loader = { request in try Self.reply(request, status: 401) }
        await #expect(throws: AppleMediaServerError.invalidCredentials) {
            try await store.setEnabled(true, id: added.id, client: .init(loader: loader), plexClient: .init(loader: loader))
        }
        store = AppleSourceStore(defaults: defaults, keychain: keys)
        let rejected = try #require(store.sources.first)
        #expect(!rejected.isEnabled)
        #expect(try await store.hasSavedMediaServerSession(for: rejected))
        #expect(AppleSourceEnableControl.control(for: rejected, hasSavedMediaServerSession: true) == .signIn)
    }

    @MainActor @Test(arguments: AppleMediaServerKind.allCases)
    func configurationRestoreCannotReenableAMediaServerWithoutValidation(kind: AppleMediaServerKind) async throws {
        let suite = "media-server-restore-enable-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppleSourceStore(defaults: defaults, keychain: ConnectionTestCredentials())
        let added = try store.addMediaServer(kind: kind, name: "Fixture", session: Self.session(kind))
        try await store.setEnabled(false, id: added.id)
        try store.restoreConfigurationSources([added], secrets: nil)
        #expect(store.sources.first?.isEnabled == false)
        #expect(throws: AppleMediaServerError.unsupported) {
            try store.restoreSourceSignIn(id: added.id, address: added.url, username: "fixture", password: "fixture")
        }
        #expect(store.sources.first?.isEnabled == false)
    }

    @MainActor @Test(arguments: [true, false])
    func plexSaveFailureNamesTheResourceAndKeepsTheFormOpen(singleServer: Bool) async throws {
        let suite = "plex-save-error-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppleSourceStore(defaults: defaults, keychain: ConnectionTestCredentials())
        let client = ApplePlexClient(loader: { request in
            switch request.url?.path {
            case "/api/v2/user": return try Self.reply(request, body: #"{"id":1,"username":"fixture"}"#)
            case "/api/v2/resources":
                let resource = #"{"name":"Fixture Plex","clientIdentifier":"fixture","provides":"server","accessToken":"fixture-token","owned":true,"connections":[{"uri":"https://fixture.example","protocol":"https","address":"fixture.example","port":443,"local":true,"relay":false}]}"#
                return try Self.reply(request, body: "[" + (singleServer ? resource : resource + "," + resource) + "]")
            default: throw URLError(.cannotConnectToHost)
            }
        })
        let model = PlexSignInModel(client: client, sourceStore: store)
        await model.handleToken("fixture-account-token")
        if !singleServer { await model.saveSelectedServer() }
        #expect(model.isError)
        #expect(model.message == "Can't reach Fixture Plex right now.")
        #expect(!model.isDone)
        #expect(store.sources.isEmpty)
    }

    private static func session(_ kind: AppleMediaServerKind) throws -> AppleMediaServerSession {
        AppleMediaServerSession(kind: kind, baseURL: try #require(URL(string: "https://fixture.example/jf")),
            accessToken: "fixture-token", userID: "fixture-user")
    }

    private static func reply(_ request: URLRequest, status: Int = 200, body: String = "") throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}

private final class ConnectionTestCredentials: AppleCredentialStoring {
    var values: [String: String] = [:]
    var removals: [String] = []
    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { removals.append(account); values.removeValue(forKey: account) }
}

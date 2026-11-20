#if DEBUG && os(visionOS)
import Foundation

/// `-OpenStreamImmersiveProbe YES`: once a VR file is in AVKit's immersive
/// view, walks it through pause, play, a seek and the way out, holding each
/// state long enough for a simulator screenshot. Each step is a trace line
/// (`immersive probe: …`) the capture script waits for.
@MainActor
enum AppleDebugImmersiveProbe {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "OpenStreamImmersiveProbe") }
    private static var proxy: AppleSMBRangeServer?

    /// Exercises the production HTTP range bridge without a saved share or credentials.
    static func proxyRequest(_ request: ApplePlaybackRequest) async throws -> ApplePlaybackRequest {
        guard request.url.isFileURL else { return request }
        let payload = try Data(contentsOf: request.url, options: .mappedIfSafe)
        let server = AppleSMBRangeServer(client: FileShare(payload: payload,
            stalls: UserDefaults.standard.bool(forKey: "OpenStreamImmersiveProxyStall")), addedLatency: .zero)
        proxy = server
        var proxied = request
        var components = URLComponents()
        components.scheme = "smb"
        components.host = "fixture.example"
        components.path = "/media/" + request.url.lastPathComponent
        guard let source = components.url else { throw AppleSMBRangeServerError.invalidMedia }
        proxied.url = try await server.playbackURL(sourceURL: source,
            credentials: AppleSMBCredentials(username: "", password: ""), sizeBytes: Int64(payload.count))
        proxied.hints.filename = request.url.lastPathComponent
        appleTrace("immersive probe: share proxy")
        return proxied
    }

    private struct FileShare: AppleNetworkShareClient {
        let payload: Data
        let stalls: Bool
        func listShares(host: String, port: Int, credentials: AppleSMBCredentials) async throws -> [AppleSMBShare] { [] }
        func listDirectory(url: URL, credentials: AppleSMBCredentials, recursive: Bool) async throws -> [AppleSMBDirectoryEntry] { [] }
        func read(url: URL, credentials: AppleSMBCredentials, range: Range<UInt64>) async throws -> Data {
            try Task.checkCancellation()
            if stalls { try await Task.sleep(for: .seconds(30)) }
            return payload.subdata(in: min(Int(range.lowerBound), payload.count)..<min(Int(range.upperBound), payload.count))
        }
    }

    static func run(host: ApplePlayerHost, coordinator: ApplePlaybackCoordinator, close: () -> Void) async {
        guard #available(visionOS 26.0, *) else { return }
        let engine = coordinator.engine
        func mark(_ step: String) async -> Bool {
            do { try await Task.sleep(for: .seconds(1)) } catch { return false }
            appleTrace("immersive probe: \(step) phase=\(coordinator.phase) position=\(String(format: "%.1f", engine.position))")
            do { try await Task.sleep(for: .seconds(4)) } catch { return false }
            return !Task.isCancelled
        }
        guard await mark("immersive") else { return }
        engine.pause()
        guard await mark("paused") else { return }
        engine.play()
        guard await mark("playing") else { return }
        await engine.seek(to: min(30, (engine.duration ?? 0) / 2))
        guard await mark("seeked") else { return }
        await host.leaveImmersive()
        guard await mark("left") else { return }
        close()
        appleTrace("immersive probe: closed")
    }
}
#endif

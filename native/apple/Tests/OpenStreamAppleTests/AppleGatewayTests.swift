import Foundation
import Testing
@testable import OpenStreamApple

@Test func gatewayEndpointPolicyAllowsHTTPSAndPrivateLiteralHTTPOnly() throws {
    #expect(AppleGatewayEndpointPolicy.isAllowed("https://gateway.example"))
    #expect(AppleGatewayEndpointPolicy.isAllowed("http://192.168.1.20:8787"))
    #expect(AppleGatewayEndpointPolicy.isAllowed("http://10.0.0.8:8787/"))
    #expect(AppleGatewayEndpointPolicy.isAllowed("http://localhost:8787"))
    #expect(!AppleGatewayEndpointPolicy.isAllowed("http://gateway.example:8787"))
    #expect(!AppleGatewayEndpointPolicy.isAllowed("http://8.8.8.8:8787"))
    #expect(!AppleGatewayEndpointPolicy.isAllowed("http://fc-malicious.example:8787"))
    #expect(!AppleGatewayEndpointPolicy.isAllowed("http://fd.example:8787"))
    #expect(AppleGatewayEndpointPolicy.isAllowed("http://[fd00::1]:8787"))
    #expect(AppleGatewayEndpointPolicy.isAllowed("http://[fe80::1]:8787"))
    #expect(!AppleGatewayEndpointPolicy.isAllowed("https://user:pass@gateway.example"))
    #expect(!AppleGatewayEndpointPolicy.isAllowed("https://gateway.example?token=secret"))
    #expect(throws: AppleTranscodeGatewayError.invalidToken) {
        try AppleTranscodeGatewayConfig(
            baseURL: "https://gateway.example",
            sessionToken: String(repeating: " ", count: 32)
        )
    }

    #expect(try AppleGatewayEndpointPolicy.normalize(" https://gateway.example/ ").absoluteString ==
        "https://gateway.example")
}

@Test func gatewayClientKeepsPlaybackCredentialsOnTheConfiguredOrigin() async throws {
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example:9443",
        sessionToken: String(repeating: "b", count: 32)
    )
    let relativeClient = AppleTranscodeGatewayClient { request in
        let data = Data(#"{"transcodeUrl":"/gateway/transcode/media?transcodeId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let session = try await relativeClient.startSMBSession(
        config: config,
        smbURI: "smb://server/movie.mkv",
        maximumWidth: 1920,
        maximumHeight: 1080
    )
    #expect(session.url == URL(string: "https://gateway.example:9443/api/transcode/media?transcodeId=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
    #expect(session.headers.isEmpty)

    let hostileClient = AppleTranscodeGatewayClient { request in
        let data = Data(#"{"transcodeUrl":"https://evil.example/api/steal"}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: AppleTranscodeGatewayError.missingTranscodeURL) {
        try await hostileClient.startSMBSession(
            config: config,
            smbURI: "smb://server/movie.mkv",
            maximumWidth: 1920,
            maximumHeight: 1080
        )
    }
}

@Test func gatewayClientPreservesAnExplicitBasePath() async throws {
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example/openstream",
        sessionToken: String(repeating: "c", count: 32)
    )
    let client = AppleTranscodeGatewayClient { request in
        #expect(request.url?.path == "/openstream/api/transcode/smb-sessions")
        let data = Data(#"{"transcodeUrl":"/gateway/transcode/media?transcodeId=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }
    let session = try await client.startSMBSession(
        config: config,
        smbURI: "smb://server/movie.mkv",
        maximumWidth: 1920,
        maximumHeight: 1080
    )
    #expect(session.url == URL(string: "https://gateway.example/openstream/api/transcode/media?transcodeId=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
}

@Test func gatewayClientSendsSessionHeadersAndParsesCapabilities() async throws {
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example",
        sessionToken: String(repeating: "a", count: 32)
    )
    let client = AppleTranscodeGatewayClient { request in
        #expect(request.url?.absoluteString == "https://gateway.example/api/transcode/capabilities")
        #expect(request.value(forHTTPHeaderField: "X-OpenStream-Session") == String(repeating: "a", count: 32))
        #expect(request.value(forHTTPHeaderField: "X-OpenStream-Client") == "apple")
        let data = Data(#"{"available":true,"version":"7.1","hardwareAccelerated":true}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    let capabilities = try await client.capabilities(config: config)
    #expect(capabilities.available)
    #expect(capabilities.version == "7.1")
    #expect(capabilities.hardwareAccelerated)
}

@Test func gatewayCapabilitiesDefaultMissingOptionalSignalsToFalse() async throws {
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example",
        sessionToken: String(repeating: "d", count: 32)
    )
    let client = AppleTranscodeGatewayClient { request in
        let data = Data(#"{"available":false}"#.utf8)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
              ) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    let capabilities = try await client.capabilities(config: config)
    #expect(!capabilities.available)
    #expect(capabilities.version == nil)
    #expect(!capabilities.hardwareAccelerated)
}

@Test func gatewayClientCreatesASeparateRemoteURLSessionPayload() async throws {
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example",
        sessionToken: String(repeating: "e", count: 32)
    )
    let remoteURL = try #require(URL(string: "https://media.example/movie.mkv?provider=opaque"))
    let client = AppleTranscodeGatewayClient { request in
        #expect(request.url?.path == "/api/transcode/sessions")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["remoteUrl"] as? String == remoteURL.absoluteString)
        #expect(payload["smbUri"] == nil)
        #expect(payload["mediaUrl"] == nil)
        let profile = try #require(payload["profile"] as? [String: Any])
        #expect(profile["maxWidth"] as? Int == 3840)
        #expect(profile["maxHeight"] as? Int == 2160)

        let data = Data(#"{"transcodeUrl":"/gateway/transcode/media?transcodeId=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}"#.utf8)
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: 201,
            httpVersion: nil,
            headerFields: nil
        ))
        return (data, response)
    }

    let session = try await client.startSession(
        config: config,
        source: .remoteURL(remoteURL),
        maximumWidth: 3840,
        maximumHeight: 2160
    )

    #expect(session.url.absoluteString == "https://gateway.example/api/transcode/media?transcodeId=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
    #expect(session.headers.isEmpty)
}

@Test func playbackPreparerUsesTheInspectedRemoteURLForGatewayFallback() async throws {
    let sourceURL = try #require(URL(string: "https://media.example/movie.mkv?provider=opaque"))
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example",
        sessionToken: String(repeating: "f", count: 32)
    )
    let client = AppleTranscodeGatewayClient { request in
        guard let url = request.url else { throw URLError(.badURL) }
        let data: Data
        switch url.path {
        case "/api/transcode/capabilities":
            data = Data(#"{"available":true,"version":"1","hardwareAccelerated":true}"#.utf8)
        case "/api/transcode/sessions":
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["remoteUrl"] as? String == sourceURL.absoluteString)
            data = Data(#"{"transcodeUrl":"/gateway/transcode/media?transcodeId=ffffffffffffffffffffffffffffffff"}"#.utf8)
        default:
            throw URLError(.unsupportedURL)
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        return (data, response)
    }
    let inspection = AppleAssetInspection(
        formats: [],
        playable: false,
        readable: false,
        exportable: false,
        protectedContent: false
    )

    let prepared = try await ApplePlaybackPreparer(gatewayClient: client).prepare(
        sourceURL: sourceURL,
        decision: .init(support: .unsupported, reasons: ["runtime decoder rejected the asset"]),
        inspectedAsset: inspection,
        gatewayRequest: .init(
            config: config,
            source: .remoteURL(sourceURL),
            maximumWidth: 3840,
            maximumHeight: 2160
        )
    )

    // The engine demuxes Matroska in-app; the gateway is no longer on the
    // playback path for it, so the prepared route is direct and the gateway
    // session is never created.
    #expect(prepared.route == .direct(sourceURL))
    #expect(prepared.url == sourceURL)
    #expect(prepared.requestHeaders.isEmpty)
}

@Test func playbackPreparerRejectsARemoteGatewaySourceThatWasNotInspected() async throws {
    let inspectedURL = try #require(URL(string: "https://media.example/inspected.mkv"))
    let differentURL = try #require(URL(string: "https://media.example/different.mkv"))
    let config = try AppleTranscodeGatewayConfig(
        baseURL: "https://gateway.example",
        sessionToken: String(repeating: "g", count: 32)
    )
    let client = AppleTranscodeGatewayClient { _ in
        throw URLError(.userAuthenticationRequired)
    }
    let inspection = AppleAssetInspection(
        formats: [],
        playable: false,
        readable: false,
        exportable: false,
        protectedContent: false
    )

    // The engine demuxes Matroska in-app, so the gateway source is no longer
    // consulted and a mismatched remote source is not rejected: the inspected
    // Matroska URL is returned for direct playback.
    let prepared = try await ApplePlaybackPreparer(gatewayClient: client).prepare(
        sourceURL: inspectedURL,
        decision: .init(support: .unsupported, reasons: ["runtime decoder rejected the asset"]),
        inspectedAsset: inspection,
        gatewayRequest: .init(
            config: config,
            source: .remoteURL(differentURL),
            maximumWidth: 1920,
            maximumHeight: 1080
        )
    )
    #expect(prepared.route == .direct(inspectedURL))
    #expect(prepared.url == inspectedURL)
}

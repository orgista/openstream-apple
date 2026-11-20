import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import OpenStreamApple

@Test func tmdbClientFindsAnIMDBTitleAndSelectsTheBestOfficialTrailer() async throws {
    let configuration = try AppleTMDBConfiguration(credential: "eyJheader.payload.signature")
    let client = AppleTMDBClient { request in
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "api.themoviedb.org")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer eyJheader.payload.signature")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "api_key" }) == false)

        let body: Data
        if request.url?.path == "/3/find/tt1234567" {
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(URLQueryItem(name: "external_source", value: "imdb_id")) == true)
            body = Data(#"{"movie_results":[{"id":42}],"tv_results":[]}"#.utf8)
        } else {
            #expect(request.url?.path == "/3/movie/42")
            body = Data(#"""
            {
              "runtime":121,
              "genres":[{"name":"Adventure"},{"name":"Drama"}],
              "tagline":"Keep looking up.",
              "overview":"A test movie.",
              "poster_path":"/poster.jpg",
              "backdrop_path":"/backdrop.jpg",
              "images":{"logos":[
                {"file_path":"/fallback.png","iso_639_1":null,"vote_average":9.5},
                {"file_path":"/official-wordmark.png","iso_639_1":"en","vote_average":8.0}
              ]},
              "credits":{
                "cast":[{"name":"First Actor"}],
                "crew":[{"name":"Test Director","job":"Director"}]
              },
              "videos":{"results":[
                {"key":"teaser_123","site":"YouTube","type":"Teaser","official":true,"iso_639_1":"en","iso_3166_1":"US"},
                {"key":"trailer_456","site":"YouTube","type":"Trailer","official":true,"iso_639_1":"en","iso_3166_1":"US"},
                {"key":"alt_789","site":"YouTube","type":"Teaser","official":false},
                {"key":"invalid key","site":"YouTube","type":"Trailer","official":true}
              ]}
            }
            """#.utf8)
        }
        return (
            body,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    let details = try await client.details(imdbID: "tt1234567", kind: .movie, configuration: configuration)

    #expect(details.runtimeMinutes == 121)
    #expect(details.genres == ["Adventure", "Drama"])
    #expect(details.cast == ["First Actor"])
    #expect(details.director == "Test Director")
    #expect(details.trailerYouTubeKey == "trailer_456")
    #expect(details.trailerYouTubeKeys == ["trailer_456", "teaser_123", "alt_789"])
    #expect(details.posterURL == URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg"))
    #expect(details.logoURL == URL(string: "https://image.tmdb.org/t/p/w500/official-wordmark.png"))
    #expect(AppleTrailerPreviewPolicy.watchURL(for: details.trailerYouTubeKey)?.host == "www.youtube.com")
    let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: details.trailerYouTubeKey))
    #expect(embed.host == "www.youtube-nocookie.com")
    #expect(URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(URLQueryItem(name: "autoplay", value: "1")) == true)
    #expect(URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(URLQueryItem(name: "mute", value: "1")) == true)
    #expect(URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "cc_load_policy" }) == false)
    #expect(URLComponents(url: embed, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(URLQueryItem(name: "enablejsapi", value: "1")) == true)
}

@Test func youtubePreviewWaitsForPlayerReadinessAndHandlesBlockedAutoplay() throws {
    let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: "trailer_456"))
    let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, startupChromeCanShow: false)

    #expect(html.contains("onYouTubeIframeAPIReady"))
    #expect(html.contains("'onReady'"))
    #expect(html.contains("'onAutoplayBlocked'"))
    #expect(html.contains("var desiredMuted = true"))
    #expect(html.contains("player.mute()"))
    #expect(html.contains("player.unMute()"))
    #expect(html.contains("player.setVolume(100)"))
    #expect(html.contains("setOption('captions', 'track', {})"))
    #expect(html.contains("player.unloadModule('captions')"))
    #expect(html.contains("'onApiChange'"))
    #expect(!html.contains("id=\"sound\""))
    #expect(!html.contains("id=\"captionGuard\""))
    #expect(html.contains("trailerState"))
    // Sized to the page, times the layout scale (1 on every host but the Mac hero).
    #expect(html.contains("var layoutScale = 1;"))
    #expect(html.contains("var width = Math.round(window.innerWidth * layoutScale), height = Math.round(window.innerHeight * layoutScale);"))
    #expect(html.contains("player.setSize(width, height)"))
    #expect(html.contains("body.ready iframe"))
    #expect(html.contains("revealAfterPlaybackStarts"))
    #expect(html.contains("var revealRule = ["))
    #expect(html.contains("if (!revealAllowed()) return;"))
    #expect(!html.contains("setTimeout(reveal, 3200)"))
    #expect(html.contains("revealWatchdogTimer"))
    #expect(html.contains("hasSeenPlaying"))
    #expect(html.contains("}, 12000);"))
    #expect(html.contains("if (!hasRevealed) finishPreview();"))
    #expect(!html.contains("revealAfterChromeSettles"))
    #expect(html.contains("document.body.classList.add('ready')"))
    #expect(!html.contains("pointer-events:none"))
    #expect(html.contains("window.setTrailerMuted = function(isMuted)"))
    #expect(html.contains("notifyNative(desiredMuted ? 'muted' : 'unmuted', desiredMuted)"))
    #expect(html.contains("window.setTrailerPlaying = function(isPlaying)"))
    #expect(html.contains("window.restartTrailer = function()"))
    #expect(html.contains("player.seekTo(0, true)"))
    #expect(html.contains("notifyNative('ended')"))
    #expect(html.contains("previewCapSeconds = 60"))
    #expect(html.contains("previewHideLeadSeconds = 0.8"))
    #expect(html.contains("function finishPreview()"))
    #expect(html.contains("setTimeout(finishPreview, (previewCapSeconds - previewHideLeadSeconds) * 1000)"))
    #expect(html.contains("function clearPreviewCapTimers()"))
    #expect(html.contains("setTimeout(hidePlayer, 650)"))
    #expect(html.contains("showinfo: 0") == false)
    #expect(html.contains("fs: 0"))
    #expect(!html.contains("window.setTrailerMuted(!desiredMuted)"))
    #expect(!html.contains("&mute="))
    #expect(html.contains("&amp;mute="))
    #expect(!html.contains("TrailerDiagnostics"))
}

@Test func trailerPreviewCropKeepsYouTubeChromeOutsideTheHero() {
    let window = AppleTrailerPreviewLayout.visiblePlayerWindow

    #expect(window.lowerBound >= 0.18)
    #expect(window.lowerBound <= 0.20)
    #expect(window.upperBound >= 0.92)
    #expect(window.upperBound <= 0.94)
}

@Test func detailHeroUsesOwnerLogoAndTrailerGeometry() {
    #expect(AppleDetailMetrics.phoneAspectRatio == 4.0 / 3.0 as CGFloat)
    #expect(AppleDetailMetrics.iPadHeightFraction == 0.60)
    #expect(AppleDetailMetrics.landscapeHeightFraction == 1.0)
    #expect(AppleDetailMetrics.titleLogoWidthFraction == 0.70)
    #expect(AppleDetailMetrics.landscapeTitleLogoWidthFraction == 0.40)
    #expect(AppleDetailMetrics.titleLogoMaxHeight == 96)
    #expect(AppleDetailMetrics.titleLogoIntrusion >= 12)
    #expect(AppleDetailMetrics.titleLogoIntrusion <= 16)
    #expect(AppleDetailMetrics.titleLogoBottomBuffer >= 24)
    #expect(AppleDetailMetrics.bottomGradientHeight <= 24)
    #expect(AppleDetailMetrics.landscapeOverlayLeadingMargin == 40)
    #expect(AppleDetailMetrics.landscapeOverlayBottomMargin == 28)
    #expect(AppleDetailMetrics.wideEpisodeThreshold == 1_000)
}

@Test func titleLogoValidatorRequiresDecodedTransparentPNGEdges() throws {
    let transparent = try makeLogoPNG(edgeAlpha: 0)
    let antiAliased = try makeLogoPNG(edgeAlpha: 180)
    let opaque = try makeLogoPNG(edgeAlpha: 255)

    #expect(AppleTransparentPNGLogoValidator.hasTransparentEdges(in: transparent))
    #expect(AppleTransparentPNGLogoValidator.hasTransparentEdges(in: antiAliased))
    #expect(!AppleTransparentPNGLogoValidator.hasTransparentEdges(in: opaque))
    #expect(!AppleTransparentPNGLogoValidator.hasTransparentEdges(in: Data("jpeg".utf8)))
}

/// TMDB crops wordmarks tight: letters reach the top and bottom edge,
/// including at the centre. That is still a mark; a plate is not.
@Test func titleLogoValidatorAcceptsTightCropsAndRefusesPlates() throws {
    // Three opaque letters spanning the full height, gaps between them.
    let tightMark = try makePNG(width: 60, height: 20) { context in
        for x in [0, 26, 52] { context.fill(CGRect(x: x, y: 0, width: 8, height: 20)) }
    }
    // A card with rounded corners: only the corner pixels are clear.
    let roundedPlate = try makePNG(width: 60, height: 20) { context in
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 60, height: 20),
                               cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
    }
    #expect(AppleTransparentPNGLogoValidator.hasTransparentEdges(in: tightMark))
    #expect(!AppleTransparentPNGLogoValidator.hasTransparentEdges(in: roundedPlate))
}

private func makePNG(width: Int, height: Int, draw: (CGContext) -> Void) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    draw(context)
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeLogoPNG(edgeAlpha: UInt8) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: 12,
        height: 12,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat(edgeAlpha) / 255))
    context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        "public.png" as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func trailerSoundBridgeTransitionsAndIssuesExplicitPlayerCommands() {
    var isMuted = true
    #expect(AppleTrailerSoundBridge.accessibilityLabel(isMuted: isMuted) == "Turn trailer sound on")
    #expect(AppleTrailerSoundBridge.accessibilityValue(isMuted: isMuted) == "Muted")

    isMuted = AppleTrailerSoundBridge.toggledState(from: isMuted)
    #expect(!isMuted)
    #expect(AppleTrailerSoundBridge.javascriptCommand(isMuted: isMuted) == "window.setTrailerMuted(false);")
    #expect(AppleTrailerSoundBridge.accessibilityLabel(isMuted: isMuted) == "Mute trailer")
    #expect(AppleTrailerSoundBridge.accessibilityValue(isMuted: isMuted) == "Sound on")

    isMuted = AppleTrailerSoundBridge.toggledState(from: isMuted)
    #expect(isMuted)
    #expect(AppleTrailerSoundBridge.javascriptCommand(isMuted: isMuted) == "window.setTrailerMuted(true);")
    #expect(AppleTrailerSoundBridge.accessibilityLabel(isMuted: isMuted) == "Turn trailer sound on")
    #expect(AppleTrailerSoundBridge.accessibilityValue(isMuted: isMuted) == "Muted")
}

@Test func trailerAutoplayHonorsSystemAccessibilityPreferences() {
    #expect(AppleTrailerPreviewPolicy.shouldAutoplay(
        reduceMotion: false,
        systemVideoAutoplayEnabled: true
    ))
    #expect(!AppleTrailerPreviewPolicy.shouldAutoplay(
        reduceMotion: true,
        systemVideoAutoplayEnabled: true
    ))
    #expect(!AppleTrailerPreviewPolicy.shouldAutoplay(
        reduceMotion: false,
        systemVideoAutoplayEnabled: false
    ))
}

@Test(arguments: [AppleTrailerPreviewPolicy.TitlePageDevice.phoneOrPad, .vision, .mac])
func titlePageTrailerAutoplaysWithTheSettingOnAndReduceMotionOff(device: AppleTrailerPreviewPolicy.TitlePageDevice) {
    #expect(AppleTrailerPreviewPolicy.titlePageAutoplays(on: device, setting: true, reduceMotion: false))
    #expect(!AppleTrailerPreviewPolicy.titlePageAutoplays(on: device, setting: false, reduceMotion: false))
    #expect(!AppleTrailerPreviewPolicy.titlePageAutoplays(on: device, setting: true, reduceMotion: true))
}

@Test func macTitlePageTrailerAutoplaysLikeItsDiscoverHero() {
    // N69 (owner 2026-09-25): the Mac title page no longer waits for a press.
    #expect(AppleTrailerPreviewPolicy.titlePageAutoplays(on: .mac, setting: true, reduceMotion: false))
}

@Test func allTitlePagesFollowSystemVideoAutoplay() {
    #expect(!AppleTrailerPreviewPolicy.titlePageAutoplays(
        on: .phoneOrPad, setting: true, reduceMotion: false, systemVideoAutoplayEnabled: false))
    #expect(!AppleTrailerPreviewPolicy.titlePageAutoplays(
        on: .mac, setting: true, reduceMotion: false, systemVideoAutoplayEnabled: false))
}

@Test func appleTVTitlePageNeverAutoplaysATrailer() {
    #expect(!AppleTrailerPreviewPolicy.titlePageAutoplays(on: .tv, setting: true, reduceMotion: false))
}

@Test func trailerFrameProbeURLUsesYtimgFrame0() {
    #expect(AppleTrailerPreviewPolicy.frameProbeURL(for: "abc123")?.absoluteString
        == "https://i.ytimg.com/vi/abc123/frame0.jpg")
    #expect(AppleTrailerPreviewPolicy.frameProbeURL(for: "contains a space") == nil)
    #expect(AppleTrailerPreviewPolicy.frameProbeURL(for: nil) == nil)
}

@Test func trailerPortraitFrameDetectionComparesWidthAndHeight() {
    #expect(AppleTrailerPreviewPolicy.isPortraitFrame(CGSize(width: 270, height: 480)))
    #expect(!AppleTrailerPreviewPolicy.isPortraitFrame(CGSize(width: 480, height: 268)))
    #expect(!AppleTrailerPreviewPolicy.isPortraitFrame(.zero))
}

@Test func trailerFirstPlayableCandidateSkipsPortraitKeys() {
    let keys = ["ob4SHtT6cC0", "NO9hXSD5K4A", "FdV-Cs5o8mc"]
    #expect(AppleTrailerPreviewPolicy.firstPlayableCandidate(
        keys, portraitKeys: ["ob4SHtT6cC0"], startingAt: 0
    ) == 1)
    #expect(AppleTrailerPreviewPolicy.firstPlayableCandidate(
        keys, portraitKeys: ["ob4SHtT6cC0", "NO9hXSD5K4A"], startingAt: 0
    ) == 2)
    #expect(AppleTrailerPreviewPolicy.firstPlayableCandidate(
        keys, portraitKeys: Set(keys), startingAt: 0
    ) == nil)
    #expect(AppleTrailerPreviewPolicy.firstPlayableCandidate(
        keys, portraitKeys: [], startingAt: keys.count
    ) == nil)
}

@Test func detailSynopsisFallsBackWhenCatalogTextIsEmpty() {
    #expect(AppleMetadataPresentationPolicy.synopsis(
        catalog: "  ",
        enriched: "  A richer overview from metadata.  "
    ) == "A richer overview from metadata.")
    #expect(AppleMetadataPresentationPolicy.synopsis(
        catalog: "Catalog synopsis",
        enriched: "Enriched synopsis"
    ) == "Catalog synopsis")
    #expect(AppleMetadataPresentationPolicy.synopsis(catalog: nil, enriched: "\n") == nil)
}

@Test func tmdbClientKeepsV3CredentialsInTheQueryAndRejectsInvalidIdentifiers() async throws {
    let key = String(repeating: "a", count: 32)
    let configuration = try AppleTMDBConfiguration(credential: key)
    let client = AppleTMDBClient { request in
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "api_key", value: key)))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (
            Data(#"{"movie_results":[],"tv_results":[]}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    await #expect(throws: AppleTMDBError.titleNotFound) {
        try await client.details(imdbID: "tt7654321", kind: .movie, configuration: configuration)
    }
    await #expect(throws: AppleTMDBError.invalidIdentifier) {
        try await client.details(imdbID: "not-imdb", kind: .movie, configuration: configuration)
    }
    #expect(AppleTrailerPreviewPolicy.validYouTubeKey("contains a space") == nil)
}

@Test func tmdbClientReadsCreditsCountriesAndLanguagesForTheTitlePage() async throws {
    let configuration = try AppleTMDBConfiguration(credential: "eyJheader.payload.signature")
    let client = AppleTMDBClient { request in
        let body: Data
        if request.url?.path == "/3/find/tt0903747" {
            body = Data(#"{"movie_results":[],"tv_results":[{"id":1396}]}"#.utf8)
        } else {
            #expect(request.url?.path == "/3/tv/1396")
            body = Data(#"""
            {
              "genres":[{"name":"Drama"}],
              "origin_country":["US"],
              "original_language":"en",
              "spoken_languages":[{"iso_639_1":"en","english_name":"English"},{"iso_639_1":"es","english_name":"Spanish"}],
              "created_by":[{"name":"Vince Gilligan","profile_path":"/vince.jpg"}],
              "credits":{
                "cast":[{"name":"Bryan Cranston","character":"Walter White","profile_path":"/bryan.jpg"},
                        {"name":"Aaron Paul","character":"Jesse Pinkman"}],
                "crew":[]
              }
            }
            """#.utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    let details = try await client.details(imdbID: "tt0903747", kind: .series, configuration: configuration)

    #expect(details.cast == ["Bryan Cranston", "Aaron Paul"])
    #expect(details.castMembers == [
        AppleCreditPerson(name: "Bryan Cranston", role: "Walter White",
                          portraitURL: URL(string: "https://image.tmdb.org/t/p/h632/bryan.jpg")),
        AppleCreditPerson(name: "Aaron Paul", role: "Jesse Pinkman"),
        AppleCreditPerson(name: "Vince Gilligan", role: "Creator",
                          portraitURL: URL(string: "https://image.tmdb.org/t/p/h632/vince.jpg")),
    ])
    #expect(details.countries == [AppleTitlePagePolicy.regionName("US")])
    #expect(details.originalLanguage == AppleTitlePagePolicy.languageName("en"))
    #expect(details.spokenLanguages == ["en", "es"].compactMap { AppleTitlePagePolicy.languageName($0) })
}

@Test func tmdbLibraryTitlesKeepTheirGenres() async throws {
    let configuration = try AppleTMDBConfiguration(credential: "eyJheader.payload.signature")
    let client = AppleTMDBClient { request in
        #expect(request.url?.path == "/3/movie/42")
        let body = Data(#"{"id":42,"title":"Fixture Film","release_date":"2024-01-01","genres":[{"name":"Drama"},{"name":"Adventure"}]}"#.utf8)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
    let item = try await client.sharedLinkDetails(id: 42, kind: .movie, configuration: configuration)
    #expect(item.genres == ["Drama", "Adventure"])
}

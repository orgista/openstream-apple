import Foundation
import Testing
@testable import OpenStreamApple

/// Finding CEA-608 captions a provider never declared, and declaring them so
/// AVFoundation can see them. Detection only — nothing here decodes a caption.
@Suite("Embedded caption detection")
struct AppleCEA608DetectorTests {
    /// One ATSC A/53 caption SEI payload's identifying bytes, with a little
    /// plausible video either side.
    private func captionSEI(_ filler: Int = 24) -> [UInt8] {
        [0x00, 0x00, 0x01, 0x06, 0x04, 0x2E]
            + AppleCEA608Detector.atscUserIdentifier
            + [UInt8](repeating: 0x33, count: filler)
    }

    private func elementaryStream(captionFrames: Int, noise: Int = 400) -> Data {
        var bytes = [UInt8](repeating: 0x5A, count: noise)
        for _ in 0 ..< captionFrames {
            bytes += captionSEI()
            bytes += [UInt8](repeating: 0x5A, count: 120)
        }
        return Data(bytes)
    }

    // MARK: - Detection

    @Test func aStreamCarryingCaptionsIsFound() {
        #expect(AppleCEA608Detector.carriesCEA608(in: elementaryStream(captionFrames: 30)))
    }

    /// A channel with no captions must come back clean, or every channel would
    /// be declared and the caption menu would offer a track with nothing in it.
    @Test func aStreamWithoutCaptionsIsNotFound() {
        var bytes = [UInt8]()
        for index in 0 ..< 4_000 { bytes.append(UInt8(index % 251)) }
        #expect(!AppleCEA608Detector.carriesCEA608(in: Data(bytes)))
    }

    /// The signature is seven bytes. A single chance occurrence is not a
    /// caption track, and the threshold is what says so.
    @Test func oneChanceOccurrenceIsNotEnough() {
        #expect(!AppleCEA608Detector.carriesCEA608(in: elementaryStream(captionFrames: 1)))
        #expect(AppleCEA608Detector.carriesCEA608(in: elementaryStream(captionFrames: 3)))
    }

    @Test func occurrencesAreCounted() {
        let data = elementaryStream(captionFrames: 7)
        #expect(AppleCEA608Detector.occurrences(of: AppleCEA608Detector.atscUserIdentifier, in: data) == 7)
    }

    @Test func anEmptyStreamIsNotFound() {
        #expect(!AppleCEA608Detector.carriesCEA608(in: Data()))
        #expect(AppleCEA608Detector.occurrences(of: AppleCEA608Detector.atscUserIdentifier, in: Data()) == 0)
    }

    // MARK: - Transport stream unwrapping

    /// The signature is seven bytes and a transport packet header lands every
    /// 188; unwrapped, a signature split across a header is still found.
    @Test func transportPacketHeadersAreStrippedBeforeScanning() {
        let payload = [UInt8](elementaryStream(captionFrames: 20))
        var ts = [UInt8]()
        var index = 0
        while index < payload.count {
            let slice = Array(payload[index ..< min(index + 184, payload.count)])
            index += 184
            ts += [0x47, 0x01, 0x00, 0x10] + slice
            ts += [UInt8](repeating: 0xFF, count: 184 - slice.count)
        }
        let data = Data(ts)
        #expect(AppleCEA608Detector.elementaryStream(from: data) != nil)
        #expect(AppleCEA608Detector.carriesCEA608(in: data))
    }

    @Test func nonTransportDataIsScannedAsItArrived() {
        let raw = elementaryStream(captionFrames: 10)
        #expect(AppleCEA608Detector.elementaryStream(from: raw) == nil)
        #expect(AppleCEA608Detector.carriesCEA608(in: raw))
    }

    /// A packet whose adaptation-field control says "no payload" contributes
    /// nothing, and one with an adaptation field starts later than byte four.
    @Test func adaptationFieldsAreSkipped() {
        var packet = [UInt8](repeating: 0x00, count: 188)
        packet[0] = 0x47
        packet[3] = 0x30           // adaptation field followed by payload
        packet[4] = 10             // adaptation field length
        for (offset, byte) in AppleCEA608Detector.atscUserIdentifier.enumerated() {
            packet[15 + offset] = byte
        }
        var empty = [UInt8](repeating: 0xFF, count: 188)
        empty[0] = 0x47
        empty[3] = 0x20            // adaptation field only, no payload
        let unwrapped = AppleCEA608Detector.elementaryStream(from: Data(packet + empty + packet + packet))
        let found = AppleCEA608Detector.occurrences(
            of: AppleCEA608Detector.atscUserIdentifier, in: try! #require(unwrapped))
        #expect(found == 3)
    }
}

@Suite("HLS caption declaration")
struct AppleHLSCaptionDeclarationTests {
    private let master = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
    variant.m3u8
    """

    private let media = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-MEDIA-SEQUENCE:1200
    #EXTINF:6.0,
    segment-1200.ts
    #EXTINF:6.0,
    segment-1201.ts
    """

    @Test func aMasterIsToldApartFromAMediaPlaylist() {
        #expect(AppleHLSCaptionDeclaration.isMasterPlaylist(master))
        #expect(!AppleHLSCaptionDeclaration.isMasterPlaylist(media))
    }

    @Test func aMasterGainsTheDeclarationAndTheAttribute() {
        let patched = AppleHLSCaptionDeclaration.declaring(master)
        #expect(patched.contains("#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS"))
        #expect(patched.contains("INSTREAM-ID=\"CC1\""))
        #expect(patched.contains("#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CLOSED-CAPTIONS=\"\(AppleHLSCaptionDeclaration.groupID)\""))
        #expect(patched.contains("variant.m3u8"))
    }

    /// A provider that already declared captions — or said there are none with
    /// `CLOSED-CAPTIONS=NONE` — is left exactly as it arrived.
    @Test func aManifestThatAlreadySpokeIsUntouched() {
        let declared = master.replacingOccurrences(
            of: "RESOLUTION=1920x1080", with: "RESOLUTION=1920x1080,CLOSED-CAPTIONS=NONE")
        #expect(AppleHLSCaptionDeclaration.declaring(declared) == declared)
        #expect(AppleHLSCaptionDeclaration.declaresClosedCaptions(declared))
    }

    /// A media playlist has nowhere to put the declaration, so it comes back
    /// byte for byte — the wrapper master is the route for those.
    @Test func aMediaPlaylistIsNeverRewritten() {
        #expect(AppleHLSCaptionDeclaration.declaring(media) == media)
    }

    @Test func aMediaPlaylistCanBeWrappedInADeclaringMaster() {
        let wrapper = AppleHLSCaptionDeclaration.master(wrapping: "live.m3u8")
        #expect(wrapper.hasPrefix("#EXTM3U"))
        #expect(wrapper.contains("INSTREAM-ID=\"CC1\""))
        #expect(wrapper.contains("CLOSED-CAPTIONS=\"\(AppleHLSCaptionDeclaration.groupID)\""))
        #expect(wrapper.hasSuffix("live.m3u8"))
        #expect(AppleHLSCaptionDeclaration.isMasterPlaylist(wrapper))
    }

    @Test func theFirstSegmentIsWhatTheProbeFetches() {
        #expect(AppleHLSCaptionDeclaration.firstSegmentURI(in: media) == "segment-1200.ts")
        #expect(AppleHLSCaptionDeclaration.firstSegmentURI(in: "#EXTM3U\n#EXT-X-ENDLIST") == nil)
    }
}

/// When a live channel plays through the proxy's caption-declaring master.
@Suite("Live caption master wrap")
struct AppleLiveCaptionWrapTests {
    /// Probe × manifest × shape: only undeclared 608 in a media playlist wraps.
    @Test(arguments: [
        (true, false, true, true),
        (true, true, true, false),
        (false, false, true, false),
        (false, true, true, false),
        (true, false, false, false),
    ])
    func wrapsOnlyUndeclaredCaptionsInAMediaPlaylist(
        carries: Bool, declares: Bool, isMediaPlaylist: Bool, wraps: Bool
    ) {
        #expect(AppleLiveCaptionWrapPolicy.shouldWrap(
            carriesEmbeddedCaptions: carries, manifestDeclaresCaptions: declares,
            isMediaPlaylist: isMediaPlaylist) == wraps)
    }

    @Test func aProbeResultWrapsOnlyForAnUndeclaredMediaPlaylist() {
        typealias Result = AppleLiveCaptionProbe.Result
        #expect(Result(carriesUndeclaredCaptions: true, manifestAlreadyDeclares: false,
                       isMediaPlaylist: true).wrapsInCaptionMaster)
        // A raw transport stream carrying 608 is the engine's to decode.
        #expect(!Result(carriesUndeclaredCaptions: true, manifestAlreadyDeclares: false,
                        isMediaPlaylist: false).wrapsInCaptionMaster)
        #expect(!Result(carriesUndeclaredCaptions: false, manifestAlreadyDeclares: true,
                        isMediaPlaylist: true).wrapsInCaptionMaster)
    }

    @Test func theSynthesizedMasterIsExactly() {
        let expected = [
            "#EXTM3U",
            "#EXT-X-VERSION:4",
            "#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"openstream-cc\",NAME=\"CC1\","
                + "LANGUAGE=\"en\",INSTREAM-ID=\"CC1\",DEFAULT=NO,AUTOSELECT=YES",
            "#EXT-X-STREAM-INF:BANDWIDTH=2000000,CLOSED-CAPTIONS=\"openstream-cc\"",
            "stream.m3u8",
        ].joined(separator: "\n")
        #expect(AppleHLSCaptionDeclaration.master(
            wrapping: AppleProtectedHTTPPlaybackServer.captionVariantPath) == expected)
    }

    private func channel(_ path: String) -> AppleIPTVChannel {
        AppleIPTVChannel(id: path, sourceID: UUID(), name: "Fixture",
                         streamURL: URL(string: "https://fixture.example/\(path)")!, userAgent: "FixtureAgent")
    }

    @Test func aStampedHLSChannelAsksForTheMasterAndKeepsItsHeaders() {
        let request = channel("live.m3u8").withCaptionMaster(true).playbackRequest()
        #expect(request.hints.declaresEmbeddedCaptions)
        #expect(request.hints.nativeRemoteHLS)
        #expect(request.url == URL(string: "https://fixture.example/live.m3u8"))
        #expect(request.effectiveHeaders == ["User-Agent": "FixtureAgent"])
    }

    @Test func firstHLSPlayIsEligibleUnlessAProbeAlreadyRuledOutCaptions() {
        #expect(channel("live.m3u8").playbackRequest().hints.declaresEmbeddedCaptions)
        #expect(!channel("live.m3u8").withCaptionMaster(false).playbackRequest().hints.declaresEmbeddedCaptions)
        #expect(!channel("live.ts").withCaptionMaster(true).playbackRequest().hints.declaresEmbeddedCaptions)
    }

    @Test func noProbeAnswerPreservesTheUnknownState() {
        #expect(AppleLiveCaptionProbe().wrapsInCaptionMaster(channelID: "never-probed") == nil)
    }
}

/// Which shape the channel picker takes, and what one channel row says.
@Suite("Live channel picker")
struct AppleLiveChannelPickerTests {
    private func channel(_ id: String, _ name: String) -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: UUID(), name: name, group: "All",
                         logoURL: nil, streamURL: URL(string: "https://fixture.example/\(id).m3u8")!)
    }

    private func programme(_ channelID: String, _ title: String) -> AppleIPTVProgramme {
        AppleIPTVProgramme(id: "\(channelID):1", channelID: channelID, title: title, subtitle: nil,
                           description: nil, start: Date(timeIntervalSince1970: 0),
                           end: Date(timeIntervalSince1970: 3_600), category: nil, isLive: true)
    }

    /// The iPad browses in a strip along the bottom; the phone and the Apple TV
    /// keep the leading panel.
    @Test func onlyTheIPadGetsTheStrip() {
        #expect(AppleLiveChannelPickerPresentation.choose(isPad: true) == .bottomStrip)
        #expect(AppleLiveChannelPickerPresentation.choose(isPad: false) == .panel)
    }

    /// The programme line comes from the guide the Live tab already loaded.
    @Test func eachRowCarriesWhatIsOnNow() {
        let guide = AppleIPTVGuide(programmes: [programme("cbs", "CBS Evening News")])
        let entries = AppleLiveChannelPickerEntry.entries(
            channels: [channel("cbs", "CBS (EAST)"), channel("fox", "FOX (EAST)")],
            guide: guide, currentChannelID: "cbs", at: Date(timeIntervalSince1970: 600))
        #expect(entries.map(\.nowTitle) == ["CBS Evening News", nil])
        #expect(entries.map(\.isCurrent) == [true, false])
    }

    /// The row is one accessibility element, so everything it shows has to be
    /// in the label or VoiceOver never reads it.
    @Test func theLabelCarriesTheBadgeAndTheProgramme() {
        let guide = AppleIPTVGuide(programmes: [programme("cbs", "CBS Evening News")])
        let entries = AppleLiveChannelPickerEntry.entries(
            channels: [channel("cbs", "CBS (EAST)")], guide: guide,
            currentChannelID: "cbs", at: Date(timeIntervalSince1970: 600))
        #expect(entries[0].accessibilityLabel == "CBS (EAST), Now playing, CBS Evening News")
    }

    @Test func aChannelWithNoGuideDataReadsAsItsNameAlone() {
        let entries = AppleLiveChannelPickerEntry.entries(
            channels: [channel("fox", "FOX (EAST)")], guide: AppleIPTVGuide(programmes: []),
            currentChannelID: nil)
        #expect(entries[0].nowTitle == nil)
        #expect(entries[0].accessibilityLabel == "FOX (EAST)")
    }
}

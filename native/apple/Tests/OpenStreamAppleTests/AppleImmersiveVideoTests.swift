import CoreMedia
import CoreImage
import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleImmersiveVideoDetectorTests {
    private let half = kCMFormatDescriptionProjectionKind_HalfEquirectangular as String
    private let full = kCMFormatDescriptionProjectionKind_Equirectangular as String
    private let sideBySide = kCMFormatDescriptionViewPackingKind_SideBySide as String
    private let overUnder = kCMFormatDescriptionViewPackingKind_OverUnder as String

    // MARK: Metadata

    @Test func halfEquirectangularSideBySideIsStereo180() throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(projectionKind: half, viewPackingKind: sideBySide))
        #expect(layout == AppleImmersiveVideoLayout(projection: .halfSphere, packing: .sideBySide, isFromMetadata: true))
        #expect(layout.projectionKind == .stereo180)
    }

    @Test func halfEquirectangularOverUnderIsStereo180() throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(projectionKind: half, viewPackingKind: overUnder))
        #expect(layout.packing == .overUnder)
        #expect(layout.projectionKind == .stereo180)
    }

    /// The owner's Insta360 exports: sv3d equirectangular, st3d mono.
    @Test func equirectangularWithoutPackingIsMono360() throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(projectionKind: full, viewPackingKind: nil))
        #expect(layout.packing == .mono)
        #expect(layout.projectionKind == .mono360)
    }

    @Test(arguments: [nil, kCMFormatDescriptionProjectionKind_Rectilinear as String, "Unknown"])
    func otherProjectionsAreNotVR(kind: String?) {
        #expect(AppleImmersiveVideoDetector.layout(projectionKind: kind, viewPackingKind: sideBySide) == nil)
    }

    // MARK: File names

    @Test(arguments: [
        ("Trip_180_LR.mp4", AppleImmersiveProjection.halfSphere, AppleImmersiveViewPacking.sideBySide),
        ("Trip VR180 SBS.mov", .halfSphere, .sideBySide),
        ("concert_180x180_3dh.mp4", .halfSphere, .sideBySide),
        ("synthetic_180_TB.mp4", .halfSphere, .overUnder),
        ("beach-180-3dv.mp4", .halfSphere, .overUnder),
        ("drone_180_mono.mp4", .halfSphere, .mono),
        ("tour_360_TB.mp4", .fullSphere, .overUnder),
        ("tour.vr360.mp4", .fullSphere, .mono),
    ])
    func nameGivesTheLayout(name: String, projection: AppleImmersiveProjection, packing: AppleImmersiveViewPacking) throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(filename: name, videoSize: nil))
        #expect(layout.projection == projection)
        #expect(layout.packing == packing)
        #expect(!layout.eyesSwapped)
        #expect(!layout.isFromMetadata)
    }

    @Test(arguments: ["Avatar.2009.3D.HSBS.mkv", "Movie_SBS.mp4", "Show S01E180.mp4",
                      "Holiday 2018.mp4", "1080p.mp4", "trip_LR.mp4", "Xbox 360 review.mp4",
                      "Top 180.mp4", "Holiday_180.mp4", "Trip_180_review_LR.mp4"])
    func namesWithoutAProjectionAreNotVR(name: String) {
        #expect(AppleImmersiveVideoDetector.layout(filename: name, videoSize: CGSize(width: 3840, height: 1920)) == nil)
    }

    @Test func rightEyeFirstNamesAreFlagged() throws {
        let rl = try #require(AppleImmersiveVideoDetector.layout(filename: "clip_180_RL.mp4", videoSize: nil))
        #expect(rl.packing == .sideBySide && rl.eyesSwapped)
        let bt = try #require(AppleImmersiveVideoDetector.layout(filename: "clip_180_BT.mp4", videoSize: nil))
        #expect(bt.packing == .overUnder && bt.eyesSwapped)
    }

    @Test(arguments: [AppleImmersiveViewPacking.sideBySide, .overUnder])
    func rightEyeFirstSelectsTheOppositeHalf(packing: AppleImmersiveViewPacking) {
        let size = CGSize(width: 800, height: 400)
        let normal = AppleImmersiveVideoLayout(projection: .halfSphere, packing: packing, isFromMetadata: false)
        var reversed = normal
        reversed.eyesSwapped = true
        #expect(normal.eyeRect(left: true, size: size) == reversed.eyeRect(left: false, size: size))
        #expect(normal.eyeRect(left: false, size: size) == reversed.eyeRect(left: true, size: size))
        #expect(normal.eyeRect(left: true, size: size) != normal.eyeRect(left: false, size: size))
        #expect(normal.eyeRect(left: true, size: size).origin == CGPoint(x: 0, y: packing == .overUnder ? 200 : 0))
    }

    @Test(arguments: [AppleImmersiveViewPacking.sideBySide, .overUnder])
    func swappedEyeRenderingPutsTheOriginalRightEyeInTheLeftOutput(packing: AppleImmersiveViewPacking) {
        let size = CGSize(width: 8, height: 8)
        let normal = AppleImmersiveVideoLayout(projection: .halfSphere, packing: packing, isFromMetadata: false)
        var swapped = normal
        swapped.eyesSwapped = true
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: normal.eyeRect(left: true, size: size))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: normal.eyeRect(left: false, size: size))
        let frame = red.composited(over: blue)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(swapped.eyeImage(left: true, image: frame), toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        #expect(pixel == [0, 0, 255, 255])
        context.render(swapped.eyeImage(left: false, image: frame), toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        #expect(pixel == [255, 0, 0, 255])
    }

    /// No packing word: the frame's shape decides.
    @Test(arguments: [
        (AppleImmersiveProjection.halfSphere, CGSize(width: 5760, height: 2880), AppleImmersiveViewPacking.sideBySide),
        (.halfSphere, CGSize(width: 2880, height: 2880), .mono),
        (.halfSphere, CGSize(width: 1920, height: 3840), .overUnder),
        (.fullSphere, CGSize(width: 5760, height: 2880), .mono),
        (.fullSphere, CGSize(width: 3840, height: 3840), .overUnder),
        (.fullSphere, CGSize(width: 7680, height: 1920), .sideBySide),
        (.halfSphere, CGSize(width: 1920, height: 1080), .sideBySide),
        (.fullSphere, CGSize.zero, .mono),
    ])
    func aspectPicksThePacking(projection: AppleImmersiveProjection, size: CGSize, packing: AppleImmersiveViewPacking) {
        #expect(AppleImmersiveVideoDetector.packing(projection: projection, videoSize: size) == packing)
    }

    @Test func nameWithoutPackingUsesTheFrame() throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(filename: "VR180 hike.mp4",
                                                                     videoSize: CGSize(width: 1920, height: 3840)))
        #expect(layout.packing == .overUnder)
    }

    // MARK: Candidates

    private func request(_ raw: String, filename: String? = nil, isLive: Bool = false,
                         headers: [String: String] = [:]) throws -> ApplePlaybackRequest {
        ApplePlaybackRequest(url: try #require(URL(string: raw)), headers: headers, isLive: isLive,
                             mediaID: "vr", sourceKind: .files, hints: ApplePlaybackRequest.Hints(filename: filename))
    }

    @Test func localAndShareMP4FilesAreCandidates() throws {
        #expect(AppleImmersiveVideoDetector.isCandidate(try request("file:///videos/trip_180_LR.mp4")))
        #expect(AppleImmersiveVideoDetector.isCandidate(try request("http://127.0.0.1:8080/s/1", filename: "Kansas.mp4")))
        #expect(AppleImmersiveVideoDetector.isCandidate(try request("file:///videos/clip.MOV")))
    }

    @Test func otherStreamsAreNotCandidates() throws {
        #expect(!AppleImmersiveVideoDetector.isCandidate(try request("file:///videos/trip_180_LR.mkv")))
        #expect(!AppleImmersiveVideoDetector.isCandidate(try request("https://fixture.example/live.m3u8", isLive: true)))
        #expect(!AppleImmersiveVideoDetector.isCandidate(try request("https://fixture.example/a.mp4", headers: ["X-Token": "t"])))
        #expect(!AppleImmersiveVideoDetector.isCandidate(try request("smb://nas/share/trip_180.mp4")))
        var disc = try request("file:///videos/movie.mp4")
        disc.hints.disc = AppleDiscPlaybackChoice(start: .mainTitle, format: .bluRay)
        #expect(!AppleImmersiveVideoDetector.isCandidate(disc))
    }
}

@MainActor
@Suite struct ApplePlaybackCoordinatorEngineAdoptionTests {
    @Test func adoptsStopsAndObservesTheReplacement() async throws {
        let original = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: original)
        coordinator.retriesFailedEngineOpen = true
        let replacement = FakePlaybackEngine()
        replacement.script([.playing])
        coordinator.adoptEngine(replacement)
        #expect(coordinator.engine === replacement)
        #expect(original.stopCount == 1)
        #expect(!coordinator.retriesFailedEngineOpen)
        let request = ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/video.mp4")),
                                           mediaID: "adoption", sourceKind: .files)
        await coordinator.begin(request)
        #expect(replacement.loadedRequests == [request])
        #expect(coordinator.phase == .playing)
        #expect(coordinator.route == .avPlayer)
        replacement.emit(.phase(.paused))
        for _ in 0..<100 where coordinator.phase != .paused { await Task.yield() }
        #expect(coordinator.phase == .paused)
        original.emit(.phase(.ended))
        await Task.yield()
        #expect(coordinator.phase == .paused)
        let refused = FakePlaybackEngine()
        coordinator.adoptEngine(refused)
        #expect(coordinator.engine === replacement)
        replacement.emit(.phase(.ended))
        for _ in 0..<100 where coordinator.phase != .ended { await Task.yield() }
        #expect(coordinator.phase == .ended)
        coordinator.stop()
    }

    @Test func loadingWithoutARouteStillRefusesAdoption() async throws {
        let engine = FakePlaybackEngine()
        engine.scriptedRoute = .none
        engine.script([.loading])
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        await coordinator.begin(ApplePlaybackRequest(url: try #require(URL(string: "https://fixture.example/video.mp4")),
            mediaID: "pending-adoption", sourceKind: .files))
        #expect(coordinator.phase == .loading && coordinator.route == .none)
        coordinator.adoptEngine(FakePlaybackEngine())
        #expect(coordinator.engine === engine)
        coordinator.stop()
    }
}

@Suite struct AppleImmersiveVideoEntryPolicyTests {
    @Test(arguments: [false, true])
    func metadataAutomaticallyEnters(probeRequested: Bool) {
        let layout = AppleImmersiveVideoLayout(projection: .halfSphere, packing: .sideBySide, isFromMetadata: true)
        #expect(AppleImmersiveVideoEntryPolicy.automaticallyEnters(layout, debugProbeRequested: probeRequested))
    }

    @Test func nameOnlyWaitsForTheViewer() {
        let layout = AppleImmersiveVideoLayout(projection: .halfSphere, packing: .sideBySide, isFromMetadata: false)
        #expect(!AppleImmersiveVideoEntryPolicy.automaticallyEnters(layout, debugProbeRequested: false))
        #if DEBUG
        #expect(AppleImmersiveVideoEntryPolicy.automaticallyEnters(layout, debugProbeRequested: true))
        #else
        #expect(!AppleImmersiveVideoEntryPolicy.automaticallyEnters(layout, debugProbeRequested: true))
        #endif
    }
}

/// Name-only VR files are read with Google spherical tags in their header.
@Suite struct AppleSphericalMetadataWriterTests {
    private typealias Writer = AppleSphericalMetadataWriter

    private func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(body.count + 8).bigEndian, Array.init) + Array(type.utf8) + body
    }

    private func track(handler: String, entry: String) -> [UInt8] {
        let hdlr = box("hdlr", [UInt8](repeating: 0, count: 8) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + box(entry, [UInt8](repeating: 7, count: 78)))
        let minf = box("minf", box("vmhd", [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]) + box("stbl", stsd))
        return box("trak", box("tkhd", [UInt8](repeating: 1, count: 84)) + box("mdia", hdlr + minf))
    }

    /// The child of each box along `path`, starting inside `bytes`.
    private func find(_ path: [String], in bytes: [UInt8]) throws -> Writer.Box {
        var range = 0..<bytes.count
        var found: Writer.Box?
        for type in path {
            let skip = found?.type == "stsd" ? 8 : 0
            let children = try #require(Writer.children(of: bytes, in: range.lowerBound + skip..<range.upperBound))
            found = try #require(children.first { $0.type == type })
            range = found!.body
        }
        return try #require(found)
    }

    @Test(arguments: [
        ("trip_180_LR.mp4", CGSize(width: 1920, height: 1080), UInt8(2), UInt32(0x4000_0000)),
        ("trip_180_TB.mp4", CGSize(width: 960, height: 2160), 1, 0x4000_0000),
        ("tour_360_TB.mp4", CGSize(width: 3840, height: 3840), 1, 0),
        ("tour.vr360.mp4", CGSize(width: 3840, height: 1920), 0, 0),
    ])
    func layoutGivesStereoModeAndBounds(name: String, size: CGSize, stereoMode: UInt8, sideBound: UInt32) throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(filename: name, videoSize: size))
        let tags = try #require(Writer.sphericalBoxes(for: layout))
        let st3d = try find(["st3d"], in: tags)
        #expect(Array(tags[st3d.body]) == [0, 0, 0, 0, stereoMode])
        let equi = try find(["sv3d", "proj", "equi"], in: tags)
        // version/flags, then top, bottom, left, right.
        #expect(Writer.readUInt32(tags, at: equi.body.lowerBound + 4) == 0)
        #expect(Writer.readUInt32(tags, at: equi.body.lowerBound + 8) == 0)
        #expect(Writer.readUInt32(tags, at: equi.body.lowerBound + 12) == sideBound)
        #expect(Writer.readUInt32(tags, at: equi.body.lowerBound + 16) == sideBound)
        _ = try find(["sv3d", "svhd"], in: tags)
        _ = try find(["sv3d", "proj", "prhd"], in: tags)
    }

    /// `st3d` cannot say the right eye comes first; tagging these would show
    /// each eye the other's picture.
    @Test(arguments: ["clip_180_RL.mp4", "clip_180_BT.mp4"])
    func rightEyeFirstFilesUseTheCompositorInsteadOfMisleadingTags(name: String) throws {
        let layout = try #require(AppleImmersiveVideoDetector.layout(filename: name, videoSize: nil))
        #expect(Writer.sphericalBoxes(for: layout) == nil)
    }

    @Test func onlyTheVideoSampleEntryIsTagged() throws {
        let tags = try #require(Writer.sphericalBoxes(for: AppleImmersiveVideoLayout(
            projection: .halfSphere, packing: .overUnder, isFromMetadata: false)))
        let audio = track(handler: "soun", entry: "mp4a")
        let moov = box("moov", box("mvhd", [UInt8](repeating: 2, count: 100)) + track(handler: "vide", entry: "avc1") + audio)
        let tagged = try #require(Writer.taggedMovie(moov, boxes: tags))

        #expect(tagged.count == moov.count + tags.count)
        #expect(Int(Writer.readUInt32(tagged, at: 0)) == tagged.count)
        let entry = try find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "avc1"], in: tagged)
        #expect(Array(tagged[entry.body.suffix(tags.count)]) == tags)
        #expect(Array(tagged[entry.body.prefix(78)]) == [UInt8](repeating: 7, count: 78))
        #expect(Array(tagged.suffix(audio.count)) == audio)
    }

    @Test func aHeaderWithoutVideoIsLeftAlone() throws {
        let tags = try #require(Writer.sphericalBoxes(for: AppleImmersiveVideoLayout(
            projection: .halfSphere, packing: .sideBySide, isFromMetadata: false)))
        let moov = box("moov", track(handler: "soun", entry: "mp4a"))
        #expect(Writer.taggedMovie(moov, boxes: tags) == nil)
        var truncated = box("moov", track(handler: "vide", entry: "avc1"))
        truncated.removeLast()
        #expect(Writer.taggedMovie(truncated, boxes: tags) == nil)
    }
}

import AVFoundation
import CoreMedia
import CoreImage
import Foundation

/// How much of the sphere a VR video covers.
public enum AppleImmersiveProjection: String, Equatable, Sendable {
    /// VR180: half-equirectangular, a hemisphere in front of the viewer.
    case halfSphere
    /// VR360: equirectangular, the whole sphere.
    case fullSphere
}

/// How the two eyes share one frame.
public enum AppleImmersiveViewPacking: String, Equatable, Sendable {
    case mono
    case sideBySide
    case overUnder
}

/// A VR video's shape: projection, eye packing, and where that was learned.
public struct AppleImmersiveVideoLayout: Equatable, Sendable {
    public var projection: AppleImmersiveProjection
    public var packing: AppleImmersiveViewPacking
    /// Right eye first (`_RL`, `_BT`).
    public var eyesSwapped: Bool
    /// The file's own spherical metadata (APMP, or st3d/sv3d that AVFoundation
    /// resolves) rather than its name.
    public var isFromMetadata: Bool

    public init(projection: AppleImmersiveProjection, packing: AppleImmersiveViewPacking,
                eyesSwapped: Bool = false, isFromMetadata: Bool) {
        self.projection = projection
        self.packing = packing
        self.eyesSwapped = eyesSwapped
        self.isFromMetadata = isFromMetadata
    }

    public var isStereo: Bool { packing != .mono }

    /// Core Image coordinates start at the bottom of the frame.
    func eyeRect(left: Bool, size: CGSize) -> CGRect {
        let first = left != eyesSwapped
        switch packing {
        case .mono: return CGRect(origin: .zero, size: size)
        case .sideBySide:
            return CGRect(x: first ? 0 : size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .overUnder:
            return CGRect(x: 0, y: first ? size.height / 2 : 0, width: size.width, height: size.height / 2)
        }
    }

    func eyeImage(left: Bool, image: CIImage) -> CIImage {
        let rect = eyeRect(left: left, size: image.extent.size)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    public var projectionKind: OpenStreamProjection {
        switch (projection, isStereo) {
        case (.halfSphere, true): .stereo180
        case (.halfSphere, false): .mono180
        case (.fullSphere, true): .stereo360
        case (.fullSphere, false): .mono360
        }
    }
}

/// Recognises VR180 and VR360 video from metadata or from the file name.
public enum AppleImmersiveVideoDetector {
    /// From the format description's projection and packing extensions.
    public static func layout(projectionKind: String?, viewPackingKind: String?) -> AppleImmersiveVideoLayout? {
        let projection: AppleImmersiveProjection
        if projectionKind == kCMFormatDescriptionProjectionKind_HalfEquirectangular as String {
            projection = .halfSphere
        } else if projectionKind == kCMFormatDescriptionProjectionKind_Equirectangular as String {
            projection = .fullSphere
        } else {
            return nil
        }
        let packing: AppleImmersiveViewPacking
        if viewPackingKind == kCMFormatDescriptionViewPackingKind_SideBySide as String { packing = .sideBySide }
        else if viewPackingKind == kCMFormatDescriptionViewPackingKind_OverUnder as String { packing = .overUnder }
        else { packing = .mono }
        return AppleImmersiveVideoLayout(projection: projection, packing: packing, isFromMetadata: true)
    }

    private static let halfSphereTokens: Set<String> = ["vr180", "180x180", "180vr"]
    private static let fullSphereTokens: Set<String> = ["vr360", "360vr", "360x180"]
    private static let sideBySideTokens: Set<String> = ["lr", "sbs", "hsbs", "fsbs", "3dh", "sidebyside"]
    private static let overUnderTokens: Set<String> = ["tb", "ou", "htb", "hou", "3dv", "overunder", "topbottom"]
    private static let monoTokens: Set<String> = ["mono", "2d"]

    /// From the naming players share (`_180_LR`, `VR180`, `_360_TB`, `_3dh`).
    /// A projection word is required: a side-by-side name alone is a 3D film,
    /// not VR. Without a packing word the frame's shape decides it.
    public static func layout(filename: String, videoSize: CGSize?) -> AppleImmersiveVideoLayout? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let words = stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let tokens = Set(words)
        let qualifiers = sideBySideTokens.union(overUnderTokens).union(monoTokens).union(["rl", "bt", "vr"])
        func qualified(_ number: String) -> Bool {
            words.indices.contains { index in
                words[index] == number && ((index > 0 && qualifiers.contains(words[index - 1]))
                    || (index + 1 < words.count && qualifiers.contains(words[index + 1])))
            }
        }
        let projection: AppleImmersiveProjection
        if !tokens.isDisjoint(with: halfSphereTokens) || qualified("180") { projection = .halfSphere }
        else if !tokens.isDisjoint(with: fullSphereTokens) || qualified("360") { projection = .fullSphere }
        else { return nil }

        if tokens.contains("rl") {
            return AppleImmersiveVideoLayout(projection: projection, packing: .sideBySide, eyesSwapped: true, isFromMetadata: false)
        }
        if tokens.contains("bt") {
            return AppleImmersiveVideoLayout(projection: projection, packing: .overUnder, eyesSwapped: true, isFromMetadata: false)
        }
        let packing: AppleImmersiveViewPacking
        if !tokens.isDisjoint(with: sideBySideTokens) { packing = .sideBySide }
        else if !tokens.isDisjoint(with: overUnderTokens) { packing = .overUnder }
        else if !tokens.isDisjoint(with: monoTokens) { packing = .mono }
        else { packing = self.packing(projection: projection, videoSize: videoSize) }
        return AppleImmersiveVideoLayout(projection: projection, packing: packing, isFromMetadata: false)
    }

    /// A hemisphere is square per eye and a sphere twice as wide as tall, so
    /// the frame's aspect names the packing. Unknown sizes take the common case.
    static func packing(projection: AppleImmersiveProjection, videoSize: CGSize?) -> AppleImmersiveViewPacking {
        let fallback: AppleImmersiveViewPacking = projection == .halfSphere ? .sideBySide : .mono
        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return fallback }
        let aspect = videoSize.width / videoSize.height
        let shapes: [(CGFloat, AppleImmersiveViewPacking)] = projection == .halfSphere
            ? [(2, .sideBySide), (1, .mono), (0.5, .overUnder)]
            : [(4, .sideBySide), (2, .mono), (1, .overUnder)]
        return shapes.first(where: { abs(aspect / $0.0 - 1) < 0.15 })?.1 ?? fallback
    }

    /// Worth probing: an on-demand MPEG-4/QuickTime file AVFoundation opens
    /// itself, from a local file or a header-free HTTP URL (the share proxy).
    public static func isCandidate(_ request: ApplePlaybackRequest) -> Bool {
        guard !request.isLive, request.hints.disc == nil, request.effectiveHeaders.isEmpty,
              let scheme = request.url.scheme?.lowercased(), ["file", "http", "https"].contains(scheme),
              let ext = AppleTVPlaybackPresentationPolicy.containerExtension(url: request.url, filename: request.hints.filename)
        else { return false }
        return ["mp4", "m4v", "mov", "qt"].contains(ext)
    }
}

enum AppleImmersiveVideoEntryPolicy {
    static func automaticallyEnters(_ layout: AppleImmersiveVideoLayout, debugProbeRequested: Bool) -> Bool {
        if layout.isFromMetadata { return true }
        #if DEBUG
        return debugProbeRequested
        #else
        return false
        #endif
    }
}

#if os(visionOS)
@MainActor
struct AppleImmersivePreparedAsset {
    let layout: AppleImmersiveVideoLayout
    let videoComposition: AVVideoComposition?
}

@MainActor
enum AppleImmersiveVideoProbe {
    /// A file recognised as VR only by its name, read with the spherical
    /// tags the name implies so AVKit offers its immersive view. Nil keeps
    /// the plain asset: already tagged, not VR, or a header it cannot rewrite.
    @available(visionOS 26.0, *)
    nonisolated static func taggedAsset(url: URL, filename: String) async -> AVURLAsset? {
        guard let named = AppleImmersiveVideoDetector.layout(filename: filename, videoSize: nil),
              !named.eyesSwapped else { return nil }
        let plain = AVURLAsset(url: url, options: [AVURLAssetShouldParseExternalSphericalTagsKey: true])
        let source = AppleSphericalByteSource(url: url)
        let tagged: AppleSphericalTaggedAsset? = await AppleImmersiveProbeDeadline.run(cancel: {
            plain.cancelLoading()
            source.cancel()
        }) {
            defer { plain.cancelLoading() }
            guard let track = try? await plain.loadTracks(withMediaType: .video).first,
              let (formats, size) = try? await track.load(.formatDescriptions, .naturalSize),
              let format = formats.first,
              CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ProjectionKind) == nil,
              let layout = AppleImmersiveVideoDetector.layout(filename: filename, videoSize: size),
              let boxes = AppleSphericalMetadataWriter.sphericalBoxes(for: layout) else { return nil }
            return try? await AppleSphericalTaggedAsset.make(source: source, filename: filename, boxes: boxes)
        }
        if tagged == nil { source.cancel() }
        return tagged
    }

    static func prepare(asset: AVAsset, filename: String) async -> AppleImmersivePreparedAsset? {
        guard #available(visionOS 26.0, *) else { return nil }
        if let layout = await layout(of: asset) {
            return AppleImmersivePreparedAsset(layout: layout, videoComposition: nil)
        }
        guard let layout = AppleImmersiveVideoDetector.layout(filename: filename, videoSize: nil),
              layout.eyesSwapped,
              let composition = try? await AppleImmersiveVideoCompositor.composition(asset: asset, layout: layout),
              !Task.isCancelled else { return nil }
        return AppleImmersivePreparedAsset(layout: layout, videoComposition: composition)
    }

    /// The playing asset's projection. A `taggedAsset` reports what its name
    /// gave, so it still waits for "View in VR".
    @available(visionOS 26.0, *)
    static func layout(of asset: AVAsset) async -> AppleImmersiveVideoLayout? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first, !Task.isCancelled else { return nil }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        guard var layout = AppleImmersiveVideoDetector.layout(
            projectionKind: extensions[kCMFormatDescriptionExtension_ProjectionKind as String] as? String,
            viewPackingKind: extensions[kCMFormatDescriptionExtension_ViewPackingKind as String] as? String) else { return nil }
        layout.isFromMetadata = !(asset is AppleSphericalTaggedAsset)
        appleTrace("immersive: \(layout.projectionKind.rawValue) \(layout.packing.rawValue) from the \(layout.isFromMetadata ? "metadata" : "name")")
        return layout
    }
}
#endif

#if OPENSTREAM_ADDONS
import Foundation

/// Only an installed YouTube source may receive a shared video's identifier.
enum AppleSharedLinkYouTubePolicy {
    static func sources(in sources: [AppleSource]) -> [AppleSource] {
        sources.filter {
            let identity = ($0.manifestID ?? "").lowercased()
            return $0.isEnabled && $0.isAddon && $0.resources.contains("stream")
                && ($0.catalogs.contains { $0.type == "youtube" || $0.id.hasPrefix("yt_id:") }
                    || identity.contains("youtube") || identity.contains("youtubio"))
        }
    }

    static func item(videoID: String, source: AppleSource) -> AppleCatalogItem {
        let catalog = source.catalogs.first { $0.type == "youtube" || $0.id.hasPrefix("yt_id:") }
            ?? source.catalogs.first
        // YouTubio advertises yt_id: in its catalog identifiers (its public manifest).
        let prefix = catalog?.id.hasPrefix("yt_id:") == true
            || (source.manifestID ?? "").lowercased().contains("youtubio") ? "yt_id:" : "yt:"
        return AppleCatalogItem(mediaID: prefix + videoID, type: catalog?.type ?? "youtube", name: "YouTube")
    }
}
#endif

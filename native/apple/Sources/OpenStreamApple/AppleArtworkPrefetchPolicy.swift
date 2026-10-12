import Foundation

/// Pure policies for deciding what artwork to prefetch.
public enum AppleArtworkPrefetchPolicy {
    /// Returns the URLs to prefetch for a list of catalogue sections.
    ///
    /// Preserves order (first position wins) and removes duplicates.
    /// - Parameters:
    ///   - sections: The sections of items.
    ///   - perSection: The maximum number of items to inspect per section.
    public static func urls(sections: [[AppleCatalogItem]], perSection: Int = 12) -> [URL] {
        var urls: [URL] = []
        var seen: Set<URL> = []

        for section in sections {
            let items = section.prefix(perSection)
            for item in items {
                // The item's poster, backdrop/background and logo URLs (if available).
                // AppleCatalogItem currently provides posterURL and backgroundURL.
                let candidates = [item.posterURL, item.backgroundURL].compactMap { $0 }
                for url in candidates {
                    if !seen.contains(url) {
                        seen.insert(url)
                        urls.append(url)
                    }
                }
            }
        }
        return urls
    }

    /// Returns the URLs to prefetch for a detail view.
    ///
    /// Preserves order (first position wins) and removes duplicates.
    /// - Parameters:
    ///   - item: The primary item.
    ///   - episodeThumbnails: The thumbnails of the episodes to be shown.
    ///   - limit: The maximum number of episode thumbnails to include.
    public static func urls(forDetail item: AppleCatalogItem, episodeThumbnails: [URL], limit: Int = 20) -> [URL] {
        var urls: [URL] = []
        var seen: Set<URL> = []

        // The item's logo, backdrop, poster first.
        let candidates = [item.backgroundURL, item.posterURL].compactMap { $0 }
        for url in candidates {
            if !seen.contains(url) {
                seen.insert(url)
                urls.append(url)
            }
        }

        for url in episodeThumbnails.prefix(limit) {
            if !seen.contains(url) {
                seen.insert(url)
                urls.append(url)
            }
        }
        return urls
    }
}

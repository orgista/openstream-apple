import Foundation

/// Chooses owner-visible detail text without letting an empty catalog field
/// suppress richer metadata loaded from an enrichment provider.
enum AppleMetadataPresentationPolicy {
    static func title(metadata: String?, fallback: String) -> String {
        guard let title = metadata, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return title
    }

    static func synopsis(catalog: String?, enriched: String?) -> String? {
        [catalog, enriched]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : clean
            }
            .first
    }
}

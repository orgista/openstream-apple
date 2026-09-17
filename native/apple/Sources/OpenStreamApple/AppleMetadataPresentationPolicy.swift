import Foundation

/// Chooses owner-visible detail text without letting an empty catalog field
/// suppress richer metadata loaded from an enrichment provider.
enum AppleMetadataPresentationPolicy {
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

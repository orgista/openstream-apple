/// Results consumed as they arrive by the Discover hero. Kept outside the
/// generic view so child tasks capture only Sendable metadata types.
enum AppleHeroMetadataOutcome: Sendable {
    case preview(AppleStremioPreviewAssets?)
    case identity(String?)
    case episodes([AppleStremioEpisode])
    case details(AppleTMDBDetails?)
}

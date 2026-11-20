enum AppleArtworkLoadingPolicy {
    static func needsReload(loadedIdentity: String?, requestedIdentity: String, hasImage: Bool = true) -> Bool {
        !hasImage || loadedIdentity != requestedIdentity
    }
}

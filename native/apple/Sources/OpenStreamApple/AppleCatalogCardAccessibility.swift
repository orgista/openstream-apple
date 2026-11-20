/// How VoiceOver reads a catalog card.
///
/// A card that draws its title under the art is read as its children
/// combined. A card that draws none — every Apple TV poster, the Top 10 and
/// Featured cards, the Continue Watching still inside its tile — has to name
/// itself: combined children with no text of their own gave the link a blank
/// label (N41 on Apple TV, N49 on the iPad's Featured rows).
enum AppleCatalogCardAccessibility {
    static func namesItself(drawsTitle: Bool) -> Bool {
        #if os(tvOS)
        true
        #else
        !drawsTitle
        #endif
    }
}

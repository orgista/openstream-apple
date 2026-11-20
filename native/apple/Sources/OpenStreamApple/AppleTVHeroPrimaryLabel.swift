#if os(tvOS)
import SwiftUI

/// Only the label changes pages; the enclosing button keeps its focus identity.
struct AppleTVHeroPrimaryLabel: View {
    let button: AppleTitlePagePolicy.HeroButton
    @Environment(\.appleHeroActionPage) private var page

    var body: some View {
        AppleHeroPageFade(page: page, layer: .copy, alignment: .leading) {
            HStack(spacing: AppleTVBillboardMetrics.pillGlyphSpacing) {
                Image(systemName: button.systemImage)
                    .font(.system(size: AppleTVBillboardMetrics.pillGlyphSize, weight: .semibold))
                Text(button.title)
                    .lineLimit(1)
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var appleHeroActionPage = ""
}
#endif

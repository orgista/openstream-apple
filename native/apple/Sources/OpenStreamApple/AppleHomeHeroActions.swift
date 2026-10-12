import SwiftUI

struct AppleHomeHeroActions: View {
    let mode: AppleHomePresentationPolicy.Hero
    let viewportSize: CGSize
    let button: AppleTitlePagePolicy.HeroButton
    let isInList: Bool
    let tv: AppleHomeTVHeroContext?
    let onPlay: () -> Void
    let onToggleList: () -> Void
    let onDetails: () -> Void

    var body: some View {
        #if os(macOS)
        if mode == .mac {
            AppleHomeMacHeroActions(button: button, isInList: isInList, onPlay: onPlay, onToggleList: onToggleList)
        } else { fallback }
        #elseif os(tvOS)
        if let tv {
            AppleHomeTVHeroActions(button: button, isInList: isInList, focus: tv.focus,
                pagingEnabled: tv.pagingEnabled, willOpenPage: tv.willOpenPage,
                onPlay: onPlay, onToggleList: onToggleList, onDetails: onDetails)
        } else { fallback }
        #else
        if mode == .phone || mode == .pad {
            AppleHomePhoneHeroActions(button: button, isInList: isInList, onPlay: onPlay, onToggleList: onToggleList)
        } else { fallback }
        #endif
    }

    private var fallback: some View {
        AppleFeaturedActions(viewportSize: viewportSize, button: button, onPlay: onPlay, onDetails: onDetails)
    }
}

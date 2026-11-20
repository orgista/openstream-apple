import SwiftUI

/// A home page's size (Discover, Library). On iOS 18 the inline-large bar changes the safe area
/// by 18 pt every frame it collapses or expands, and each reading re-ran all
/// of the page's body (owner's iPhone, trace 2026-10-17). Nothing on the page
/// sizes itself off a change that small; a new width, a turn of the device or
/// a resize past the bars is taken at once. Only iOS bars move like that; a
/// Mac or visionOS window takes every resize.
enum AppleHomePageViewport {
    #if os(iOS)
    static let barSlack: CGFloat = 60
    #else
    static let barSlack: CGFloat = 0
    #endif

    static func settled(drawn: CGSize, measured: CGSize, barSlack: CGFloat = Self.barSlack) -> CGSize {
        guard drawn.width > 0, drawn.height > 0 else { return measured }
        if abs(measured.width - drawn.width) >= 1 { return measured }
        if (measured.width > measured.height) != (drawn.width > drawn.height) { return measured }
        return abs(measured.height - drawn.height) > barSlack ? measured : drawn
    }
}

#if os(iOS) || os(visionOS)
/// Reads a home page's scroll view (Discover, Library) into the iPhone and
/// iPad hero layouts. The readings change every frame the bar moves; they
/// stay in this modifier, so the page only redraws for a layout that is drawn.
struct AppleDiscoverHeroLayoutReader: ViewModifier {
    /// The page, in the trace.
    let page: String
    #if os(iOS)
    @Environment(\.appleIsLargeLayout) private var measuresPad
    #else
    private let measuresPad = true
    #endif
    @Binding var phone: AppleHomePhoneHeroLayout
    @Binding var pad: AppleMacHeroLayout
    /// The last reading, drawn once it has held (`AppleHomePhoneHeroLayout.settled`).
    @State private var measured = AppleHomePhoneHeroLayout()
    @State private var held = false

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .modifier(ApplePhoneLandingScrollReader(layout: phone))
            #endif
            .onScrollGeometryChange(for: AppleHomePhoneHeroLayout.self) { geometry in
                // The container is the part between the bars.
                AppleHomePhoneHeroLayout(containerHeight: geometry.containerSize.height
                                             + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                         topInset: geometry.contentInsets.top,
                                         bottomInset: geometry.contentInsets.bottom,
                                         containerWidth: geometry.containerSize.width)
            } action: { _, layout in
                measured = layout
                appleTrace("\(page) phone hero layout h=\(Int(layout.containerHeight)) top=\(Int(layout.topInset)) bottom=\(Int(layout.bottomInset)) art=\(Int(layout.artHeight))")
                draw(AppleHomePhoneHeroLayout.next(drawn: phone, measured: layout, held: held))
            }
            .task(id: measured) {
                try? await Task.sleep(for: AppleHomePhoneHeroLayout.settleDelay)
                guard !Task.isCancelled, measured.containerWidth > 0, measured.containerHeight > 0 else { return }
                if measured.containerHeight != phone.containerHeight { draw(measured) }
                held = true
            }
            .onScrollGeometryChange(for: AppleMacHeroLayout.self) { [measuresPad] geometry in
                guard measuresPad else { return AppleMacHeroLayout(platform: .pad) }
                return AppleMacHeroLayout(contentWidth: geometry.containerSize.width,
                                          windowHeight: geometry.containerSize.height
                                              + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                          topInset: geometry.contentInsets.top,
                                          platform: .pad)
            } action: { _, layout in
                pad = layout
            }
    }

    private func draw(_ layout: AppleHomePhoneHeroLayout) {
        guard layout != phone else { return }
        phone = layout
        appleTrace("\(page) phone hero drawn h=\(Int(layout.containerHeight)) top=\(Int(layout.topInset)) art=\(Int(layout.artHeight))")
    }
}
#endif

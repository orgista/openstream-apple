#if os(iOS)
import SwiftUI

struct AppleRootLayoutReader: ViewModifier {
    @Binding var viewportSize: CGSize
    let isLargeLayout: Bool
    let expandsPhoneLayout: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.appleIsLargeLayout, isLargeLayout)
            .environment(\.appleExpandsPhoneLayout, expandsPhoneLayout)
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                       height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            } action: { viewportSize = $0 }
            .onChange(of: isLargeLayout) { AppleOrientationLock.shared.windowSizeDidChange() }
    }
}
#endif

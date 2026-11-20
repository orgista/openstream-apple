import SwiftUI

@MainActor
enum ApplePlayerControlMetrics {
    #if os(tvOS)
    static let chromePointSize = AppleTVChromeMetrics.glyphFontSize
    #else
    static let chromePointSize: CGFloat = 20
    #endif
    static let transportPointSize: CGFloat = 34
    static let transportTargetSize = max(AppleDesignTokens.minimumActionSize, 56)
    static let chromeFont = Font.system(size: chromePointSize, weight: .semibold)
    static let transportFont = Font.system(size: transportPointSize, weight: .semibold)
}

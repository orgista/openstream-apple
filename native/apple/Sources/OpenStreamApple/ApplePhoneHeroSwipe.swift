import Foundation

enum ApplePhoneHeroSwipe {
    static func displacement(_ translation: CGSize, pageWidth: CGFloat) -> CGFloat {
        guard pageWidth > 0, abs(translation.width) > abs(translation.height) else { return 0 }
        return min(max(translation.width, -pageWidth), pageWidth)
    }

    static func turn(translation: CGSize, predicted: CGSize, pageWidth: CGFloat) -> Int? {
        guard pageWidth > 0, abs(translation.width) > abs(translation.height),
              abs(translation.width) > 50 || abs(predicted.width) > 160 else { return nil }
        return translation.width < 0 ? 1 : -1
    }
}

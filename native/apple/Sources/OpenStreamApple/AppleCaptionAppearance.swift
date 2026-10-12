import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility
import SwiftUI

/// A snapshot of system caption preferences. Mapping is separate from reading
/// global settings so rendering can be checked without changing the user's style.
struct AppleCaptionAppearance {
    let foreground: CGColor
    let background: CGColor
    let fontDescriptor: CTFontDescriptor?
    let relativeSize: CGFloat

    init(foreground: CGColor?, foregroundOpacity: CGFloat = 1,
         background: CGColor?, backgroundOpacity: CGFloat = 0,
         fontDescriptor: CTFontDescriptor?, relativeSize: CGFloat = 1) {
        self.foreground = (foreground ?? CGColor(gray: 1, alpha: 1))
            .copy(alpha: foregroundOpacity) ?? CGColor(gray: 1, alpha: 1)
        self.background = (background ?? CGColor(gray: 0, alpha: 1))
            .copy(alpha: backgroundOpacity) ?? CGColor(gray: 0, alpha: 0)
        self.fontDescriptor = fontDescriptor
        self.relativeSize = relativeSize.isFinite && relativeSize > 0 ? relativeSize : 1
    }

    static func system() -> Self {
        Self(
            foreground: MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue(),
            foregroundOpacity: MACaptionAppearanceGetForegroundOpacity(.user, nil),
            background: MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue(),
            backgroundOpacity: MACaptionAppearanceGetBackgroundOpacity(.user, nil),
            fontDescriptor: MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue(),
            relativeSize: MACaptionAppearanceGetRelativeCharacterSize(.user, nil)
        )
    }

    func font(baseSize: CGFloat, bold: Bool = false, italic: Bool = false) -> Font {
        var font: Font
        if let fontDescriptor {
            font = Font(CTFontCreateWithFontDescriptor(fontDescriptor, baseSize * relativeSize, nil))
        } else {
            font = .system(size: baseSize * relativeSize, weight: .semibold)
        }
        if bold { font = font.bold() }
        if italic { font = font.italic() }
        return font
    }

    func text(for cue: AppleSubtitleCue, baseSize: CGFloat) -> AttributedString {
        let runs: [AppleSubtitleTextRun]
        switch cue.body {
        case .text(let text): runs = [AppleSubtitleTextRun(text: text)]
        case .richText(let richRuns): runs = richRuns
        case .image: return AttributedString()
        }
        var result = AttributedString()
        for run in runs {
            var text = AttributedString(run.text)
            text.font = font(baseSize: baseSize, bold: run.isBold, italic: run.isItalic)
            text.foregroundColor = Color(cgColor: foreground)
            text.backgroundColor = Color(cgColor: background)
            if run.isUnderlined { text.underlineStyle = .single }
            if run.isStruckThrough { text.strikethroughStyle = .single }
            result.append(text)
        }
        return result
    }
}

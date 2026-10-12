import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import OpenStreamApple

@Suite("System caption appearance")
struct AppleCaptionAppearanceTests {
    @Test func missingStyleUsesReadableDefaults() throws {
        let style = AppleCaptionAppearance(foreground: nil, background: nil,
                                           fontDescriptor: nil, relativeSize: .nan)
        let cue = AppleSubtitleCue(id: 0, startTime: 0, endTime: 3, body: .text("Caption"))
        let text = style.text(for: cue, baseSize: 15)
        let run = try #require(text.runs.first)
        #expect(String(text.characters) == "Caption")
        #expect(style.foreground == CGColor(gray: 1, alpha: 1))
        #expect(style.background.alpha == 0)
        #expect(style.relativeSize == 1)
        #expect(run.font == .system(size: 15, weight: .semibold))
    }

    @Test func customStylePreservesRichTextEmphasis() throws {
        let descriptor = CTFontDescriptorCreateWithNameAndSize("Courier" as CFString, 15)
        let yellow = CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let style = AppleCaptionAppearance(foreground: yellow, foregroundOpacity: 0.8,
                                           background: blue, backgroundOpacity: 0.6,
                                           fontDescriptor: descriptor, relativeSize: 1.5)
        let cue = AppleSubtitleCue(id: 0, startTime: 0, endTime: 3, body: .richText([
            AppleSubtitleTextRun(text: "Plain "),
            AppleSubtitleTextRun(text: "italic", isBold: true, isItalic: true,
                                 isUnderlined: true, isStruckThrough: true),
        ]))
        let text = style.text(for: cue, baseSize: 20)
        let runs = Array(text.runs)
        try #require(runs.count == 2)
        let baseFont = Font(CTFontCreateWithFontDescriptor(descriptor, 30, nil))
        #expect(String(text.characters) == "Plain italic")
        #expect(runs[0].font == baseFont)
        #expect(runs[1].font == baseFont.bold().italic())
        #expect(runs[1].underlineStyle == .single)
        #expect(runs[1].strikethroughStyle == .single)
        #expect(runs[0].foregroundColor == Color(cgColor: yellow.copy(alpha: 0.8)!))
        #expect(runs[1].backgroundColor == Color(cgColor: blue.copy(alpha: 0.6)!))
    }

    @Test func systemSwitchOnlyAddsAnOnSignal() {
        for preference in AppleCaptionsPreference.allCases {
            #expect(AppleCaptionsPreference.effective(preference, systemCaptionsEnabled: false) == preference)
            #expect(AppleCaptionsPreference.effective(preference, systemCaptionsEnabled: true)
                    == (preference == .off ? .always : preference))
        }
    }
}

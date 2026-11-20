import AetherEngine
import Foundation
import Testing
@testable import OpenStreamApple

/// iPhone 27 v2 re-run: Russian Windows-1251 sidecars showed mojibake and
/// UTF-16 Portuguese ones showed nothing. The fixtures in
/// `Tests/Fixtures/subtitles` are two-cue SubRip files in each encoding.
@Suite struct AppleSubtitleTextEncodingTests {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/subtitles/\(name)")
        return try Data(contentsOf: url)
    }

    private func texts(_ name: String, language: String?) throws -> [String] {
        AppleSubtitleTextParser.cues(from: try fixture(name), language: language).compactMap(\.text)
    }

    @Test(arguments: [
        ("ru-cp1251.srt", "rus", "Привет, как дела?"),
        ("ru-cp1251.srt", "ru", "Привет, как дела?"),
        ("uk-cp1251.srt", "ukr", "Доброго ранку!"),
        ("pt-utf16le-bom.srt", "por", "Olá, tudo bem?"),
        ("pt-utf16le-nobom.srt", "pob", "Olá, tudo bem?"),
        ("pt-utf16be-bom.srt", "pt", "Olá, tudo bem?"),
        ("es-utf32le-bom.srt", "spa", "¿Qué tal, señor?"),
        ("fr-utf8-bom.srt", "fre", "Ça va très bien."),
        ("fr-cp1252.srt", "fra", "Ça va très bien."),
        ("pl-cp1250.srt", "pol", "Zażółć gęślą jaźń."),
        ("el-cp1253.srt", "ell", "Γειά σου κόσμε."),
        ("ar-cp1256.srt", "ara", "مرحبا بالعالم"),
        ("ja-shiftjis.srt", "jpn", "こんにちは世界"),
        ("zh-gbk.srt", "chi", "你好，世界"),
        ("zh-tw-big5.srt", "zh-TW", "你好，世界"),
    ])
    func eachEncodingReadsBackItsFirstCue(file: String, language: String, expected: String) throws {
        let cues = try texts(file, language: language)
        #expect(cues.count == 2)
        #expect(cues.first == expected)
    }

    /// No declared language: the bytes decide. Unicode needs no hint at all,
    /// and mostly-high-byte text is read as Cyrillic.
    @Test func withoutALanguageTheBytesDecide() throws {
        #expect(try texts("pt-utf16le-nobom.srt", language: nil).last == "Legendas em português, ação.")
        #expect(try texts("ru-cp1251.srt", language: nil).first == "Привет, как дела?")
        #expect(try texts("fr-cp1252.srt", language: nil).first == "Ça va très bien.")
    }

    @Test func theDetectorsPieces() {
        #expect(AppleSubtitleTextEncoding.byteOrderMark([0xFF, 0xFE, 0x31, 0x00])?.0 == .utf16LittleEndian)
        #expect(AppleSubtitleTextEncoding.byteOrderMark([0xFF, 0xFE, 0x00, 0x00])?.0 == .utf32LittleEndian)
        #expect(AppleSubtitleTextEncoding.byteOrderMark([0x31, 0x0D, 0x0A]) == nil)
        let ascii = Array("1\r\n00:00:01,000 --> 00:00:03,000\r\n".utf8)
        #expect(AppleSubtitleTextEncoding.utf16WithoutMark(ascii) == nil)
        let be = Array("1\r\n00:00:01,000".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        #expect(AppleSubtitleTextEncoding.utf16WithoutMark(be) == .utf16BigEndian)
    }

    /// iOS 18.6 regression 2026-10-01 (A Different World, screens 28–31): the
    /// OpenSubtitles file itself says "£" where the broadcast caption had "♪".
    @Test func aPoundSignWithNoAmountIsTheMusicNote() {
        let srt = "1\r\n00:00:06,005 --> 00:00:08,708\r\n£ I know my parents love me £\r\n\r\n"
            + "2\r\n00:00:09,000 --> 00:00:10,000\r\nThat's £5. It cost 20 £, or £ 30.\r\n"
        let cues = AppleSubtitleTextParser.cues(from: Data(srt.utf8), language: "eng")
        #expect(cues.map(\.body) == [.text("♪ I know my parents love me ♪"), .text("That's £5. It cost 20 £, or £ 30.")])
    }

    /// The other file for that episode is UTF-8 read as Latin-1 and saved as
    /// UTF-8 again: "Â£ I KNOW MY PARENTS LOVE ME Â£".
    @Test func doublyEncodedUTF8IsRepaired() {
        let srt = "1\n00:00:06,005 --> 00:00:08,708\nÂ£ I KNOW MY PARENTS LOVE ME Â£\n\n2\n00:00:09,000 --> 00:00:10,000\nCafÃ© crÃ¨me\n"
        let cues = AppleSubtitleTextParser.cues(from: Data(srt.utf8))
        #expect(cues.map(\.body) == [.text("♪ I KNOW MY PARENTS LOVE ME ♪"), .text("Café crème")])
        // Real text with an Â in it, or anything Latin-1 cannot hold, is left alone.
        #expect(AppleSubtitleTextParser.utf8MojibakeRepaired("Â bientôt") == "Â bientôt")
        #expect(AppleSubtitleTextParser.utf8MojibakeRepaired("Ã ♪") == "Ã ♪")
    }

    /// On the sim the "£" came from the MKV's own text track, decoded by the
    /// engine, not from a sidecar file: its cues get the same repair.
    @MainActor
    @Test func embeddedTextCuesGetTheMusicNoteToo() {
        #expect(AetherPlaybackEngine.mapCueBody(.text("£ BECAUSE I FINALLY\nHEARD THEM SAY £"))
            == .text("♪ BECAUSE I FINALLY\nHEARD THEM SAY ♪"))
        #expect(AetherPlaybackEngine.mapCueBody(.text("That's £5.")) == .text("That's £5."))
    }
}

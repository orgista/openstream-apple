import Foundation

/// Works out how a downloaded subtitle file is encoded.
///
/// iPhone 27 v2 re-run: a Windows-1251 Russian SubRip showed mojibake (it was
/// read as Windows-1252) and a UTF-16 Portuguese one showed nothing (its
/// timings never parsed). In order:
/// 1. a byte-order mark (UTF-8, UTF-32 LE/BE, UTF-16 LE/BE);
/// 2. UTF-16 without one, from the pattern of zero bytes;
/// 3. valid UTF-8;
/// 4. the legacy code page of the subtitle's declared language (the add-on's
///    `lang`), else a guess from the bytes: mostly high bytes is Cyrillic
///    Windows-1251, otherwise Western Windows-1252.
public enum AppleSubtitleTextEncoding {
    public static func decode(_ data: Data, language: String? = nil) -> String? {
        let bytes = [UInt8](data)
        if let (encoding, skip) = byteOrderMark(bytes) {
            return String(data: Data(bytes.dropFirst(skip)), encoding: encoding)
        }
        if let encoding = utf16WithoutMark(bytes), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        for encoding in legacyEncodings(for: language, bytes: bytes) {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Unicode

    static func byteOrderMark(_ bytes: [UInt8]) -> (String.Encoding, Int)? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    /// Subtitle text is mostly digits, punctuation and Latin letters, so in
    /// UTF-16 every other byte is zero: the odd ones for little-endian, the
    /// even ones for big-endian. Text in any 8-bit encoding has no zero bytes.
    static func utf16WithoutMark(_ bytes: [UInt8]) -> String.Encoding? {
        let sample = bytes.prefix(4_096)
        guard sample.count >= 8 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = Double(sample.count / 2)
        if Double(oddZeros) > pairs * 0.3, Double(evenZeros) < pairs * 0.05 { return .utf16LittleEndian }
        if Double(evenZeros) > pairs * 0.3, Double(oddZeros) < pairs * 0.05 { return .utf16BigEndian }
        return nil
    }

    // MARK: - Legacy code pages

    /// The code pages to try, most likely first.
    static func legacyEncodings(for language: String?, bytes: [UInt8]) -> [String.Encoding] {
        if let language, let encodings = encodings(forLanguage: language) { return encodings + [.windowsCP1252] }
        return [guessFromBytes(bytes), .windowsCP1252]
    }

    /// The legacy encodings subtitle files in `language` are found in.
    static func encodings(forLanguage raw: String) -> [String.Encoding]? {
        let lowered = raw.lowercased()
        let traditionalChinese = ["tw", "hk", "hant", "zht", "cht"].contains { lowered.contains($0) }
        guard let code = AppleTrackCarryOver.normalized(raw) else { return nil }
        switch code {
        case "ru", "uk", "bg", "sr", "mk", "be", "rus", "ukr", "bul", "srp", "mkd", "bel":
            return [.windowsCP1251, cf(.isoLatinCyrillic), cf(.KOI8_R)]
        case "pl", "cs", "sk", "hu", "sl", "hr", "ro", "bs", "sq":
            return [.windowsCP1250, .isoLatin2]
        case "el": return [.windowsCP1253, cf(.isoLatinGreek)]
        case "tr": return [.windowsCP1254, cf(.isoLatin5)]
        case "he": return [cf(.windowsHebrew), cf(.isoLatinHebrew)]
        case "ar", "fa", "ur": return [cf(.windowsArabic), cf(.isoLatinArabic)]
        case "lt", "lv", "et": return [cf(.windowsBalticRim), cf(.isoLatin4)]
        case "vi": return [cf(.windowsVietnamese)]
        case "th": return [cf(.dosThai)]
        case "zh", "chi", "zho":
            return traditionalChinese ? [cf(.big5), cf(.GB_18030_2000)] : [cf(.GB_18030_2000), cf(.big5)]
        case "ja", "jpn": return [.shiftJIS, .japaneseEUC]
        case "ko", "kor": return [cf(.EUC_KR), cf(.dosKorean)]
        default: return [.windowsCP1252, .isoLatin1]
        }
    }

    /// Without a language: Cyrillic in Windows-1251 is nearly all bytes
    /// 0xC0...0xFF, where a Western file has an accent here and there.
    static func guessFromBytes(_ bytes: [UInt8]) -> String.Encoding {
        var high = 0, letters = 0
        for byte in bytes {
            if byte >= 0xC0 { high += 1; letters += 1 } else if (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) { letters += 1 }
        }
        guard letters > 0 else { return .windowsCP1252 }
        return Double(high) / Double(letters) > 0.3 ? .windowsCP1251 : .windowsCP1252
    }

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}

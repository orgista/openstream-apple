import Foundation

/// What a file or version name says about its picture.
public enum AppleReleaseName {
    /// The vertical resolution a name states (`2160p`, `4K`, `UHD`, `1080i`…), or 0.
    public static func resolution(_ text: String) -> Int {
        let lower = text.lowercased()
        if lower.range(of: #"\b8k\b"#, options: .regularExpression) != nil { return 4320 }
        if lower.range(of: #"\b(?:4k|uhd)\b"#, options: .regularExpression) != nil { return 2160 }
        guard let range = lower.range(of: #"\b(?:4320|2160|1440|1080|720|576|480)[pi]\b"#, options: .regularExpression) else { return 0 }
        return Int(lower[range].dropLast()) ?? 0
    }
}

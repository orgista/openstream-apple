import AVFoundation
import Foundation

/// What the stock player's transport names above its scrubber. With nothing
/// given, AVKit falls back to the file's own container tags: a 2015 film
/// showed "2023", the title tag of the release it was cut from (Apple TV
/// check, 2026-10-01). The title page's own title replaces it.
///
/// The small line above the title is AVKit's "<date's year> • <subtitle>",
/// and the "2023" was the file's own date tag: setting only a subtitle drew
/// "2023 • 2015", and a blank date "• 2015". So the year goes in every date
/// slot AVKit reads, as a date (a bare "2015" string drew this year), and a
/// subtitle (an episode's show) only when there is one — an empty subtitle
/// still draws its "•".
public enum AppleStockPlayerMetadata {
    public static func items(title: String?, subtitle: String? = nil, year: Int? = nil) -> [AVMetadataItem] {
        guard let title = clean(title) else { return [] }
        var items = [item(.commonIdentifierTitle, title as NSString)]
        if let subtitle = clean(subtitle) { items.append(item(.iTunesMetadataTrackSubTitle, subtitle as NSString)) }
        if let date = year.flatMap(midYear) {
            for identifier in dateIdentifiers { items.append(item(identifier, date as NSDate)) }
        }
        return items
    }

    static let dateIdentifiers: [AVMetadataIdentifier] = [
        .commonIdentifierCreationDate, .quickTimeMetadataCreationDate, .iTunesMetadataReleaseDate,
    ]

    /// Midyear, so no time zone moves it into another year.
    static func midYear(_ year: Int) -> Date? {
        guard (1_870 ... 2_200).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: year, month: 7, day: 1, hour: 12))
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }
}

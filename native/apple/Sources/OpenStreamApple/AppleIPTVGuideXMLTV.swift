import Foundation

final class AppleIPTVGuideXMLTVParser: NSObject, XMLParserDelegate, Sendable {
    static func parseDate(_ value: String, defaultOffsetHours: Double = 0) -> Date? {
        parseDate(value, defaultOffsetSeconds: defaultOffsetSeconds(hours: defaultOffsetHours))
    }

    fileprivate static func defaultOffsetSeconds(hours: Double) -> Int {
        let clamped = hours.isFinite ? min(14, max(-12, hours)) : 0
        let seconds = Int(clamped * 3600)
        // The former formatter uses the fixed zone's identifier, which rounds
        // sub-minute offsets to the nearest minute, with ties away from zero.
        return ((abs(seconds) + 30) / 60 * 60) * (seconds < 0 ? -1 : 1)
    }

    /// XMLTV's fixed digit layout, using Gregorian civil-day arithmetic.
    /// No Calendar or formatter allocation on the programme hot path.
    fileprivate static func parseDate(_ value: String, defaultOffsetSeconds: Int) -> Date? {
        let bytes = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard bytes.count >= 14 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var result = 0
            for index in start..<(start + count) {
                guard bytes[index] >= 48, bytes[index] <= 57 else { return nil }
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }
        guard let year = digits(0, 4), year > 0,
              let month = digits(4, 2), (1...12).contains(month),
              let day = digits(6, 2), day > 0,
              let hour = digits(8, 2), hour < 24,
              let minute = digits(10, 2), minute < 60,
              let second = digits(12, 2), second < 60 else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthDays: Int
        switch month {
        case 2: monthDays = leap ? 29 : 28
        case 4, 6, 9, 11: monthDays = 30
        default: monthDays = 31
        }
        guard day <= monthDays else { return nil }
        var offset = defaultOffsetSeconds
        if bytes.count > 14 {
            var index = 14
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
            guard index > 14, bytes.count == index + 5,
                  bytes[index] == 43 || bytes[index] == 45,
                  let offsetHour = digits(index + 1, 2), offsetHour < 24,
                  let offsetMinute = digits(index + 3, 2), offsetMinute < 60 else { return nil }
            offset = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == 45 ? -1 : 1)
        }
        // March-based 400-year eras: 719468 days from civil origin to 1970-01-01.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468
        let epoch = days * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    func parse(data: Data, defaultOffsetHours: Double = 0) -> [AppleIPTVProgramme] {
        guide(data: data, defaultOffsetHours: defaultOffsetHours).allProgrammes
    }

    func guide(data: Data, defaultOffsetHours: Double = 0) -> AppleIPTVGuide {
        let parser = XMLParser(data: data)
        let delegate = ParserDelegate(defaultOffsetHours: defaultOffsetHours)
        parser.delegate = delegate
        parser.parse()
        return AppleIPTVGuide(programmes: delegate.programmes, channelNames: delegate.channelNames)
    }
    func validatedGuide(data: Data, defaultOffsetHours: Double = 0,
        progress: @escaping @Sendable (AppleImportProgress) -> Void = { _ in }) throws -> AppleIPTVGuide {
        try Task.checkCancellation()
        let stream = XMLTVProgressInputStream(data: data)
        let parser = XMLParser(stream: stream)
        let delegate = ParserDelegate(defaultOffsetHours: defaultOffsetHours)
        delegate.bytesRead = { stream.processedBytes }
        delegate.progress = progress
        delegate.totalBytes = data.count
        parser.delegate = delegate
        let succeeded = parser.parse()
        try Task.checkCancellation()
        guard succeeded else { throw parser.parserError ?? URLError(.cannotParseResponse) }
        progress(AppleImportProgress(items: delegate.programmes.count, bytes: data.count, totalBytes: data.count))
        return AppleIPTVGuide(programmes: delegate.programmes, channelNames: delegate.channelNames)
    }

}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    var progress: @Sendable (AppleImportProgress) -> Void = { _ in }
    var totalBytes = 0
    var bytesRead: () -> Int = { 0 }
    var programmes: [AppleIPTVProgramme] = []
    var channelNames: [String: String] = [:]
    private var catalogueID: String?
    private var displayName = ""
    
    private var currentElement: String = ""
    private var currentChannel: String = ""
    private var currentStart: Date?
    private var currentEnd: Date?
    
    private var currentTitle: String = ""
    private var currentSubtitle: String = ""
    private var currentDesc: String = ""
    private var currentCategory: String = ""
    
    private let defaultOffsetSeconds: Int

    init(defaultOffsetHours: Double) {
        defaultOffsetSeconds = AppleIPTVGuideXMLTVParser.defaultOffsetSeconds(hours: defaultOffsetHours)
        super.init()
    }

    private func parseDate(_ value: String) -> Date? {
        AppleIPTVGuideXMLTVParser.parseDate(value, defaultOffsetSeconds: defaultOffsetSeconds)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard !Task.isCancelled else { parser.abortParsing(); return }
        currentElement = elementName
        if elementName == "channel" {
            catalogueID = attributeDict["id"]
            displayName = ""
        }
        if elementName == "programme" {
            currentChannel = attributeDict["channel"] ?? ""
            if let startStr = attributeDict["start"] {
                currentStart = parseDate(startStr)
            } else {
                currentStart = nil
            }
            if let stopStr = attributeDict["stop"] {
                currentEnd = parseDate(stopStr)
            } else {
                currentEnd = nil
            }
            
            currentTitle = ""
            currentSubtitle = ""
            currentDesc = ""
            currentCategory = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !Task.isCancelled else { parser.abortParsing(); return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        
        switch currentElement {
        case "display-name" where catalogueID != nil: displayName += string
        case "title": currentTitle += string
        case "sub-title": currentSubtitle += string
        case "desc": currentDesc += string
        case "category": currentCategory += string
        default: break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !Task.isCancelled else { parser.abortParsing(); return }
        if elementName == "channel", let id = catalogueID, channelNames.count < AppleIPTVClient.maximumChannels {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !name.isEmpty { channelNames[id] = name }
            catalogueID = nil
        }
        if elementName == "programme" {
            guard let start = currentStart, let end = currentEnd, !currentChannel.isEmpty, end > start, !currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, programmes.count < AppleIPTVGuideDiskCache.maximumProgrammes else { return }
            
            let prog = AppleIPTVProgramme(
                id: "\(currentChannel)|\(Int64(start.timeIntervalSince1970))",
                channelID: currentChannel,
                title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: currentSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentSubtitle.trimmingCharacters(in: .whitespacesAndNewlines),
                description: currentDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentDesc.trimmingCharacters(in: .whitespacesAndNewlines),
                start: start,
                end: end,
                category: currentCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : currentCategory.trimmingCharacters(in: .whitespacesAndNewlines),
                isLive: false // Will be determined by guide querying logic comparing Date() to start/end
            )
            programmes.append(prog)
            if programmes.count.isMultiple(of: 128) {
                progress(AppleImportProgress(items: programmes.count, bytes: bytesRead(), totalBytes: totalBytes))
            }
        }
        currentElement = ""
    }
}

/// XMLParser reads bounded chunks; count the actual bytes consumed, including markup.
private final class XMLTVProgressInputStream: InputStream {
    private let backing: InputStream
    private(set) var processedBytes = 0
    override init(data: Data) {
        backing = InputStream(data: data)
        super.init(data: Data())
    }
    override func open() { backing.open() }
    override func close() { backing.close() }
    override var streamStatus: Stream.Status { backing.streamStatus }
    override var streamError: (any Error)? { backing.streamError }
    override var hasBytesAvailable: Bool { backing.hasBytesAvailable }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let count = backing.read(buffer, maxLength: len)
        if count > 0 { processedBytes += count }
        return count
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool {
        false
    }
}

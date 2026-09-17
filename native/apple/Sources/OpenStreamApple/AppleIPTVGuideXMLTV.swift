import Foundation

final class AppleIPTVGuideXMLTVParser: NSObject, XMLParserDelegate, Sendable {
    private final class State {
        var programmes: [AppleIPTVProgramme] = []
        
        var currentElement: String = ""
        
        var currentChannel: String = ""
        var currentStart: Date?
        var currentEnd: Date?
        
        var currentTitle: String = ""
        var currentSubtitle: String = ""
        var currentDesc: String = ""
        var currentCategory: String = ""
        
        func resetCurrent() {
            currentChannel = ""
            currentStart = nil
            currentEnd = nil
            currentTitle = ""
            currentSubtitle = ""
            currentDesc = ""
            currentCategory = ""
        }
    }
    
    // We cannot use non-Sendable `XMLParser` inside a Sendable method if it mutates state.
    // Instead we can wrap the parsing logically.
    func parse(data: Data) -> [AppleIPTVProgramme] {
        let parser = XMLParser(data: data)
        let delegate = ParserDelegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.programmes
    }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    var programmes: [AppleIPTVProgramme] = []
    
    private var currentElement: String = ""
    private var currentChannel: String = ""
    private var currentStart: Date?
    private var currentEnd: Date?
    
    private var currentTitle: String = ""
    private var currentSubtitle: String = ""
    private var currentDesc: String = ""
    private var currentCategory: String = ""
    
    private let dateFormatterWithOffset: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss Z"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    
    private let dateFormatterNoOffset: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df
    }()
    
    private func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = dateFormatterWithOffset.date(from: trimmed) {
            return d
        }
        if let d = dateFormatterNoOffset.date(from: trimmed) {
            return d
        }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
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
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        
        switch currentElement {
        case "title": currentTitle += string
        case "sub-title": currentSubtitle += string
        case "desc": currentDesc += string
        case "category": currentCategory += string
        default: break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "programme" {
            guard let start = currentStart, let end = currentEnd, !currentChannel.isEmpty else { return }
            
            let prog = AppleIPTVProgramme(
                id: UUID().uuidString,
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
        }
        currentElement = ""
    }
}

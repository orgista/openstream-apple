import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleIPTVGuide Tests")
struct AppleIPTVGuideTests {

    @Test("XMLTV parsing and nowAndNext")
    func testXMLTVParsingAndNowAndNext() async throws {
        let xmlString = """
        <?xml version="1.0" encoding="utf-8"?>
        <tv>
            <channel id="CNN">
                <display-name>CNN</display-name>
            </channel>
            <channel id="BBC">
                <display-name>BBC</display-name>
            </channel>
            <channel id="FOX">
                <display-name>FOX</display-name>
            </channel>
            <programme start="20260902100000 +0000" stop="20260902120000 +0000" channel="CNN">
                <title>News Hour</title>
                <desc>Latest news.</desc>
            </programme>
            <programme start="20260902120000 +0000" stop="20260902140000 +0000" channel="CNN">
                <title>Sports Hour</title>
            </programme>
            <programme start="20260902100000" stop="20260902130000" channel="BBC">
                <title>BBC News</title>
            </programme>
            <programme start="20260902130000" stop="20260902150000" channel="BBC">
                <title>BBC Sports</title>
            </programme>
            <programme start="20260902110000 +0200" stop="20260902130000 +0200" channel="FOX">
                <title>FOX News</title>
            </programme>
            <programme start="20260902130000 +0200" stop="20260902150000 +0200" channel="FOX">
                <title>FOX Sports</title>
            </programme>
        </tv>
        """
        
        let parser = AppleIPTVGuideXMLTVParser()
        let programmes = parser.parse(data: xmlString.data(using: .utf8)!)
        #expect(programmes.count == 6)
        
        let guide = AppleIPTVGuide(programmes: programmes)
        
        // Instant 1: 2026-09-02 11:00:00 UTC
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let instant1 = formatter.date(from: "20260902110000 +0000")!
        
        let cnn1 = guide.nowAndNext(channelID: "CNN", at: instant1)
        #expect(cnn1.now?.title == "News Hour")
        #expect(cnn1.next?.title == "Sports Hour")
        
        let bbc1 = guide.nowAndNext(channelID: "BBC", at: instant1)
        #expect(bbc1.now?.title == "BBC News")
        #expect(bbc1.next?.title == "BBC Sports")
        
        // FOX start is 11:00:00 +0200 which is 09:00:00 UTC. Stop is 13:00 +0200 = 11:00 UTC.
        // So at 11:00 UTC, FOX is exactly ending FOX News and starting FOX Sports? Wait, no, start is 09:00 UTC, stop is 11:00 UTC.
        // at 11:00 UTC it is exactly next?
        // Let's use 10:00 UTC for FOX.
        let instantFOX = formatter.date(from: "20260902100000 +0000")!
        let fox1 = guide.nowAndNext(channelID: "FOX", at: instantFOX)
        #expect(fox1.now?.title == "FOX News")
        #expect(fox1.next?.title == "FOX Sports")
    }

    @Test("Xtream parsing and base64 decode")
    func testXtreamParsing() async throws {
        // Base64 for "Test Title": VGVzdCBUaXRsZQ==
        // Base64 for "Test Desc": VGVzdCBEZXNj
        let json = """
        {
            "epg_listings": [
                {
                    "id": "1",
                    "epg_id": "1",
                    "title": "VGVzdCBUaXRsZQ==",
                    "description": "VGVzdCBEZXNj",
                    "start_timestamp": "1700000000",
                    "stop_timestamp": "1700003600"
                }
            ]
        }
        """
        
        let parser = AppleIPTVGuideXtreamParser()
        let programmes = parser.parseShortEPG(data: json.data(using: .utf8)!, streamID: "123")
        #expect(programmes.count == 1)
        #expect(programmes[0].title == "Test Title")
        #expect(programmes[0].description == "Test Desc")
    }

    @Test("Malformed input")
    func testMalformedInput() async throws {
        let json = "invalid json"
        let parser = AppleIPTVGuideXtreamParser()
        let programmes = parser.parseShortEPG(data: json.data(using: .utf8)!, streamID: "123")
        #expect(programmes.isEmpty)
        
        let xml = "<tv><programme></programme></tv>"
        let xmlParser = AppleIPTVGuideXMLTVParser()
        let xmlProgrammes = xmlParser.parse(data: xml.data(using: .utf8)!)
        #expect(xmlProgrammes.isEmpty)
    }
}

import XCTest
@testable import OpenStreamApple

final class AppleChannelLineupPresetsExtendedTests: XCTestCase {
    
    // We test the extended JSON file directly by decoding it,
    // since the production code currently hardcodes "premier-us.json".
    func testExtendedLineupValid() throws {
        let bundle = Bundle.module
        var url: URL?
        if let bundleURL = bundle.url(forResource: "premier-us-extended", withExtension: "json") {
            url = bundleURL
        } else if let bundleURL = bundle.url(forResource: "premier-us-extended", withExtension: "json", subdirectory: "ChannelLineup") {
            url = bundleURL
        } else {
            let thisFile = URL(fileURLWithPath: #filePath)
            url = thisFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/OpenStreamApple/Resources/ChannelLineup/premier-us-extended.json")
        }
        
        guard let finalURL = url else {
            XCTFail("Could not find premier-us-extended.json")
            return
        }
        
        let data = try Data(contentsOf: finalURL)
        
        // Define structures strictly to ensure it matches the schema
        struct DummyMarket: Codable, Equatable {
            let network: String?
            let region: String?
            
            init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(), let str = try? container.decode(String.self) {
                    self.region = str
                    self.network = nil
                } else if let container = try? decoder.container(keyedBy: CodingKeys.self), let network = try? container.decode(String.self, forKey: .network) {
                    self.network = network
                    self.region = nil
                } else {
                    self.region = nil
                    self.network = nil
                }
            }
            enum CodingKeys: String, CodingKey { case network }
        }
        
        struct DummyEntry: Codable {
            let number: Int
            let name: String
            let aliases: [String]
            let category: String
            let market: DummyMarket?
        }
        
        struct DummyFile: Codable {
            let channels: [DummyEntry]
            let markets: [String: String]
        }
        
        let decoded = try JSONDecoder().decode(DummyFile.self, from: data)
        XCTAssertGreaterThan(decoded.channels.count, 350, "Should have around 380 channels")
        
        // Test missing ranges
        let premiumHBO = decoded.channels.first { $0.number == 501 }
        XCTAssertNotNil(premiumHBO)
        XCTAssertEqual(premiumHBO?.name, "HBO East")
        
        let sportsFS1 = decoded.channels.first { $0.number == 600 }
        XCTAssertNotNil(sportsFS1)
        XCTAssertEqual(sportsFS1?.name, "Fox Sports 1")
        
        let intlUnivision = decoded.channels.first { $0.number == 402 }
        XCTAssertNotNil(intlUnivision)
        XCTAssertEqual(intlUnivision?.name, "Univision")
        
        let musicHitList = decoded.channels.first { $0.number == 801 }
        XCTAssertNotNil(musicHitList)
        XCTAssertEqual(musicHitList?.name, "Hit List")
        
        let ppvCinema = decoded.channels.first { $0.number == 125 }
        XCTAssertNotNil(ppvCinema)
        XCTAssertEqual(ppvCinema?.name, "Cinema 1")
    }
}

import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleAddonManifestIcon")
struct AppleAddonManifestIconTests {
    @Test("Extracts icon when both icon and logo are present")
    func extractsIconPreferably() throws {
        let manifest: [String: Any] = [
            "icon": "https://example.com/icon.png",
            "logo": "https://example.com/logo.png"
        ]
        let result = AppleAddonManifestIcon.extract(fromManifestDictionary: manifest)
        #expect(result?.url.absoluteString == "https://example.com/icon.png")
    }

    @Test("Extracts logo when icon is absent")
    func extractsLogoWhenIconAbsent() throws {
        let manifest: [String: Any] = [
            "logo": "https://example.com/logo.png"
        ]
        let result = AppleAddonManifestIcon.extract(fromManifestDictionary: manifest)
        #expect(result?.url.absoluteString == "https://example.com/logo.png")
    }

    @Test("Rejects non-HTTPS URLs")
    func rejectsNonHTTPS() throws {
        let manifest: [String: Any] = [
            "icon": "http://example.com/icon.png",
            "logo": "http://example.com/logo.png"
        ]
        let result = AppleAddonManifestIcon.extract(fromManifestDictionary: manifest)
        #expect(result == nil)
    }

    @Test("Rejects excessively long URLs")
    func rejectsLongURLs() throws {
        let longString = "https://example.com/" + String(repeating: "a", count: 1024) + ".png"
        let manifest: [String: Any] = [
            "icon": longString
        ]
        let result = AppleAddonManifestIcon.extract(fromManifestDictionary: manifest)
        #expect(result == nil)
    }

    @Test("Returns nil when neither are present")
    func returnsNilWhenAbsent() throws {
        let manifest: [String: Any] = [
            "name": "Some Addon"
        ]
        let result = AppleAddonManifestIcon.extract(fromManifestDictionary: manifest)
        #expect(result == nil)
    }
    
    @Test("Extracts from Data")
    func extractsFromData() throws {
        let jsonString = """
        {
            "logo": "https://example.com/logo.png"
        }
        """
        let data = Data(jsonString.utf8)
        let result = AppleAddonManifestIcon.extract(fromManifestData: data)
        #expect(result?.url.absoluteString == "https://example.com/logo.png")
    }
}

import Foundation
import Testing
@testable import OpenStreamApple

/// Settings → Streaming Services (owner 2026-09-28): an Add Service menu of
/// the region's ten most popular services instead of the whole directory.
@Suite("Streaming services add menu")
struct AppleWatchProviderAddMenuTests {
    private func entry(_ id: Int, priority: Int?, regional: [String: Int]? = nil) -> String {
        var fields = [#""provider_id":\#(id)"#, #""provider_name":"Service \#(id)""#]
        if let priority { fields.append(#""display_priority":\#(priority)"#) }
        if let regional {
            let pairs = regional.map { #""\#($0.key)":\#($0.value)"# }.joined(separator: ",")
            fields.append(#""display_priorities":{\#(pairs)}"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func directory(_ entries: [String], region: String? = "US") throws -> [AppleWatchProvider] {
        let json = #"{"results":[\#(entries.joined(separator: ","))]}"#
        let envelope = try JSONDecoder().decode(AppleWatchProviderResponse.DirectoryEnvelope.self, from: Data(json.utf8))
        return AppleWatchProviderResponse.directory(in: envelope, region: region)
    }

    @Test func theRegionsPriorityRanksTheDirectory() throws {
        let services = try directory([
            entry(1, priority: 1, regional: ["US": 30, "GB": 1]),
            entry(2, priority: 2, regional: ["US": 10]),
            entry(3, priority: 3, regional: ["US": 20]),
        ])
        #expect(services.map(\.id) == [2, 3, 1])
        #expect(try directory([entry(1, priority: 1, regional: ["US": 30, "GB": 1]), entry(2, priority: 2, regional: ["US": 10])],
                              region: "gb").map(\.id) == [1, 2])
    }

    @Test func aMissingPriorityKeepsTMDBsOrder() throws {
        let services = try directory([entry(5, priority: nil), entry(4, priority: nil), entry(6, priority: 1)])
        #expect(services.map(\.id) == [6, 5, 4])
    }

    @Test func theMenuOffersTheTopTenNotYetAdded() throws {
        let services = try directory((1...15).reversed().map { entry($0, priority: $0) })
        let menu = AppleWatchProviderPolicy.addable(services, enabledProviderIDs: [])
        #expect(menu.map(\.id) == Array(1...10))
        let afterAdding = AppleWatchProviderPolicy.addable(services, enabledProviderIDs: [2, 5])
        #expect(afterAdding.map(\.id) == [1, 3, 4, 6, 7, 8, 9, 10, 11, 12])
    }

    /// Nothing is lost from before the menu: an added service outside the top
    /// ten is still listed, and an id the directory does not know stays stored.
    @Test func addedServicesStayListedOutsideTheTopTen() throws {
        let services = try directory((1...15).map { entry($0, priority: $0) })
        let added = AppleWatchProviderPolicy.added(services, enabledProviderIDs: [14, 3, 999])
        #expect(added.map(\.id) == [3, 14])
        #expect(!AppleWatchProviderPolicy.addable(services, enabledProviderIDs: [14, 3]).contains { $0.id == 3 })
    }
}

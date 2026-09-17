// AppleChannelLineupPresetsTests.swift
// OpenStreamAppleTests
// Done / hooks needed: none
import Testing
import Foundation
@testable import OpenStreamApple

struct AppleChannelLineupPresetsTests {

    @Test("Tests JSON Loading and preset logic")
    func testPremierUS() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        #expect(entries.count >= 300)
    }

    @Test("Tests Exact name match")
    func testMatchExactName() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        let match = AppleChannelLineupPresets.match(channelName: "ESPN", in: entries)
        #expect(match?.number == 206)
    }

    @Test("Tests alias match")
    func testMatchAlias() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        let match = AppleChannelLineupPresets.match(channelName: "ESPN HD", in: entries)
        #expect(match?.number == 206)
    }

    @Test("Tests normalization US prefix")
    func testMatchUSPrefix() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        let match = AppleChannelLineupPresets.match(channelName: "US: CNN", in: entries)
        #expect(match?.number == 202)
    }

    @Test("Tests normalization suffix")
    func testMatchEastSuffix() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        let match = AppleChannelLineupPresets.match(channelName: "HBO East", in: entries)
        #expect(match?.number == 501)
    }
    
    @Test("Tests normalization of punctuation")
    func testMatchPunctuation() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        // 205 is Sports Mix in the real guide; Fox News Channel is 360.
        let match = AppleChannelLineupPresets.match(channelName: "Fox-News!", in: entries)
        #expect(match?.number == 360)
    }

    @Test("Tests local matching")
    func testLocalMatches() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        let chicagoMatches = AppleChannelLineupPresets.localMatches(zip: "60614", entries: entries)
        // Should include locals (which apply to all markets according to our simple model, or specifically Chicago)
        // AND the RSNs for Chicago
        let rsn = chicagoMatches.first { $0.number == 665 }
        #expect(rsn?.name == "NBC Sports Chicago")
        
        // Should not include Dallas RSN
        let dallasRSN = chicagoMatches.first { $0.number == 602 }
        #expect(dallasRSN == nil)
    }

    @Test("Unknown name returns nil")
    func testUnknownName() throws {
        let entries = try AppleChannelLineupPresets.premierUS()
        let match = AppleChannelLineupPresets.match(channelName: "Some Random Unknown Channel", in: entries)
        #expect(match == nil)
    }
}

import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleSharePlayChannelTests {
    private func channel(_ name: String, guideID: String? = nil, id: String = "local") -> AppleIPTVChannel {
        .init(id: id, sourceID: UUID(), name: name,
              streamURL: URL(string: "https://private.fixture.example/live/fixture-user/fixture-secret/123.ts")!,
              userAgent: "fixture-agent", referer: "https://private.fixture.example/account",
              guideID: guideID)
    }

    @Test func sharingAChannelNeverSerializesItsTransportOrAccountDetails() throws {
        let input = channel("Fixture News East", guideID: "fixture.news.east")
        let shared = try AppleSharePlayChannel(channel: input)
        let data = try JSONEncoder().encode(shared)
        let text = String(decoding: data, as: UTF8.self)
        for privateValue in ["private.fixture.example", "fixture-user", "fixture-secret", "fixture-agent", input.sourceID.uuidString, "fixture.news.east"] {
            #expect(!text.contains(privateValue))
        }
        #expect(try JSONDecoder().decode(AppleSharePlayChannel.self, from: data) == shared)
        #expect(shared.title == "Fixture News East")
    }

    @Test func participantsResolveTheirOwnChannelWithoutSharingSourceIDs() throws {
        let shared = try AppleSharePlayChannel(channel: channel("Fixture News East", guideID: "fixture.east"))
        let otherProvider = channel("  FIXTURE  NEWS EAST ", guideID: "different-provider-key", id: "participant-local-id")
        let west = channel("Fixture News West", guideID: "fixture.west", id: "west")
        #expect(shared.candidates(in: [west, otherProvider]).map(\.id) == ["participant-local-id"])
        #expect(shared.candidates(in: [west]).isEmpty)
    }

    @Test func aMatchingGuideKeyDisambiguatesFeedsButNeverOverridesTheTitle() throws {
        let shared = try AppleSharePlayChannel(channel: channel("Fixture News East", guideID: "fixture.east"))
        let wrongTitle = channel("Fixture News West", guideID: "fixture.east", id: "wrong-title")
        let exact = channel("Fixture News East", guideID: "fixture.east", id: "correct")
        let ambiguous = channel("Fixture News East", guideID: "other", id: "other")
        #expect(shared.candidates(in: [wrongTitle, ambiguous, exact]).map(\.id) == ["correct"])
        #expect(shared.candidates(in: [wrongTitle]).isEmpty)
    }

    @Test func ambiguousLocalMatchesRemainExplicitChoices() throws {
        let shared = try AppleSharePlayChannel(channel: channel("Fixture News"))
        let choices = [channel("Fixture News", id: "first"), channel("Fixture News", id: "second")]
        #expect(shared.candidates(in: choices).map(\.id) == ["first", "second"])
    }

    @Test func unsafeNamesAndUntrustedSessionPayloadsAreRejected() throws {
        for name in ["", String(repeating: "a", count: 201), "https://fixture.example/private", "fixture@example.com", "token=fixture-secret", "Fixture\u{0}News"] {
            #expect(throws: AppleSharePlayChannel.ValidationError.self) {
                try AppleSharePlayChannel(channel: channel(name))
            }
        }
        let shared = try AppleSharePlayChannel(channel: channel("Fixture News"))
        let encoded = try JSONEncoder().encode(shared)
        var value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        value["version"] = 999
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppleSharePlayChannel.self, from: JSONSerialization.data(withJSONObject: value))
        }
        value["version"] = 1
        value["channelKey"] = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppleSharePlayChannel.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }
}

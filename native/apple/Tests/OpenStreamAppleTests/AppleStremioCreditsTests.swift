import Foundation
import Testing
@testable import OpenStreamApple

/// Cast & Crew pictures from Stremio meta responses (N37). The plain `cast`
/// list is names only, so these come from `app_extras` or `credits_cast`.
struct AppleStremioCreditsTests {
    private static let source = AppleSource(
        kind: .stremio, name: "Meta",
        url: URL(string: "https://fixture.example/manifest.json")!,
        manifestID: "meta", resources: ["meta"]
    )

    private static func details(_ meta: String, source: AppleSource = source) async throws -> AppleTMDBDetails {
        let client = AppleStremioMetadataClient { request in
            (Data(meta.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return try await client.details(source: source, type: "movie", mediaID: "tt0000001")
    }

    @Test func appExtrasGivesEveryPersonWithAPhotoTheirPortrait() async throws {
        let details = try await Self.details(#"""
        {"meta":{"id":"tt0000001","type":"movie","name":"Fixture Film",
          "cast":["Ada Actor","Ben Actor"],"director":["Dee Director"],"writer":["Wes Writer"],
          "app_extras":{
            "cast":[{"name":"Ada Actor","character":"Heroine","photo":"https://image.tmdb.org/t/p/w276_and_h350_face/ada.jpg"},
                    {"name":"Ben Actor","character":"Sidekick"},
                    {"character":"No name, skipped"},
                    {"name":"Cy Actor","photo":"http://image.tmdb.org/t/p/w276_and_h350_face/cy.jpg"}],
            "directors":[{"name":"Dee Director","photo":"https://image.tmdb.org/t/p/w276_and_h350_face/dee.jpg"}],
            "writers":[{"name":"Wes Writer","photo":"not a url"}]
          }}}
        """#)

        #expect(details.cast == ["Ada Actor", "Ben Actor"])
        #expect(details.castMembers == [
            AppleCreditPerson(name: "Ada Actor", role: "Heroine",
                              portraitURL: URL(string: "https://image.tmdb.org/t/p/w276_and_h350_face/ada.jpg")),
            AppleCreditPerson(name: "Ben Actor", role: "Sidekick"),
            // An http picture is asked for over https.
            AppleCreditPerson(name: "Cy Actor",
                              portraitURL: URL(string: "https://image.tmdb.org/t/p/w276_and_h350_face/cy.jpg")),
            AppleCreditPerson(name: "Dee Director", role: "Director",
                              portraitURL: URL(string: "https://image.tmdb.org/t/p/w276_and_h350_face/dee.jpg")),
            AppleCreditPerson(name: "Wes Writer", role: "Writer"),
        ])
    }

    @Test func tmdbStyleCreditsCastUsesTheProfilePath() async throws {
        let details = try await Self.details(#"""
        {"meta":{"id":"tt0000001","type":"movie","name":"Fixture Film",
          "credits_cast":[{"name":"Ada Actor","character":"Heroine","profile_path":"/ada.jpg"},
                          {"name":"Ben Actor","character":"Sidekick","profile_path":null}],
          "credits_crew":[{"name":"Dee Director","job":"Director","department":"Directing","profile_path":"/dee.jpg"},
                          {"name":"Gaffer Person","job":"Gaffer","department":"Lighting","profile_path":"/g.jpg"}]}}
        """#)

        #expect(details.castMembers == [
            AppleCreditPerson(name: "Ada Actor", role: "Heroine",
                              portraitURL: URL(string: "https://image.tmdb.org/t/p/h632/ada.jpg")),
            AppleCreditPerson(name: "Ben Actor", role: "Sidekick"),
            AppleCreditPerson(name: "Dee Director", role: "Director",
                              portraitURL: URL(string: "https://image.tmdb.org/t/p/h632/dee.jpg")),
        ])
    }

    @Test func namesOnlyMetaStillFallsBackToInitials() async throws {
        let details = try await Self.details(#"""
        {"meta":{"id":"tt0000001","type":"movie","name":"Fixture Film","cast":["Ada Actor"],"app_extras":{"cast":"garbage"}}}
        """#)

        #expect(details.castMembers.isEmpty)
        let credits = AppleTitlePagePolicy.credits(detailed: details.castMembers, cast: details.cast,
                                                   director: nil, writers: [])
        #expect(credits == [AppleCreditPerson(name: "Ada Actor", role: "Actor")])
        #expect(credits.first?.portraitURL == nil)
    }

    @Test func theRecordedTMDBAddOnMetaCarriesPortraits() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/addon-tmdb-meta-movie.json")
        let body = try Data(contentsOf: url)
        let client = AppleStremioMetadataClient { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let details = try await client.details(source: Self.source, type: "movie", mediaID: "tmdb:969681")

        #expect(details.castMembers.count == 5)
        #expect(details.castMembers.allSatisfy { $0.portraitURL?.host == "image.tmdb.org" })
        #expect(details.castMembers.first?.role == "Peter Parker / Spider-Man")
    }

    @Test func aPortraitMissingFromTheWinningSourceIsFilledFromAnother() async throws {
        let preferred = AppleSource(kind: .stremio, name: "Preferred",
                                    url: URL(string: "https://preferred.fixture.example/manifest.json")!,
                                    manifestID: "preferred", resources: ["meta"])
        let secondary = AppleSource(kind: .stremio, name: "Secondary",
                                    url: URL(string: "https://secondary.fixture.example/manifest.json")!,
                                    manifestID: "secondary", resources: ["meta"])
        let resolver = AppleMetadataResolver(
            sourceClient: AppleStremioMetadataClient { request in
                let body = request.url?.host == "preferred.fixture.example"
                    ? #"{"meta":{"id":"tt0000001","type":"movie","name":"Fixture Film","app_extras":{"cast":[{"name":"Ada Actor","character":"Heroine"},{"name":"Ben Actor"}]}}}"#
                    : #"{"meta":{"id":"tt0000001","type":"movie","name":"Fixture Film","app_extras":{"cast":[{"name":"ada actor","photo":"https://image.tmdb.org/t/p/w185/ada.jpg"}]}}}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            overallDeadline: .seconds(5),
            defaultSource: secondary
        )

        let details = try await resolver.resolve(sources: [preferred, secondary], preferredSourceID: preferred.id,
                                                 type: "movie", mediaID: "tt0000001")

        #expect(details?.castMembers == [
            AppleCreditPerson(name: "Ada Actor", role: "Heroine",
                              portraitURL: URL(string: "https://image.tmdb.org/t/p/h632/ada.jpg")),
            AppleCreditPerson(name: "Ben Actor"),
        ])
    }

    /// Thumbnails upscaled into blurry circles (owner, 2026-09-25); larger
    /// sizes, face crops and other hosts are left as sent.
    @Test func tmdbThumbnailsAreAskedForAtThePortraitSize() {
        #expect(AppleCreditPerson.sharpTMDBPortraitPath("/t/p/w185/a.jpg") == "/t/p/h632/a.jpg")
        #expect(AppleCreditPerson.sharpTMDBPortraitPath("/t/p/w45/a.jpg") == "/t/p/h632/a.jpg")
        #expect(AppleCreditPerson.sharpTMDBPortraitPath("/t/p/w276_and_h350_face/a.jpg") == "/t/p/w276_and_h350_face/a.jpg")
        #expect(AppleCreditPerson.sharpTMDBPortraitPath("/t/p/original/a.jpg") == "/t/p/original/a.jpg")
        #expect(AppleCreditPerson.sharpTMDBPortraitPath("/photos/w185/a.jpg") == "/photos/w185/a.jpg")
    }

    @Test func fillingPortraitsLeavesPeopleWithAPictureAlone() {
        let own = URL(string: "https://image.tmdb.org/t/p/w185/own.jpg")
        let other = URL(string: "https://image.tmdb.org/t/p/w185/other.jpg")
        let people = [AppleCreditPerson(name: "Ada Actor", portraitURL: own), AppleCreditPerson(name: "Ben Actor")]
        let filled = AppleTitlePagePolicy.fillingPortraits(people, from: [
            AppleCreditPerson(name: "Ada Actor", portraitURL: other),
            AppleCreditPerson(name: "Ben Actor", portraitURL: other),
        ])
        #expect(filled.map(\.portraitURL) == [own, other])
    }
}

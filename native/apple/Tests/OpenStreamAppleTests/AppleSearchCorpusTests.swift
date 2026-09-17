import Foundation
import Testing
@testable import OpenStreamApple

/// A 206-title corpus spanning 1927–2025, movies and series, chosen to include
/// the shapes that break naive matching: one-word titles ("It", "Up", "Us",
/// "Her", "M", "9"), punctuation ("WALL·E", "M*A*S*H", "S.H.I.E.L.D."),
/// diacritics ("Amélie", "Shōgun", "Léon"), digits in titles ("Se7en", "1917",
/// "12 Angry Men", "2001"), ampersands ("Law & Order"), and the same title in
/// two eras ("It" 1990 and 2017).
///
/// Owner asked for a real sample rather than a handful of cases: "search for at
/// least 200 shows and movies all from different eras".
@MainActor
@Suite("Search corpus, 1927–2025")
struct AppleSearchCorpusTests {
    private static let corpus: [(String, Int, AppleMediaKind)] = [
        ("Metropolis", 1927, .movie),
        ("The Jazz Singer", 1927, .movie),
        ("M", 1931, .movie),
        ("King Kong", 1933, .movie),
        ("It Happened One Night", 1934, .movie),
        ("Modern Times", 1936, .movie),
        ("Snow White and the Seven Dwarfs", 1937, .movie),
        ("The Wizard of Oz", 1939, .movie),
        ("Gone with the Wind", 1939, .movie),
        ("Citizen Kane", 1941, .movie),
        ("Casablanca", 1942, .movie),
        ("Double Indemnity", 1944, .movie),
        ("It's a Wonderful Life", 1946, .movie),
        ("The Third Man", 1949, .movie),
        ("Sunset Boulevard", 1950, .movie),
        ("Rashomon", 1950, .movie),
        ("Singin' in the Rain", 1952, .movie),
        ("Seven Samurai", 1954, .movie),
        ("Rear Window", 1954, .movie),
        ("12 Angry Men", 1957, .movie),
        ("Vertigo", 1958, .movie),
        ("Some Like It Hot", 1959, .movie),
        ("Psycho", 1960, .movie),
        ("La Dolce Vita", 1960, .movie),
        ("West Side Story", 1961, .movie),
        ("Lawrence of Arabia", 1962, .movie),
        ("Dr. Strangelove", 1964, .movie),
        ("The Good, the Bad and the Ugly", 1966, .movie),
        ("2001: A Space Odyssey", 1968, .movie),
        ("The Twilight Zone", 1959, .series),
        ("Star Trek", 1966, .series),
        ("Doctor Who", 1963, .series),
        ("The Godfather", 1972, .movie),
        ("The Exorcist", 1973, .movie),
        ("Chinatown", 1974, .movie),
        ("Jaws", 1975, .movie),
        ("Taxi Driver", 1976, .movie),
        ("Star Wars", 1977, .movie),
        ("Alien", 1979, .movie),
        ("Apocalypse Now", 1979, .movie),
        ("Monty Python's Flying Circus", 1969, .series),
        ("M*A*S*H", 1972, .series),
        ("Columbo", 1971, .series),
        ("The Shining", 1980, .movie),
        ("Blade Runner", 1982, .movie),
        ("E.T. the Extra-Terrestrial", 1982, .movie),
        ("The Thing", 1982, .movie),
        ("Scarface", 1983, .movie),
        ("The Terminator", 1984, .movie),
        ("Back to the Future", 1985, .movie),
        ("Aliens", 1986, .movie),
        ("Die Hard", 1988, .movie),
        ("Akira", 1988, .movie),
        ("Cheers", 1982, .series),
        ("Twin Peaks", 1990, .series),
        ("The Simpsons", 1989, .series),
        ("Seinfeld", 1989, .series),
        ("Goodfellas", 1990, .movie),
        ("Terminator 2: Judgment Day", 1991, .movie),
        ("The Silence of the Lambs", 1991, .movie),
        ("Jurassic Park", 1993, .movie),
        ("Schindler's List", 1993, .movie),
        ("Pulp Fiction", 1994, .movie),
        ("The Lion King", 1994, .movie),
        ("Se7en", 1995, .movie),
        ("Heat", 1995, .movie),
        ("Toy Story", 1995, .movie),
        ("Fargo", 1996, .movie),
        ("Titanic", 1997, .movie),
        ("The Big Lebowski", 1998, .movie),
        ("The Matrix", 1999, .movie),
        ("Fight Club", 1999, .movie),
        ("The Sixth Sense", 1999, .movie),
        ("Friends", 1994, .series),
        ("The X-Files", 1993, .series),
        ("ER", 1994, .series),
        ("Buffy the Vampire Slayer", 1997, .series),
        ("The Sopranos", 1999, .series),
        ("Futurama", 1999, .series),
        ("Amélie", 2001, .movie),
        ("Donnie Darko", 2001, .movie),
        ("Spirited Away", 2001, .movie),
        ("The Lord of the Rings: The Fellowship of the Ring", 2001, .movie),
        ("City of God", 2002, .movie),
        ("Oldboy", 2003, .movie),
        ("Lost in Translation", 2003, .movie),
        ("Eternal Sunshine of the Spotless Mind", 2004, .movie),
        ("Sin City", 2005, .movie),
        ("Pan's Labyrinth", 2006, .movie),
        ("The Departed", 2006, .movie),
        ("Children of Men", 2006, .movie),
        ("No Country for Old Men", 2007, .movie),
        ("There Will Be Blood", 2007, .movie),
        ("WALL·E", 2008, .movie),
        ("The Dark Knight", 2008, .movie),
        ("Up", 2009, .movie),
        ("District 9", 2009, .movie),
        ("Avatar", 2009, .movie),
        ("The Wire", 2002, .series),
        ("Firefly", 2002, .series),
        ("Arrested Development", 2003, .series),
        ("Lost", 2004, .series),
        ("House", 2004, .series),
        ("The Office", 2005, .series),
        ("Dexter", 2006, .series),
        ("Mad Men", 2007, .series),
        ("Breaking Bad", 2008, .series),
        ("Fringe", 2008, .series),
        ("Community", 2009, .series),
        ("Archer", 2009, .series),
        ("Inception", 2010, .movie),
        ("Black Swan", 2010, .movie),
        ("Drive", 2011, .movie),
        ("The Artist", 2011, .movie),
        ("Skyfall", 2012, .movie),
        ("Django Unchained", 2012, .movie),
        ("Her", 2013, .movie),
        ("Gravity", 2013, .movie),
        ("12 Years a Slave", 2013, .movie),
        ("Whiplash", 2014, .movie),
        ("Interstellar", 2014, .movie),
        ("Birdman", 2014, .movie),
        ("Mad Max: Fury Road", 2015, .movie),
        ("The Revenant", 2015, .movie),
        ("Ex Machina", 2014, .movie),
        ("Arrival", 2016, .movie),
        ("Moonlight", 2016, .movie),
        ("La La Land", 2016, .movie),
        ("Get Out", 2017, .movie),
        ("Blade Runner 2049", 2017, .movie),
        ("Dunkirk", 2017, .movie),
        ("Coco", 2017, .movie),
        ("Roma", 2018, .movie),
        ("Spider-Man: Into the Spider-Verse", 2018, .movie),
        ("Parasite", 2019, .movie),
        ("1917", 2019, .movie),
        ("Joker", 2019, .movie),
        ("Us", 2019, .movie),
        ("Sherlock", 2010, .series),
        ("Game of Thrones", 2011, .series),
        ("Black Mirror", 2011, .series),
        ("Peaky Blinders", 2013, .series),
        ("True Detective", 2014, .series),
        ("Better Call Saul", 2015, .series),
        ("Stranger Things", 2016, .series),
        ("The Crown", 2016, .series),
        ("Westworld", 2016, .series),
        ("Fleabag", 2016, .series),
        ("The Good Place", 2016, .series),
        ("Dark", 2017, .series),
        ("Killing Eve", 2018, .series),
        ("Succession", 2018, .series),
        ("Chernobyl", 2019, .series),
        ("The Mandalorian", 2019, .series),
        ("Watchmen", 2019, .series),
        ("Tenet", 2020, .movie),
        ("Soul", 2020, .movie),
        ("Nomadland", 2020, .movie),
        ("Dune", 2021, .movie),
        ("No Time to Die", 2021, .movie),
        ("The Power of the Dog", 2021, .movie),
        ("Everything Everywhere All at Once", 2022, .movie),
        ("Top Gun: Maverick", 2022, .movie),
        ("The Banshees of Inisherin", 2022, .movie),
        ("Nope", 2022, .movie),
        ("Oppenheimer", 2023, .movie),
        ("Barbie", 2023, .movie),
        ("Poor Things", 2023, .movie),
        ("Past Lives", 2023, .movie),
        ("Dune: Part Two", 2024, .movie),
        ("Anora", 2024, .movie),
        ("The Substance", 2024, .movie),
        ("Conclave", 2024, .movie),
        ("Ted Lasso", 2020, .series),
        ("The Queen's Gambit", 2020, .series),
        ("Bridgerton", 2020, .series),
        ("Squid Game", 2021, .series),
        ("Arcane", 2021, .series),
        ("Severance", 2022, .series),
        ("The Bear", 2022, .series),
        ("Andor", 2022, .series),
        ("House of the Dragon", 2022, .series),
        ("The Last of Us", 2023, .series),
        ("Beef", 2023, .series),
        ("Shōgun", 2024, .series),
        ("Baby Reindeer", 2024, .series),
        ("Ripley", 2024, .series),
        ("Fallout", 2024, .series),
        ("The Penguin", 2024, .series),
        ("Adolescence", 2025, .series),
        ("It", 1990, .series),
        ("It", 2017, .movie),
        ("9", 2009, .movie),
        ("Æon Flux", 2005, .movie),
        ("Rogue One", 2016, .movie),
        ("Ocean's Eleven", 2001, .movie),
        ("Marvel's Agents of S.H.I.E.L.D.", 2013, .series),
        ("Law & Order", 1990, .series),
        ("Star Wars: Episode V - The Empire Strikes Back", 1980, .movie),
        ("Léon: The Professional", 1994, .movie),
        ("Amadeus", 1984, .movie),
        ("Ran", 1985, .movie),
        ("Brazil", 1985, .movie),
        ("Saw", 2004, .movie),
        ("Cars", 2006, .movie),
        ("Room", 2015, .movie)
    ]

    private func availability() -> [AppleMediaAvailability] {
        [AppleMediaAvailability(instanceID: UUID(), capability: .direct,
                                itemReference: "ref", lastVerified: .now)]
    }

    /// Every record carries a plausible IMDb id, because the id is part of what
    /// the matcher searches and that turns out to matter.
    private func records() -> [AppleMediaRecord] {
        Self.corpus.enumerated().map { index, entry in
            AppleMediaRecord(
                canonicalID: String(format: "tt%07d", 100000 + index * 7),
                kind: entry.2, title: entry.0, year: entry.1,
                availability: availability())
        }
    }

    private func search(_ query: String) -> [AppleMediaRecord] {
        AppleCatalogSearchStore.mergedResults(records(), matching: query, limit: 500)
    }

    /// Recall: every title in the corpus must find itself.
    @Test func everyTitleFindsItself() {
        let all = records()
        var missed: [String] = []
        for entry in Self.corpus {
            let hits = AppleCatalogSearchStore.mergedResults(all, matching: entry.0, limit: 500)
            if !hits.contains(where: { $0.title == entry.0 }) { missed.append(entry.0) }
        }
        #expect(missed.isEmpty, "\(missed.count) titles could not find themselves: \(missed.prefix(12))")
    }

    /// Precision: a one-word title must not drag in every title that merely
    /// contains those letters. "Her" inside "Sherlock" is the canonical case.
    @Test func aShortTitleDoesNotMatchTitlesThatMerelyContainIt() {
        let cases: [(query: String, mustNotReturn: String)] = [
            ("Her", "Sherlock"),
            ("It", "Spirited Away"),
            ("Up", "Succession"),
            ("Us", "Succession"),
            ("Ran", "Stranger Things"),
            ("Saw", "Star Wars"),
        ]
        var wrong: [String] = []
        for c in cases {
            let titles = search(c.query).map(\.title)
            if titles.contains(c.mustNotReturn) { wrong.append("\(c.query) → \(c.mustNotReturn)") }
        }
        #expect(wrong.isEmpty, "substring matches leaked through: \(wrong)")
    }

    /// A short query must not return a flood. "It" legitimately matches two
    /// titles in this corpus; it should not match dozens.
    @Test func aShortQueryReturnsAHandfulNotAFlood() {
        let hits = search("It")
        #expect(hits.count <= 6, "\"It\" returned \(hits.count) results: \(hits.prefix(10).map(\.title))")
    }

    /// The matcher searches the canonical id too, so a digit string can match a
    /// title by its IMDb number rather than by its name.
    @Test func aNumericQueryDoesNotMatchByIMDbId() {
        let all = records()
        let victim = all[3]
        let digits = String(victim.canonicalID!.dropFirst(2).drop(while: { $0 == "0" }))
        let hits = AppleCatalogSearchStore.mergedResults(all, matching: digits, limit: 500)
        #expect(!hits.contains { $0.title == victim.title },
                "query \"\(digits)\" matched \(victim.title) through its IMDb id")
    }

    /// Titles differing only by era must both survive; they are different works.
    @Test func theSameTitleInTwoErasStaysTwoResults() {
        let hits = search("It").filter { $0.title == "It" }
        #expect(hits.count == 2, "expected the 1990 series and the 2017 film, got \(hits.count)")
    }

    /// People disambiguate by year — "dune 2021", "it 2017" — which is exactly
    /// how you tell two versions of one title apart.
    @Test func aYearInTheQueryNarrowsRatherThanKills() {
        let dune = search("Dune 2021").map(\.title)
        #expect(dune.contains("Dune"), "\"Dune 2021\" found \(dune)")

        // The case that matters most: the corpus holds It (1990) and It (2017).
        let it2017 = search("It 2017")
        #expect(it2017.contains { $0.title == "It" && $0.year == 2017 },
                "\"It 2017\" did not find the 2017 film")
        #expect(!it2017.contains { $0.title == "It" && $0.year == 1990 },
                "\"It 2017\" also returned the 1990 series")
    }

    /// Relevance: typing a title exactly should put that title first.
    ///
    /// Results are ordered alphabetically by title, which has no notion of
    /// relevance at all — so a longer title can outrank the exact one the
    /// viewer typed.
    @Test func anExactTitleComesFirst() {
        let cases = [("Dune", "Dune"), ("Star Wars", "Star Wars"),
                     ("Alien", "Alien"), ("It", "It"), ("Up", "Up")]
        var wrong: [String] = []
        for (query, expected) in cases {
            let first = search(query).first?.title
            if first != expected { wrong.append("\(query) → \(first ?? "nothing")") }
        }
        #expect(wrong.isEmpty, "the exact title was not first: \(wrong)")
    }

    /// The live-results version of `anExactTitleComesFirst`.
    ///
    /// Owner review on the phone, 2026-09-17: typing "Dune" listed *Be Dune
    /// Teen*, *Children of Dune* and *Destination Dune* above *Dune*. Every one
    /// of those genuinely matches — "Dune" begins a word in each — and B, C and
    /// D-e all sort before D-u, so alphabetical order buried the exact match.
    /// The 206-title corpus has no decoy shaped like that, which is exactly why
    /// `anExactTitleComesFirst` passed while the app was wrong.
    @Test func aDecoyThatSortsFirstDoesNotOutrankTheExactTitle() {
        let titles = ["Be Dune Teen", "Children of Dune", "Destination Dune",
                      "Dune", "Dune: Part Two"]
        let decoys = titles.enumerated().map { index, title in
            AppleMediaRecord(
                canonicalID: String(format: "tt90000%02d", index),
                kind: .movie, title: title, year: 1984 + index,
                availability: availability())
        }
        let hits = AppleCatalogSearchStore
            .mergedResults(decoys, matching: "Dune", limit: 500)
            .map(\.title)
        #expect(hits.first == "Dune", "\"Dune\" was not first: \(hits)")
        #expect(hits == ["Dune", "Dune: Part Two", "Be Dune Teen",
                         "Children of Dune", "Destination Dune"],
                "unexpected order: \(hits)")
    }

    /// A title that *starts with* the query should outrank one that merely
    /// contains it later on.
    @Test func aTitleStartingWithTheQueryOutranksOneThatDoesNot() {
        let hits = search("Dune").map(\.title)
        guard let dune = hits.firstIndex(of: "Dune"),
              let part2 = hits.firstIndex(of: "Dune: Part Two") else {
            Issue.record("expected both Dune titles, got \(hits)")
            return
        }
        #expect(dune < part2, "Dune: Part Two outranked Dune")
    }

    /// Diacritics, punctuation and digits must all be findable as typed plainly.
    @Test func awkwardTitlesAreStillFindable() {
        let checks = [("Amelie", "Amélie"), ("WALL E", "WALL·E"), ("MASH", "M*A*S*H"),
                      ("Shogun", "Shōgun"), ("Leon", "Léon: The Professional"),
                      ("Law and Order", "Law & Order")]
        var missed: [String] = []
        for (query, title) in checks where !search(query).contains(where: { $0.title == title }) {
            missed.append("\(query) → \(title)")
        }
        #expect(missed.isEmpty, "not findable: \(missed)")
    }
}

import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleNetflixTop10 Tests")
struct AppleNetflixTop10Tests {
    
    @Test("Parse inline TSV fixture")
    func testParseTSV() async throws {
        let tsv = """
        country_name\tcountry_iso2\tweek\tcategory\tweekly_rank\tshow_title\tseason_title
        United States\tUS\t2026-09-01\tFilms\t1\tThe Big Movie\tN/A
        United States\tUS\t2026-09-01\tTV\t1\tThe Big Show\tSeason 1
        United States\tUS\t2026-08-25\tFilms\t1\tOld Movie\tN/A
        United Kingdom\tGB\t2026-09-01\tFilms\t1\tUK Movie\tN/A
        """
        
        // Setup mock URLProtocol to return the fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, tsv.data(using: .utf8)!)
        }
        
        let client = AppleNetflixTop10Client(session: session, country: "US")
        let result = try await client.latestWeek()
        
        #expect(result.films.count == 1)
        #expect(result.films[0].title == "The Big Movie")
        #expect(result.films[0].rank == 1)
        #expect(result.films[0].category == "movie")
        
        #expect(result.tv.count == 1)
        #expect(result.tv[0].title == "The Big Show")
        #expect(result.tv[0].seasonTitle == "Season 1")
        #expect(result.tv[0].category == "series")
    }

}

class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is unavailable.")
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

@Test func netflixStreamingParserKeepsOnlyNewestWeekWithUnsortedRows() throws {
    var parser = AppleNetflixTop10Parser(country: "US")
    try parser.consume("country_iso2\tweek\tcategory\tweekly_rank\tshow_title\tseason_title")
    for n in 0..<10_000 {
        try parser.consume("US\t2026-08-01\tFilms\t1\tOld \(n)\tN/A")
    }
    try parser.consume("US\t2026-09-01\tFilms\t2\tSecond\tN/A")
    try parser.consume("US\t2026-08-01\tFilms\t1\tOld\tN/A")
    try parser.consume("GB\t2026-09-08\tFilms\t1\tForeign\tN/A")
    try parser.consume("US\t2026-09-01\tFilms\t1\tFirst\tN/A")
    try parser.consume("US\t2026-09-01\tFilms\t1\tDuplicate\tN/A")
    try parser.consume("US\t2026-09-01\tTV\t1\tShow\tSeason 1")
    let result = try parser.finish()
    #expect(result.films.map(\.title) == ["First", "Second"])
    #expect(result.tv.map(\.title) == ["Show"])
}

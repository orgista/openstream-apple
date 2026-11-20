import Foundation

final class AppleSphericalByteSource: Sendable {
    let url: URL
    private let client: AppleBoundedHTTPClient

    init(url: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.url = url
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        client = AppleBoundedHTTPClient(configuration: configuration)
    }

    func cancel() { client.invalidateAndCancel() }

    func size() async throws -> Int64 {
        try Task.checkCancellation()
        if url.isFileURL {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw URLError(.cannotOpenFile) }
            return Int64(size)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await client.load(request, maximumBytes: 1, redirectPolicy: .follow, behavior: .returnPrefix)
        if let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, probe) = try await client.load(request, maximumBytes: 1, redirectPolicy: .follow, behavior: .returnPrefix)
        guard let http = probe as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 206,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 { return total }
        if http.statusCode == 200, probe.expectedContentLength > 0 { return probe.expectedContentLength }
        throw URLError(.badServerResponse)
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, !range.isEmpty,
              range.count <= AppleSphericalAssetBytes.chunkSize else { throw URLError(.badURL) }
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            return try handle.read(upToCount: Int(range.count)) ?? Data()
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await client.load(request, maximumBytes: range.count,
                                                     redirectPolicy: .follow, behavior: .rejectOverflow)
        guard let http = response as? HTTPURLResponse, !bytes.isEmpty else { throw URLError(.badServerResponse) }
        if http.statusCode == 200, range.lowerBound == 0,
           bytes.count == response.expectedContentLength { return bytes }
        guard http.statusCode == 206,
              let header = http.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes "),
              let span = header.dropFirst(6).split(separator: "/").first?.split(separator: "-"), span.count == 2,
              let first = Int64(span[0]), let last = Int64(span[1]),
              first == range.lowerBound, last < range.upperBound, last >= first,
              last - first + 1 == bytes.count else { throw URLError(.badServerResponse) }
        return bytes
    }
}

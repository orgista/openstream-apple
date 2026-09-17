import Testing
import Foundation
@testable import OpenStreamApple

@Suite("AppleWebUploadHandler Tests")
struct AppleWebUploadHandlerTests {

    @Test("Multipart parsing of a two-part body")
    func testMultipartParsing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "legacy-upload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = AppleWebUploadHandler(directory: directory)
        let boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        let contentType = "multipart/form-data; boundary=\(boundary)"
        let bodyString = """
        --\(boundary)\r
        Content-Disposition: form-data; name="file"; filename="test_video.mp4"\r
        Content-Type: video/mp4\r
        \r
        fakevideodata\r
        --\(boundary)--\r
        """
        let bodyData = bodyString.data(using: .utf8)!
        
        let result = try await handler.handleUpload(body: bodyData, fileNameHeader: nil, contentType: contentType)
        #expect(result.status == 200)
        
        // Let's verify the file was actually written properly
        let fm = FileManager.default
        let fileURL = directory.appendingPathComponent("test_video.mp4")
        
        #expect(fm.fileExists(atPath: fileURL.path))
        let writtenData = try Data(contentsOf: fileURL)
        #expect(String(data: writtenData, encoding: .utf8) == "fakevideodata")
        
        try fm.removeItem(at: fileURL)
    }

    @Test("Filename sanitization (../ rejected)")
    func testFilenameSanitization() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "legacy-upload-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = AppleWebUploadHandler(directory: directory)
        let result = try await handler.handleUpload(body: Data([1]), fileNameHeader: "../secret.txt", contentType: nil)
        #expect(result.status == 400)
    }

    @Test("Cap exceeded -> 413")
    func testCapExceeded() async throws {
        let handler = AppleWebUploadHandler(maxBytes: 10) // 10 bytes cap
        let data = Data(repeating: 0, count: 20)
        let result = try await handler.handleUpload(body: data, fileNameHeader: "test.mp4", contentType: nil)
        #expect(result.status == 413)
    }
}

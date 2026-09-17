import Foundation
import Testing
@testable import OpenStreamApple

@Test func uploadPreservesBytesDoesNotOverwriteAndRejectsUnsafeFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "upload-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let handler = AppleWebUploadHandler(maxBytes: 64, directory: directory)
    let data = Data([0, 255, 1, 2, 13, 10])
    for _ in 0..<2 {
        let response = try await handler.handleUpload(body: data, fileNameHeader: "sample.mp4", contentType: "application/octet-stream")
        #expect(response.status == 200)
        #expect((try JSONSerialization.jsonObject(with: Data(response.responseBody.utf8)) as? [String: Any])?["success"] as? Bool == true)
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    for file in files { #expect(try Data(contentsOf: file) == data) }
    for name in ["../sample.mp4", "%2Fsample.mp4", "sample.txt", "sample%00.mp4"] {
        #expect(try await handler.handleUpload(body: data, fileNameHeader: name, contentType: nil).status == 400)
    }
    #expect(try await handler.handleUpload(body: Data(repeating: 0, count: 65), fileNameHeader: "sample.mp4", contentType: nil).status == 413)
    #expect(try await handler.handleUpload(body: data, fileNameHeader: "sample.mp4", contentType: "multipart/form-data").status == 415)
    #expect(!AppleWebUploadPage.html().contains("?token="))
    #expect(AppleWebUploadPage.html().contains("xhr.send(file)"))
}

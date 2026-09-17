import Foundation

public struct AppleWebUploadPage {
    public static func html(nonce: String = UUID().uuidString) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <title>Upload Video</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { --bg: #000; --surface: #1c1c1e; --text: #fff; --brand: #ff3366; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); padding: 20px; max-width: 600px; margin: 0 auto; }
          .card { background: var(--surface); padding: 24px; border-radius: 16px; }
          h1 { margin-top: 0; font-size: 24px; }
          .file-input { margin-bottom: 20px; }
          button { background: var(--text); color: var(--bg); border: none; padding: 12px 24px; border-radius: 24px; font-weight: bold; cursor: pointer; width: 100%; }
          .progress-container { width: 100%; background: #333; border-radius: 8px; margin-top: 20px; overflow: hidden; display: none; }
          .progress-bar { width: 0%; height: 8px; background: var(--text); transition: width 0.2s; }
          .status { margin-top: 12px; font-size: 14px; text-align: center; color: #aaa; }
        </style>
        </head>
        <body>
          <div class="card">
              <h1>Upload Media</h1>
              <form id="uploadForm">
                <input type="file" id="fileInput" name="file" accept="video/*" class="file-input" required />
                <button type="submit">Upload File</button>
              </form>
              <div id="progress-container" class="progress-container"><div id="progress-bar" class="progress-bar"></div></div>
              <div id="status" class="status"></div>
          </div>
          <script nonce="\(nonce)">
            document.getElementById('uploadForm').addEventListener('submit', function(e) {
                e.preventDefault();
                const file = document.getElementById('fileInput').files[0];
                if (!file) return;
                
                
                document.getElementById('progress-container').style.display = 'block';
                const status = document.getElementById('status');
                status.innerText = 'Starting upload...';
                
                const xhr = new XMLHttpRequest();
                xhr.upload.addEventListener('progress', function(e) {
                    if (e.lengthComputable) {
                        const percent = Math.round((e.loaded / e.total) * 100);
                        document.getElementById('progress-bar').style.width = percent + '%';
                        status.innerText = percent + '% uploaded';
                    }
                });
                xhr.onload = function() {
                    if (xhr.status >= 200 && xhr.status < 300) {
                        status.innerText = 'Upload successful!';
                        status.style.color = '#4cd964';
                        document.getElementById('fileInput').value = '';
                    } else {
                        status.innerText = 'Upload failed: ' + xhr.statusText;
                        status.style.color = '#ff3b30';
                    }
                };
                xhr.onerror = function() {
                    status.innerText = 'Upload failed.';
                    status.style.color = '#ff3b30';
                };
                
                xhr.open('POST', '/upload');
                xhr.setRequestHeader('Content-Type', 'application/octet-stream');
                xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name));
                xhr.send(file);
            });
          </script>
        </body>
        </html>
        """
    }
}

public struct AppleWebUploadHandler: Sendable {
    private let maxBytes: Int
    let directory: URL

    public init(maxBytes: Int = 8 * 1024 * 1024 * 1024, directory: URL? = nil) {
        self.maxBytes = maxBytes
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Imports", directoryHint: .isDirectory)
    }

    public func handleUpload(body: Data, fileNameHeader: String?, contentType: String?) async throws -> (status: Int, responseBody: String) {
        guard !body.isEmpty, body.count <= maxBytes else { return (413, "Payload Too Large") }
        if let contentType, contentType.lowercased().hasPrefix("multipart/") {
            guard body.count <= 32 * 1024 * 1024,
                  let boundaryParameter = contentType.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("boundary=") }) else { return (415, "Invalid multipart upload") }
            let boundary = String(boundaryParameter.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !boundary.isEmpty, boundary.utf8.count <= 70, !boundary.contains("\r"), !boundary.contains("\n"),
                  body.starts(with: Data("--\(boundary)\r\n".utf8)),
                  let headerEnd = body.range(of: Data("\r\n\r\n".utf8)), headerEnd.lowerBound <= 16_384,
                  let end = body.range(of: Data("\r\n--\(boundary)--".utf8), in: headerEnd.upperBound..<body.endIndex) else { return (400, "Malformed multipart upload") }
            let headers = String(decoding: body[..<headerEnd.lowerBound], as: UTF8.self)
            guard let start = headers.range(of: "filename=\""),
                  let finish = headers[start.upperBound...].firstIndex(of: "\"") else { return (400, "Missing file name") }
            let filename = String(headers[start.upperBound..<finish]).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            return try await handleUpload(body: Data(body[headerEnd.upperBound..<end.lowerBound]), fileNameHeader: filename, contentType: "application/octet-stream")
        }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID())")
        try body.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await handleUpload(file: temporary, fileNameHeader: fileNameHeader, contentType: contentType)
    }

    public func handleUpload(file: URL, fileNameHeader: String?, contentType: String?) async throws -> (status: Int, responseBody: String) {
        guard contentType?.lowercased().hasPrefix("multipart/") != true else {
            return (415, "Send the video file as the request body.")
        }
        guard let name = fileNameHeader?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.utf8.count <= 240, !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              AppleLibraryScanner.supportedExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
            return (400, "Choose a video file with a valid file name.")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maxBytes else { return (413, "Payload Too Large") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = destination.deletingPathExtension().lastPathComponent
            destination = directory.appending(path: "\(stem)-\(UUID().uuidString.prefix(8)).\(destination.pathExtension)")
        }
        // The complete file is moved into view only after the upload finishes.
        try FileManager.default.moveItem(at: file, to: destination)
        let data = try JSONSerialization.data(withJSONObject: ["success": true, "path": destination.lastPathComponent])
        return (200, String(decoding: data, as: UTF8.self))
    }
}

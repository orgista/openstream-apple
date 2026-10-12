import Foundation

/// The address a Sources row loads an add-on's manifest logo from.
///
/// Manifests publish logos the app cannot show as given: plain `http://`
/// (App Transport Security blocks it; OpenSubtitles v3) and SVG (the image
/// decoder cannot read it; Rotten Tomatoes, on Wikimedia). The row asks for
/// the https form, and for an SVG the raster rendition a host publishes;
/// with none, it has no logo and shows its usual fallback.
enum AppleAddonLogoURLPolicy {
    static let wikimediaThumbnailWidth = 256

    static func displayURL(for logo: URL) -> URL? {
        guard var parts = URLComponents(url: logo, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        if scheme == "http" {
            parts.scheme = "https"
            if parts.port == 80 { parts.port = nil }
        }
        guard parts.path.lowercased().hasSuffix(".svg") else { return parts.url }
        guard host == "upload.wikimedia.org" else { return nil }
        return wikimediaRaster(parts)
    }

    /// `/wikipedia/<project>/<a>/<ab>/<File>.svg` is published as a PNG at
    /// `/wikipedia/<project>/thumb/<a>/<ab>/<File>.svg/<width>px-<File>.svg.png`.
    private static func wikimediaRaster(_ parts: URLComponents) -> URL? {
        var segments = parts.percentEncodedPath.split(separator: "/").map(String.init)
        guard segments.count == 5, segments[0] == "wikipedia", let file = segments.last else { return nil }
        segments.insert("thumb", at: 2)
        segments.append("\(wikimediaThumbnailWidth)px-\(file).png")
        var raster = parts
        raster.percentEncodedPath = "/" + segments.joined(separator: "/")
        raster.query = nil
        return raster.url
    }
}

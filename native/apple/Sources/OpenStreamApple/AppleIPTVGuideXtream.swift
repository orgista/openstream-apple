import Foundation

final class AppleIPTVGuideXtreamParser: Sendable {
    
    struct XtreamEPGListing: Decodable {
        let title: String?
        let description: String?
        let start_timestamp: String?
        let stop_timestamp: String?
    }
    
    struct XtreamShortEPGResponse: Decodable {
        let epg_listings: [XtreamEPGListing]
    }

    func parseShortEPG(data: Data, streamID: String) -> [AppleIPTVProgramme] {
        guard let response = try? JSONDecoder().decode(XtreamShortEPGResponse.self, from: data) else {
            return []
        }
        
        var programmes = [AppleIPTVProgramme]()
        
        for listing in response.epg_listings {
            guard let startStr = listing.start_timestamp, let endStr = listing.stop_timestamp,
                  let startInt = Double(startStr), let endInt = Double(endStr),
                  startInt.isFinite, endInt.isFinite, endInt > startInt else { continue }
            
            let startDate = Date(timeIntervalSince1970: startInt)
            let endDate = Date(timeIntervalSince1970: endInt)
            
            let decodedTitle = decodeBase64(listing.title) ?? "Unknown"
            let decodedDesc = decodeBase64(listing.description)
            
            let prog = AppleIPTVProgramme(
                id: "\(streamID):\(startInt):\(endInt)",
                channelID: streamID,
                title: decodedTitle,
                subtitle: nil,
                description: decodedDesc,
                start: startDate,
                end: endDate,
                category: nil,
                isLive: false
            )
            programmes.append(prog)
        }
        
        return programmes
    }
    
    private func decodeBase64(_ string: String?) -> String? {
        guard let string = string, !string.isEmpty else { return nil }
        guard let data = Data(base64Encoded: string, options: .ignoreUnknownCharacters) else { return string }
        return String(data: data, encoding: .utf8) ?? string
    }
}

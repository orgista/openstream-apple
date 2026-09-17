import SwiftUI

public struct AppleIPTVGuideView: View {
    let guide: AppleIPTVGuide
    let channelID: String
    
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    public init(guide: AppleIPTVGuide, channelID: String) {
        self.guide = guide
        self.channelID = channelID
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let (now, next) = guide.nowAndNext(channelID: channelID, at: currentTime)
            
            if let now = now {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOW PLAYING")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    Text(now.title)
                        .font(.headline)
                        .lineLimit(1)
                    
                    if let desc = now.description {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    
                    Text("\(format(now.start)) - \(format(now.end))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding(.bottom, 8)
            } else {
                Text("No guide data available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if let next = next {
                VStack(alignment: .leading, spacing: 2) {
                    Text("UP NEXT")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    Text(next.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    
                    Text("\(format(next.start)) - \(format(next.end))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .onReceive(timer) { time in
            currentTime = time
        }
    }
    
    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

import Foundation

public struct AppleGuideGridCell: Sendable, Equatable, Identifiable {
    public let id: String
    public let channelID: String
    public let start: Date
    public let end: Date
    public let columnOffset: Double
    public let columnSpan: Double
    public let title: String
    public let subtitle: String?
    public let isLive: Bool

    public init(id: String, channelID: String, start: Date, end: Date, columnOffset: Double, columnSpan: Double, title: String, subtitle: String?, isLive: Bool) {
        self.id = id
        self.channelID = channelID
        self.start = start
        self.end = end
        self.columnOffset = columnOffset
        self.columnSpan = columnSpan
        self.title = title
        self.subtitle = subtitle
        self.isLive = isLive
    }
}

public struct AppleGuideGridRow: Sendable, Equatable, Identifiable {
    public let channelID: String
    public var id: String { channelID }
    public let cells: [AppleGuideGridCell]

    public init(channelID: String, cells: [AppleGuideGridCell]) {
        self.channelID = channelID
        self.cells = cells
    }
}

public struct AppleGuideGridHeaderSlot: Sendable, Equatable, Identifiable {
    public let time: Date
    public var id: Date { time }
    public let label: String

    public init(time: Date, label: String) {
        self.time = time
        self.label = label
    }
}

public struct AppleGuideGridResult: Sendable, Equatable {
    public let rows: [AppleGuideGridRow]
    public let headerSlots: [AppleGuideGridHeaderSlot]
    public let nowOffset: Double?

    public init(rows: [AppleGuideGridRow], headerSlots: [AppleGuideGridHeaderSlot], nowOffset: Double?) {
        self.rows = rows
        self.headerSlots = headerSlots
        self.nowOffset = nowOffset
    }
}

/// A built grid keyed by channel. `AppleGuideGridModel.build` allocates a
/// `DateFormatter` and walks every programme, which is far too much for a view
/// body: the Apple TV guide built one model per row on every render, including
/// every horizontal-scroll tick. The screen builds this once per window and
/// minute instead, and a row view just reads its own cells out of it.
public struct AppleGuideGridIndex: Sendable, Equatable {
    public let headerSlots: [AppleGuideGridHeaderSlot]
    public let cellsByChannel: [String: [AppleGuideGridCell]]
    public let nowOffset: Double?

    public static let empty = AppleGuideGridIndex(AppleGuideGridResult(rows: [], headerSlots: [], nowOffset: nil))

    public init(_ result: AppleGuideGridResult) {
        headerSlots = result.headerSlots
        nowOffset = result.nowOffset
        var cells = [String: [AppleGuideGridCell]](minimumCapacity: result.rows.count)
        for row in result.rows { cells[row.channelID] = row.cells }
        cellsByChannel = cells
    }

    public func cells(for channelID: String) -> [AppleGuideGridCell] { cellsByChannel[channelID] ?? [] }
}

public enum AppleGuideGridModel: Sendable {
    /// The whole grid for `channels` in one pass, pulling each channel's
    /// programmes out of `guide`. Duplicate ids are dropped, like `build`.
    public static func index(
        channels: [String],
        guide: AppleIPTVGuide,
        window: DateInterval,
        slotWidthMinutes: Int,
        now: Date
    ) -> AppleGuideGridIndex {
        var seen = Set<String>()
        let ids = channels.filter { seen.insert($0).inserted }
        var programmes = [String: [AppleIPTVProgramme]](minimumCapacity: ids.count)
        for id in ids { programmes[id] = guide.programmes(channelID: id, in: window) }
        return AppleGuideGridIndex(build(channels: ids, programmes: programmes,
            window: window, slotWidthMinutes: slotWidthMinutes, now: now))
    }

    public static func build(
        channels: [String],
        programmes: [String: [AppleIPTVProgramme]],
        window: DateInterval,
        slotWidthMinutes: Int,
        now: Date
    ) -> AppleGuideGridResult {
        guard slotWidthMinutes > 0, window.start < window.end else {
            return AppleGuideGridResult(rows: [], headerSlots: [], nowOffset: nil)
        }
        let slotDuration = TimeInterval(slotWidthMinutes) * 60
        // Guard malformed provider windows before allocating timeline columns.
        guard window.duration.isFinite, window.duration / slotDuration <= 336 else {
            return AppleGuideGridResult(rows: [], headerSlots: [], nowOffset: nil)
        }
        
        var headers: [AppleGuideGridHeaderSlot] = []
        var currentTime = window.start
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mma"
        
        while currentTime < window.end {
            let label = formatter.string(from: currentTime).lowercased()
            headers.append(AppleGuideGridHeaderSlot(time: currentTime, label: label))
            currentTime += slotDuration
        }
        
        var rows: [AppleGuideGridRow] = []
        
        var seenChannels = Set<String>()
        for channelID in channels where seenChannels.insert(channelID).inserted {
            let channelProgs = programmes[channelID] ?? []
            let overlapping = channelProgs.filter {
                $0.channelID == channelID && $0.start < $0.end && $0.start < window.end && $0.end > window.start
            }.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end > $1.end }
                return $0.id < $1.id
            }
            
            var cells: [AppleGuideGridCell] = []
            var currentCellStart = window.start
            
            for prog in overlapping {
                if prog.start > currentCellStart {
                    let gapEnd = min(prog.start, window.end)
                    let offset = currentCellStart.timeIntervalSince(window.start) / slotDuration
                    let span = gapEnd.timeIntervalSince(currentCellStart) / slotDuration
                    cells.append(AppleGuideGridCell(
                        id: "\(channelID)-gap-\(currentCellStart.timeIntervalSince1970)",
                        channelID: channelID,
                        start: currentCellStart,
                        end: gapEnd,
                        columnOffset: offset,
                        columnSpan: span,
                        title: "No information",
                        subtitle: nil,
                        isLive: false
                    ))
                }
                
                // Providers can repeat or overlap programmes. Only consume the
                // uncovered interval so every row stays aligned with the clock.
                let clampedStart = max(prog.start, currentCellStart)
                let clampedEnd = min(prog.end, window.end)
                
                if clampedEnd > clampedStart {
                    let offset = clampedStart.timeIntervalSince(window.start) / slotDuration
                    let span = clampedEnd.timeIntervalSince(clampedStart) / slotDuration
                    cells.append(AppleGuideGridCell(
                        id: "\(channelID)-programme-\(clampedStart.timeIntervalSince1970)",
                        channelID: channelID,
                        start: clampedStart,
                        end: clampedEnd,
                        columnOffset: offset,
                        columnSpan: span,
                        title: prog.title,
                        subtitle: prog.subtitle ?? prog.description,
                        isLive: prog.isLive
                    ))
                }
                currentCellStart = max(currentCellStart, clampedEnd)
            }
            
            if currentCellStart < window.end {
                let gapEnd = window.end
                let offset = currentCellStart.timeIntervalSince(window.start) / slotDuration
                let span = gapEnd.timeIntervalSince(currentCellStart) / slotDuration
                cells.append(AppleGuideGridCell(
                    id: "\(channelID)-gap-\(currentCellStart.timeIntervalSince1970)",
                    channelID: channelID,
                    start: currentCellStart,
                    end: gapEnd,
                    columnOffset: offset,
                    columnSpan: span,
                    title: "No information",
                    subtitle: nil,
                    isLive: false
                ))
            }
            
            rows.append(AppleGuideGridRow(channelID: channelID, cells: cells))
        }
        
        var nowOffset: Double? = nil
        if now >= window.start && now < window.end {
            nowOffset = now.timeIntervalSince(window.start) / slotDuration
        }
        
        return AppleGuideGridResult(rows: rows, headerSlots: headers, nowOffset: nowOffset)
    }
}

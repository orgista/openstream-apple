#if OPENSTREAM_ADDONS
import Foundation

enum Report {
    static let stageNames = ["Manifest", "Catalogs", "Meta", "Streams", "Subtitles"]

    static func stages(_ result: AddonResult?) -> [StageOutcome] {
        guard let result else { return Array(repeating: .notRun, count: 5) }
        return [result.manifest, result.catalogs, result.meta, result.streams, result.subtitles]
    }

    static func cell(_ outcome: StageOutcome) -> String {
        switch outcome.status {
        case .pass: "ok"
        case .empty: "empty"
        case .fail: "FAIL"
        case .timeout: "T/O"
        case .skip: "–"
        case .crash: "**CRASH**"
        case .notRun: "·"
        }
    }

    static func problem(_ entry: SweepEntry) -> String {
        if entry.process.hasPrefix("signal") || entry.process.hasPrefix("exit:") && entry.process != "exit:0" {
            return "crash in \(entry.crashStage ?? "?") (\(entry.process))"
        }
        if entry.process == "timeout-killed" { return "probe killed after timeout in \(entry.crashStage ?? "?")" }
        let outcomes = stages(entry.result)
        var parts: [String] = []
        for (name, outcome) in zip(stageNames, outcomes) where [.fail, .timeout, .empty, .crash].contains(outcome.status) {
            parts.append("\(name.lowercased()): \(outcome.cause ?? outcome.status.rawValue)")
        }
        if parts.isEmpty, let note = entry.result?.notes.first { parts.append(note) }
        return parts.prefix(2).joined(separator: "; ")
    }

    static func progressLine(_ entry: SweepEntry) -> String {
        let cells = zip(["M", "C", "Me", "S", "Sub"], stages(entry.result)).map { "\($0)=\($1.status.rawValue)" }
        return "\(entry.name.prefix(40)) \(cells.joined(separator: " ")) \(entry.process == "exit:0" ? "" : entry.process)"
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static func probed(_ entries: [SweepEntry]) -> [SweepEntry] {
        entries.filter { $0.process != "skipped-non200" && $0.process != "not-run" }
    }

    static func summaryLines(_ entries: [SweepEntry]) -> [String] {
        let probed = probed(entries)
        var lines = [
            "Listed: \(entries.count) · probed: \(probed.count) · skipped (list HTTP ≠ 200): \(entries.filter { $0.process == "skipped-non200" }.count)"
                + " · not run: \(entries.filter { $0.process == "not-run" }.count)"
                + " · manifest-only (needs config): \(probed.filter(\.needsConfig).count)",
        ]
        for (index, name) in stageNames.enumerated() {
            var counts: [StageStatus: Int] = [:]
            for entry in probed { counts[stages(entry.result)[index].status, default: 0] += 1 }
            let order: [StageStatus] = [.pass, .empty, .fail, .timeout, .crash, .skip, .notRun]
            lines.append("\(name): " + order.compactMap { status in
                counts[status].map { "\(status.rawValue) \($0)" }
            }.joined(separator: " · "))
        }
        let crashes = probed.filter { $0.process.hasPrefix("signal") || ($0.process.hasPrefix("exit:") && $0.process != "exit:0") }
        lines.append("Crashes: \(crashes.count) · probe timeouts: \(probed.filter { $0.process == "timeout-killed" }.count)")
        return lines
    }

    static func markdown(_ entries: [SweepEntry], elapsed: Duration, title: String) -> String {
        let probed = probed(entries)
        var out: [String] = []
        out.append("# \(title) — \(ISO8601DateFormatter().string(from: .now))")
        out.append("")
        out.append("Harness: `swift run --scratch-path \"$HOME/Developer/openstream-build/main-merge-spm\" OpenStreamAddonProbe sweep` "
                   + "(Sources/OpenStreamAddonProbe). Every stage runs the app's own clients from `OpenStreamApple`; "
                   + "each add-on is probed in its own process so a trap is attributed by exit signal. "
                   + "Elapsed \(elapsed.components.seconds / 60) min.")
        out.append("")
        out.append("Legend: ok · empty (2xx but nothing usable) · FAIL · T/O (timeout) · – (not applicable) · · (not reached) · **CRASH**")
        out.append("")
        out.append("## Summary")
        out.append("")
        out += summaryLines(entries).map { "- \($0)" }

        // Cause tallies per stage.
        out.append("")
        out.append("### Failure causes by stage (add-ons)")
        out.append("")
        for (index, name) in stageNames.enumerated() {
            var causes: [String: [String]] = [:]
            for entry in probed {
                let outcome = stages(entry.result)[index]
                guard [.fail, .timeout, .empty, .crash].contains(outcome.status) else { continue }
                causes[outcome.cause ?? outcome.status.rawValue, default: []].append(entry.name)
            }
            guard !causes.isEmpty else { continue }
            let sorted = causes.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
            out.append("- **\(name)**: " + sorted.map { "`\($0.key)` \($0.value.count)" }.joined(separator: ", "))
        }

        // CRASHES
        out.append("")
        out.append("## CRASHES (app code trapped — top priority)")
        out.append("")
        let crashes = probed.filter { $0.process.hasPrefix("signal") || ($0.process.hasPrefix("exit:") && $0.process != "exit:0") }
        if crashes.isEmpty {
            out.append("None. No probe process died by signal or non-zero exit.")
        }
        for entry in crashes {
            out.append("### \(escape(entry.name)) — \(entry.process), stage `\(entry.crashStage ?? "?")`")
            if let url = entry.manifestURL { out.append("Manifest: \(url)") }
            out.append("")
            out.append("```")
            out.append(entry.crashExcerpt?.isEmpty == false ? entry.crashExcerpt! : "(no stderr)")
            out.append("```")
            out.append("")
        }
        let killed = probed.filter { $0.process == "timeout-killed" }
        if !killed.isEmpty {
            out.append("Probe processes killed at the 300 s cap (hang, not crash): "
                       + killed.map { "\(escape($0.name)) (\($0.crashStage ?? "?"))" }.joined(separator: ", "))
        }

        // DECODE FAILURES
        out.append("")
        out.append("## DECODE FAILURES (add-on answered 2xx JSON, the app rejected or dropped it)")
        out.append("")
        var decode: [String: [String]] = [:]
        for entry in probed {
            for outcome in allOutcomes(entry.result) {
                if let cause = outcome.cause, cause.hasPrefix("decode:") {
                    decode[cause, default: []].append(entry.name)
                }
            }
        }
        if decode.isEmpty { out.append("None at stage level.") }
        for (cause, names) in decode.sorted(by: { $0.value.count > $1.value.count }) {
            let unique = Array(Set(names)).sorted()
            out.append("- `\(cause)` — \(unique.count) add-ons: \(unique.prefix(8).map(escape).joined(separator: ", "))\(unique.count > 8 ? ", …" : "")")
        }
        out.append("")
        out.append("### Catalog items the app dropped (per raw `metas` entry, first failing reason)")
        out.append("")
        var drops: [String: (items: Int, addons: Set<String>)] = [:]
        for entry in probed {
            for probe in entry.result?.catalogProbes ?? [] {
                for (reason, count) in probe.dropReasons {
                    drops[reason, default: (0, [])].items += count
                    drops[reason, default: (0, [])].addons.insert(entry.name)
                }
            }
        }
        if drops.isEmpty { out.append("None.") }
        for (reason, value) in drops.sorted(by: { $0.value.addons.count > $1.value.addons.count }) {
            let examples = value.addons.sorted().prefix(6).map(escape).joined(separator: ", ")
            out.append("- `\(reason)` — \(value.items) items in \(value.addons.count) add-ons (e.g. \(examples))")
        }

        out.append("")
        out.append("### Compatibility notes (not failures)")
        out.append("")
        var notes: [String: [String]] = [:]
        var ignoredTypes: [String: Set<String>] = [:]
        var secretFlagged: [String] = []
        for entry in probed {
            for note in entry.result?.notes ?? [] {
                let key = note.hasPrefix("catalog types ignored") ? "catalog types ignored by app (only movie/series shown)"
                    : note.hasPrefix("resources differ") ? "resource names differ after app sanitising" : note
                notes[key, default: []].append(entry.name)
            }
            for type in entry.result?.manifestInfo?.ignoredCatalogTypes.keys ?? [:].keys {
                ignoredTypes[type, default: []].insert(entry.name)
            }
            if entry.result?.manifestInfo?.treatedAsSecret == true, !entry.isPrivate { secretFlagged.append(entry.name) }
        }
        for (note, names) in notes.sorted(by: { $0.value.count > $1.value.count }) {
            out.append("- \(note): \(names.count) add-ons (e.g. \(names.prefix(6).map(escape).joined(separator: ", ")))")
        }
        if !ignoredTypes.isEmpty {
            out.append("- ignored catalog types: " + ignoredTypes.sorted { $0.value.count > $1.value.count }.prefix(15)
                .map { "`\($0.key)` \($0.value.count)" }.joined(separator: ", "))
        }
        if !secretFlagged.isEmpty {
            out.append("- `AppleAddonURLSecretPolicy.isSecret` = true for \(secretFlagged.count) list add-ons (sealed in iCloud sync; e.g. \(secretFlagged.prefix(6).map(escape).joined(separator: ", ")))")
        }

        // Table
        out.append("")
        out.append("## Add-ons")
        out.append("")
        out.append("| Add-on | Source | Manifest | Catalogs | Meta | Streams | Subtitles | Problem |")
        out.append("|---|---|---|---|---|---|---|---|")
        let sorted = entries.sorted { rank($0) < rank($1) || (rank($0) == rank($1) && $0.name.lowercased() < $1.name.lowercased()) }
        for entry in sorted {
            if entry.process == "skipped-non200" || entry.process == "not-run" {
                let why = entry.process == "not-run" ? "not run (limit/budget)" : "list HTTP \(entry.listedHTTPStatus ?? 0)"
                out.append("| \(escape(String(entry.name.prefix(50)))) | \(escape(entry.source)) | · | · | · | · | · | skipped: \(why) |")
                continue
            }
            let cells = stages(entry.result).map { outcome -> String in
                let base = cell(outcome)
                guard outcome.status != .skip, outcome.status != .notRun, let detail = outcome.detail else { return base }
                return "\(base) \(escape(String(detail.prefix(40))))"
            }
            let name = escape(String(entry.name.prefix(50))) + (entry.needsConfig ? " (cfg)" : "")
            out.append("| \(name) | \(escape(entry.source)) | \(cells.joined(separator: " | ")) | \(escape(problem(entry))) |")
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    static func allOutcomes(_ result: AddonResult?) -> [StageOutcome] {
        guard let result else { return [] }
        return stages(result)
            + result.catalogProbes.map(\.outcome)
            + result.streamProbes.map(\.outcome)
            + [result.metaProbe?.episodes].compactMap { $0 }
    }

    /// Crashes first, then failures, then the rest; skipped last.
    static func rank(_ entry: SweepEntry) -> Int {
        if entry.process.hasPrefix("signal") || (entry.process.hasPrefix("exit:") && entry.process != "exit:0") { return 0 }
        if entry.process == "skipped-non200" || entry.process == "not-run" { return 4 }
        let outcomes = stages(entry.result)
        if outcomes.contains(where: { $0.cause?.hasPrefix("decode:") == true }) { return 1 }
        if outcomes.contains(where: { [.fail, .timeout].contains($0.status) }) { return 2 }
        return 3
    }
}

#endif

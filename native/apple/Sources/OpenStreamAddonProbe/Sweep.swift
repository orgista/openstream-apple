#if OPENSTREAM_ADDONS
import Foundation
import Synchronization

/// The sweep driver: reads the add-on list, spawns one probe process per
/// add-on (≤ 8 at a time), attributes traps by exit signal, and writes the
/// report. Private (dev-sources) add-ons go only to a 0600 file and are never
/// echoed to the terminal.
struct SweepOptions: Sendable {
    var input: URL
    var privateSources: URL?
    var outputDirectory: URL
    var privateReport: URL
    var concurrency = 8
    var limit: Int?
    var only: String?
    var budget: Duration = .seconds(40 * 60)
    var perAddonTimeout: Duration = .seconds(300)
    var selfTestTrap = false

    static func parse(_ arguments: [String]) -> SweepOptions {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let build = home.appending(path: "Developer/openstream-build")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var options = SweepOptions(
            input: build.appending(path: "specs/stremio-addons.json"),
            privateSources: build.appending(path: "signing/dev-sources.json"),
            outputDirectory: build.appending(path: "addon-sweep/\(formatter.string(from: .now))"),
            privateReport: build.appending(path: "signing/addon-sweep-private.md")
        )
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--input": iterator.next().map { options.input = URL(fileURLWithPath: $0) }
            case "--private": iterator.next().map { options.privateSources = URL(fileURLWithPath: $0) }
            case "--no-private": options.privateSources = nil
            case "--out": iterator.next().map { options.outputDirectory = URL(fileURLWithPath: $0) }
            case "--private-out": iterator.next().map { options.privateReport = URL(fileURLWithPath: $0) }
            case "--concurrency": iterator.next().flatMap(Int.init).map { options.concurrency = min(max($0, 1), 8) }
            case "--limit": options.limit = iterator.next().flatMap(Int.init)
            case "--only": options.only = iterator.next()?.lowercased()
            case "--budget-minutes": iterator.next().flatMap(Int.init).map { options.budget = .seconds($0 * 60) }
            case "--selftest-trap": options.selfTestTrap = true
            default:
                FileHandle.standardError.write(Data("unknown option \(argument)\n".utf8))
                exit(64)
            }
        }
        return options
    }
}

struct ListedAddon: Decodable {
    let name: String
    let manifest_url: String
    let needs_config: Bool?
    let sources: [String]?
    let http_status: Int?
}

struct DevSources: Decodable {
    struct Source: Decodable {
        let kind: String
        let name: String
        let manifestURL: String?
    }
    let sources: [Source]
}

/// What the driver knows about one add-on after its probe process exits.
struct SweepEntry: Codable, Sendable {
    var name: String
    var manifestURL: String?          // public list entries only; nil for private
    var source: String
    var needsConfig: Bool
    var listedHTTPStatus: Int?
    var isPrivate: Bool
    var result: AddonResult?
    /// `exit:N`, `signal:N (SIGTRAP)`, `timeout-killed`, `not-run`, `skipped-non200`.
    var process: String
    var crashStage: String?
    var crashExcerpt: String?
    var durationSeconds: Double?
}

enum Sweep {
    static func run(_ options: SweepOptions) async throws {
        let listed = try JSONDecoder().decode([ListedAddon].self, from: Data(contentsOf: options.input))
        var entries: [SweepEntry] = []
        var jobs: [(Int, ProbeJob)] = []

        for addon in listed {
            if let only = options.only, !addon.name.lowercased().contains(only) { continue }
            let source = addon.sources?.first.map(shortSource) ?? "?"
            var entry = SweepEntry(name: addon.name, manifestURL: addon.manifest_url, source: source,
                                   needsConfig: addon.needs_config ?? false,
                                   listedHTTPStatus: addon.http_status, isPrivate: false, process: "not-run")
            if addon.http_status != 200 {
                entry.process = "skipped-non200"
                entries.append(entry)
                continue
            }
            let index = entries.count
            entries.append(entry)
            jobs.append((index, ProbeJob(index: index, name: addon.name, manifestURL: addon.manifest_url,
                                         manifestOnly: addon.needs_config ?? false, isPrivate: false)))
        }
        if let limit = options.limit { jobs = Array(jobs.prefix(limit)) }

        if let url = options.privateSources, options.only == nil, !options.selfTestTrap,
           let data = try? Data(contentsOf: url),
           let dev = try? JSONDecoder().decode(DevSources.self, from: data) {
            for source in dev.sources where source.kind == "stremio" {
                guard let manifestURL = source.manifestURL else { continue }
                let index = entries.count
                entries.append(SweepEntry(name: source.name, manifestURL: nil, source: "dev-sources",
                                          needsConfig: false, listedHTTPStatus: nil, isPrivate: true,
                                          process: "not-run"))
                jobs.append((index, ProbeJob(index: index, name: source.name, manifestURL: manifestURL,
                                             manifestOnly: false, isPrivate: true)))
            }
        }
        if options.selfTestTrap {
            jobs = Array(jobs.prefix(1)).map { index, job in
                var job = job
                job.selfTestTrap = true
                return (index, job)
            }
        }

        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "openstream-addon-probe-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let started = ContinuousClock.now
        let total = jobs.count
        print("Probing \(total) add-ons (concurrency \(options.concurrency)); \(entries.count - total) not probed.")
        let outcomes = await withTaskGroup(of: (Int, SweepEntry).self, returning: [(Int, SweepEntry)].self) { group in
            var next = 0
            var finished: [(Int, SweepEntry)] = []
            func enqueue() -> Bool {
                guard next < jobs.count, started.duration(to: .now) < options.budget else { return false }
                let (index, job) = jobs[next]
                let entry = entries[index]
                next += 1
                group.addTask {
                    (index, await ProbeRunner.run(job: job, entry: entry, executable: executable,
                                                  scratch: scratch, timeout: options.perAddonTimeout))
                }
                return true
            }
            for _ in 0 ..< options.concurrency { _ = enqueue() }
            while let (index, entry) = await group.next() {
                finished.append((index, entry))
                if !entry.isPrivate {
                    print("[\(finished.count)/\(total)] \(Report.progressLine(entry))")
                }
                _ = enqueue()
            }
            return finished
        }
        for (index, entry) in outcomes { entries[index] = entry }
        let elapsed = started.duration(to: .now)

        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let publicEntries = entries.filter { !$0.isPrivate }
        let privateEntries = entries.filter(\.isPrivate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = SweepFile(generatedAt: .now, elapsedSeconds: Double(elapsed.components.seconds),
                                input: options.input.lastPathComponent, entries: publicEntries)
        if !options.selfTestTrap {
            try encoder.encode(payload).write(to: options.outputDirectory.appending(path: "results.json"), options: .atomic)
            try Report.markdown(publicEntries, elapsed: elapsed, title: "Stremio add-on sweep")
                .write(to: options.outputDirectory.appending(path: "report.md"), atomically: true, encoding: .utf8)
        }
        if !privateEntries.isEmpty {
            try writePrivate(Report.markdown(privateEntries, elapsed: elapsed, title: "Private add-on sweep (owner sources)"),
                             to: options.privateReport)
        }
        let summary = Report.summaryLines(publicEntries)
        print(summary.joined(separator: "\n"))
        if options.selfTestTrap {
            print("SELFTEST: \(publicEntries.first(where: { $0.process != "skipped-non200" && $0.process != "not-run" })?.process ?? "none") stage=\(publicEntries.compactMap(\.crashStage).first ?? "-")")
        } else {
            print("Wrote \(options.outputDirectory.path)/results.json and report.md"
                  + (privateEntries.isEmpty ? "" : "; private section written (0600)."))
        }
    }

    static func writePrivate(_ text: String, to url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        guard manager.createFile(atPath: url.path, contents: Data(text.utf8),
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func shortSource(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "github:", with: "gh:")
        return String(trimmed.prefix(40))
    }
}

struct SweepFile: Codable {
    var generatedAt: Date
    var elapsedSeconds: Double
    var input: String
    var entries: [SweepEntry]
}

/// Spawns `OpenStreamAddonProbe probe` for one add-on. The job (with the
/// manifest URL) goes in through a 0600 file on stdin, never argv.
final class ExitBox: Sendable {
    let value = Mutex<(Int, Int32)?>(nil)
}

enum ProbeRunner {
    static func run(job: ProbeJob, entry: SweepEntry, executable: URL, scratch: URL, timeout: Duration) async -> SweepEntry {
        var entry = entry
        let base = scratch.appending(path: "job-\(job.index)")
        let jobURL = base.appendingPathExtension("in")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        defer {
            for url in [jobURL, outURL, errURL] { try? FileManager.default.removeItem(at: url) }
        }
        let started = ContinuousClock.now
        do {
            let manager = FileManager.default
            guard manager.createFile(atPath: jobURL.path, contents: try JSONEncoder().encode(job),
                                     attributes: [.posixPermissions: 0o600]),
                  manager.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  manager.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                entry.process = "harness-error:scratch"
                return entry
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["probe"]
            process.standardInput = try FileHandle(forReadingFrom: jobURL)
            process.standardOutput = try FileHandle(forWritingTo: outURL)
            process.standardError = try FileHandle(forWritingTo: errURL)
            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_BACKTRACE"] = "enable=yes,interactive=no,color=no,output-to=stderr,limit=40,top=10"
            process.environment = environment

            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            let exitInfo = ExitBox()
            process.terminationHandler = { finished in
                exitInfo.value.withLock { $0 = (finished.terminationReason.rawValue, finished.terminationStatus) }
                continuation.finish()
            }
            try process.run()
            let pid = process.processIdentifier

            enum Event: Sendable { case exited, killed, sleepCancelled }
            var timedOut = false
            await withTaskGroup(of: Event.self) { group in
                group.addTask {
                    for await _ in stream {}
                    return .exited
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        kill(pid, SIGKILL)
                        return .killed
                    } catch {
                        return .sleepCancelled
                    }
                }
                while let event = await group.next() {
                    switch event {
                    case .exited: group.cancelAll()
                    case .killed: timedOut = true
                    case .sleepCancelled: break
                    }
                }
            }
            entry.durationSeconds = Double(started.duration(to: .now).components.seconds)

            let stdout = (try? Data(contentsOf: outURL)) ?? Data()
            let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
            let (reasonRaw, status) = exitInfo.value.withLock { $0 } ?? (Process.TerminationReason.exit.rawValue, -1)
            let reason = Process.TerminationReason(rawValue: reasonRaw) ?? .exit
            let lastStage = stderr.split(separator: "\n").last(where: { $0.hasPrefix("STAGE ") })
                .map { String($0.dropFirst("STAGE ".count)) }

            if let result = try? JSONDecoder().decode(AddonResult.self, from: stdout) {
                entry.result = result
            }
            if timedOut {
                entry.process = "timeout-killed"
                entry.crashStage = lastStage
                entry.result = entry.result ?? partial(job: job, stage: lastStage, status: .timeout)
            } else if reason == .uncaughtSignal {
                entry.process = "signal:\(status) (\(signalName(status)))"
                entry.crashStage = lastStage
                entry.crashExcerpt = crashExcerpt(stderr, redacting: job.manifestURL)
                entry.result = partial(job: job, stage: lastStage, status: .crash)
            } else if status != 0 || entry.result == nil {
                entry.process = "exit:\(status)"
                entry.crashStage = lastStage
                entry.crashExcerpt = crashExcerpt(stderr, redacting: job.manifestURL)
                entry.result = entry.result ?? partial(job: job, stage: lastStage, status: .crash)
            } else {
                entry.process = "exit:0"
            }
        } catch {
            entry.process = "harness-error:\(type(of: error))"
        }
        return entry
    }

    /// Marks the stage that was running when the process died.
    static func partial(job: ProbeJob, stage: String?, status: StageStatus) -> AddonResult {
        var result = AddonResult(index: job.index, name: job.name)
        let order = ["manifest", "catalogs", "meta", "streams", "subtitles"]
        let reached = stage.flatMap { order.firstIndex(of: $0) } ?? 0
        let cause = status == .crash ? "crash" : "timeout"
        for (offset, name) in order.enumerated() {
            let outcome: StageOutcome = offset < reached ? .init(status: .pass, detail: "(before \(cause))")
                : offset == reached ? .init(status: status, cause: cause) : .notRun
            switch name {
            case "manifest": result.manifest = outcome
            case "catalogs": result.catalogs = outcome
            case "meta": result.meta = outcome
            case "streams": result.streams = outcome
            default: result.subtitles = outcome
            }
        }
        return result
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTRAP: "SIGTRAP"
        case SIGILL: "SIGILL"
        case SIGABRT: "SIGABRT"
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGKILL: "SIGKILL"
        default: "signal \(signal)"
        }
    }

    /// The fatal-error line plus the top of the backtrace, with every URL
    /// (and the add-on's own manifest address) removed.
    static func crashExcerpt(_ stderr: String, redacting manifestURL: String) -> String {
        var text = stderr.replacingOccurrences(of: manifestURL, with: "[MANIFEST]")
        if let expression = try? NSRegularExpression(pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+"#) {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                       withTemplate: "[URL]")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("STAGE ") }
        var excerpt = lines.filter { $0.contains("Fatal error") || $0.contains("Program crashed") }
        if let crashed = lines.firstIndex(where: { $0.hasPrefix("Thread ") && $0.hasSuffix("crashed:") }) {
            let block = lines[crashed...].dropFirst().drop(while: \.isEmpty).prefix { !$0.isEmpty }
            excerpt += [lines[crashed]] + block.prefix(25)
        }
        if excerpt.isEmpty { excerpt = Array(lines.suffix(20)) }
        return excerpt.joined(separator: "\n")
    }
}

#endif

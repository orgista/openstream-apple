#if OPENSTREAM_ADDONS
import Foundation

/// Headless Stremio add-on compatibility harness for the OpenStream Apple app.
///
///     swift run --scratch-path "$HOME/Developer/openstream-build/main-merge-spm" \
///         OpenStreamAddonProbe sweep [--limit N] [--only NAME] [--no-private] [--out DIR]
///
/// `sweep` reads `~/Developer/openstream-build/specs/stremio-addons.json` (plus
/// the stremio entries of `signing/dev-sources.json`, reported only to
/// `signing/addon-sweep-private.md`, 0600) and writes
/// `~/Developer/openstream-build/addon-sweep/<date>/{results.json,report.md}`.
/// `probe` is the per-add-on child the sweep spawns (job JSON on stdin).
/// It never plays, downloads, or follows torrent/magnet links.
@main
struct OpenStreamAddonProbeMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let mode = arguments.isEmpty ? "sweep" : arguments.removeFirst()
        switch mode {
        case "probe":
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let job = try? JSONDecoder().decode(ProbeJob.self, from: input) else {
                FileHandle.standardError.write(Data("probe: bad job on stdin\n".utf8))
                exit(65)
            }
            let result = await AddonProbe(job: job).run()
            do {
                FileHandle.standardOutput.write(try JSONEncoder().encode(result))
            } catch {
                exit(70)
            }
        case "sweep":
            do {
                try await Sweep.run(SweepOptions.parse(arguments))
            } catch {
                FileHandle.standardError.write(Data("sweep failed: \(error)\n".utf8))
                exit(1)
            }
        default:
            FileHandle.standardError.write(Data("usage: OpenStreamAddonProbe sweep [options] | probe\n".utf8))
            exit(64)
        }
    }
}

#endif

#if !OPENSTREAM_ADDONS
@main enum DisabledAddonProbe {
    static func main() { }
}
#endif

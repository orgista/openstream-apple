#if OPENSTREAM_ADDONS
import Foundation
import OpenStreamApple

/// Probes one add-on through the app's own Stremio clients. Runs inside its
/// own process (`OpenStreamAddonProbe probe`), so a trap in app code kills
/// only this add-on's probe and the driver attributes it by exit signal.
struct AddonProbe {
    static let movieID = "tt0111161"          // The Shawshank Redemption
    static let episodeID = "tt0903747:1:1"    // Breaking Bad S1E1
    static let catalogsToProbe = 3

    let job: ProbeJob

    private func stage(_ name: String) {
        FileHandle.standardError.write(Data("STAGE \(name)\n".utf8))
    }

    func run() async -> AddonResult {
        var result = AddonResult(index: job.index, name: job.name)

        // 1. Manifest — AppleManifestClient (URL policy + fetch + decode/validate).
        stage("manifest")
        let recorder = ExchangeRecorder()
        let manifestClient = AppleManifestClient(loader: recorder.wrap(AppleManifestClient.liveLoader))
        let value = job.manifestURL
        let loaded: (URL, AppleStremioManifest)
        let raw: RawManifest?
        do {
            loaded = try await withStageTimeout(.seconds(70)) { try await manifestClient.load(value) }
            raw = RawManifest(recorder.lastResponse?.body)
        } catch {
            let exchange = recorder.lastResponse
            raw = RawManifest(exchange?.body)
            result.manifest = Self.manifestFailure(error, exchange: exchange, raw: raw)
            result.manifestInfo = raw.map { Self.info(raw: $0, manifest: nil, url: nil) }
            for keyPath in [\AddonResult.catalogs, \.meta, \.streams, \.subtitles] {
                result[keyPath: keyPath] = .skip("manifest failed")
            }
            return result
        }

        let (manifestURL, manifest) = loaded
        let source = Self.source(url: manifestURL, manifest: manifest)
        let info = Self.info(raw: raw, manifest: manifest, url: manifestURL)
        result.manifestInfo = info
        result.manifest = StageOutcome(
            status: .pass,
            cause: nil,
            detail: "\(manifest.resources.joined(separator: ",")) · \(info.appCatalogCount)/\(info.rawCatalogCount) catalogs"
        )
        if !info.ignoredCatalogTypes.isEmpty {
            let list = info.ignoredCatalogTypes.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
            result.notes.append("catalog types ignored by app: \(list.joined(separator: ", "))")
        }
        if info.rawCatalogCount > 0, info.appCatalogCount == AppleStremioManifest.maximumCatalogs,
           info.rawCatalogCount - info.ignoredCatalogTypes.values.reduce(0, +) > AppleStremioManifest.maximumCatalogs {
            result.notes.append("100-catalog manifest cap hides catalogs")
        }
        if let raw, !manifest.resources.isEmpty, raw.resourceNames.isEmpty == false,
           Set(raw.resourceNames.map { $0.lowercased() }) != Set(manifest.resources) {
            result.notes.append("resources differ: raw \(raw.resourceNames.joined(separator: ",")) vs app \(manifest.resources.joined(separator: ","))")
        }

        if manifest.resources.isEmpty {
            result.notes.append("manifest declares no resources (app accepts a source that serves nothing)")
        }
        if job.manifestOnly {
            for keyPath in [\AddonResult.catalogs, \.meta, \.streams, \.subtitles] {
                result[keyPath: keyPath] = .skip("needs config")
            }
            return result
        }

        // 2. Catalogs — AppleCatalogDiscoveryPolicy + AppleStremioCatalogClient.
        stage("catalogs")
        if job.selfTestTrap {
            let empty: [Int] = []
            _ = empty[Int(ProcessInfo.processInfo.processIdentifier) % 7 + 1]
        }
        var items: [AppleCatalogItem] = []
        (result.catalogs, result.catalogProbes, items) = await probeCatalogs(source: source, info: info)

        // 3. Meta — AppleStremioMetadataClient.details (+ episodes for tt series).
        stage("meta")
        (result.meta, result.metaProbe) = await probeMeta(source: source, raw: raw, items: items)

        // 4. Streams — AppleStremioPlaybackClient.streams + candidate ranking.
        stage("streams")
        (result.streams, result.streamProbes) = await probeStreams(source: source, raw: raw)

        // 5. Subtitles — AppleExternalSubtitleService.
        stage("subtitles")
        (result.subtitles, result.subtitleProbe) = await probeSubtitles(source: source, raw: raw)
        stage("done")
        return result
    }

    // MARK: Manifest

    static func source(url: URL, manifest: AppleStremioManifest) -> AppleSource {
        // Mirrors AppleSourceStore.addStremio(manifestURL:manifest:) without
        // the keychain/persistence side effects.
        AppleSource(
            kind: .stremio,
            name: manifest.name,
            url: url,
            manifestID: manifest.id,
            version: manifest.version,
            resources: manifest.resources,
            catalogs: manifest.catalogs,
            logoURL: manifest.logoURL,
            lastValidatedAt: .now,
            validationSummary: "Manifest validated",
            capabilities: manifest.resources.map { $0.capitalized }
        )
    }

    static func info(raw: RawManifest?, manifest: AppleStremioManifest?, url: URL?) -> ManifestInfo {
        var info = ManifestInfo()
        info.id = manifest?.id ?? (raw?.object["id"] as? String).map { String($0.prefix(80)) }
        info.version = manifest?.version ?? (raw?.object["version"] as? String).map { String($0.prefix(40)) }
        info.appResources = manifest?.resources ?? []
        if let raw {
            info.rawResources = Array(raw.resourceNames.prefix(16))
            info.types = Array(raw.types.prefix(16))
            var prefixes = raw.idPrefixes
            for name in raw.resourceNames { prefixes += raw.prefixes(for: name.lowercased()) }
            var seen = Set<String>()
            info.idPrefixes = Array(prefixes.filter { seen.insert($0).inserted }.prefix(12))
            info.rawCatalogCount = raw.catalogs.count
            for catalog in raw.catalogs {
                let type = ((catalog["type"] as? String) ?? "?").lowercased()
                if !AppleCatalogDiscoveryPolicy.isShelfType(type) { info.ignoredCatalogTypes[String(type.prefix(24)), default: 0] += 1 }
                let extras = catalog["extra"] as? [Any] ?? []
                let required = extras.contains { (($0 as? [String: Any])?["isRequired"] as? Bool) == true }
                    || !((catalog["extraRequired"] as? [Any]) ?? []).isEmpty
                if required { info.requiredExtraCatalogCount += 1 }
            }
            info.specValid = raw.isSpecValid
        }
        if let manifest {
            info.appCatalogCount = manifest.catalogs.count
        }
        if let url, let manifest {
            info.eligibleCatalogCount = AppleCatalogDiscoveryPolicy.catalogs(
                for: source(url: url, manifest: manifest),
                maximumCatalogs: AppleCatalogDiscoveryPolicy.hardMaximumCatalogs
            ).count
            info.treatedAsSecret = AppleAddonURLSecretPolicy.isSecret(url)
        }
        return info
    }

    static func manifestFailure(_ error: any Error, exchange: RecordedExchange?, raw: RawManifest?) -> StageOutcome {
        let cause = Classifier.cause(of: error)
        if cause == "timeout" { return .init(status: .timeout, cause: "timeout", detail: "manifest > 70 s") }
        if let value = error as? AppleManifestClientError {
            if value == .manifestNeedsConfiguration {
                // Correct refusal: the add-on declares configurationRequired.
                return .init(status: .skip, cause: "manifest:needsConfiguration", detail: "needs configuration")
            }
            if case .manifestNeedsSetup = value {
                // Correct refusal: the add-on serves nothing until configured.
                return .init(status: .skip, cause: "manifest:needsSetup", detail: "serves nothing until configured")
            }
            // The add-on answered with JSON; did the app refuse a manifest that
            // meets Stremio's spec?
            if let raw, [.invalidManifest, .manifestNotObject].contains(value)
                || { if case .manifestMissingField = value { return true }
                     if case .manifestFieldWrongType = value { return true }
                     return false }() {
                let prefix = raw.isSpecValid ? "decode" : "bad-response"
                return .init(status: .fail, cause: "\(prefix):manifest:\(Classifier.caseName(value))",
                             detail: value.errorDescription)
            }
            if value == .manifestNotJSON {
                let shape = Classifier.looksLikeHTML(exchange) ? "html-page" : "not-json"
                return .init(status: .fail, cause: "bad-response:manifest:\(shape)", detail: value.errorDescription)
            }
        }
        let detail = (error as? LocalizedError)?.errorDescription ?? cause
        return .init(status: .fail, cause: cause, detail: String(detail.prefix(120)))
    }

    // MARK: Catalogs

    private func probeCatalogs(
        source: AppleSource,
        info: ManifestInfo
    ) async -> (StageOutcome, [CatalogProbe], [AppleCatalogItem]) {
        guard source.resources.contains("catalog") else {
            return (.skip("no catalog resource"), [], [])
        }
        let eligible = AppleCatalogDiscoveryPolicy.catalogs(
            for: source,
            maximumCatalogs: AppleCatalogDiscoveryPolicy.hardMaximumCatalogs
        )
        guard !eligible.isEmpty else {
            let why = info.rawCatalogCount == 0 ? "no catalogs"
                : info.ignoredCatalogTypes.isEmpty ? "all need extras" : "no usable catalog types"
            return (.skip(why), [], [])
        }

        var probes: [CatalogProbe] = []
        var items: [AppleCatalogItem] = []
        for catalog in eligible.prefix(Self.catalogsToProbe) {
            let recorder = ExchangeRecorder()
            let client = AppleStremioCatalogClient(loader: recorder.wrap(AppleStremioCatalogClient.liveLoader))
            var probe = CatalogProbe(type: catalog.type, id: String(catalog.id.prefix(80)),
                                     outcome: .init(status: .pass))
            do {
                let decoded = try await withStageTimeout(.seconds(20)) {
                    try await client.load(source: source, catalog: catalog)
                }
                let exchange = recorder.lastResponse
                probe.httpStatus = exchange?.status
                let rawMetas = (Classifier.json(exchange?.body) as? [String: Any])?["metas"] as? [Any]
                probe.rawCount = rawMetas?.count
                probe.decodedCount = decoded.count
                if let rawMetas {
                    probe.dropReasons = CatalogDropAnalysis.reasons(raw: rawMetas, catalogType: catalog.type,
                                                                    decodedCount: decoded.count)
                }
                probe.outcome = decoded.isEmpty
                    ? .init(status: .empty, cause: rawMetas?.isEmpty == false ? "decode:catalog:all-items-dropped" : "empty-catalog",
                            detail: "0/\(rawMetas?.count ?? 0) items")
                    : .init(status: .pass, detail: "\(decoded.count)/\(rawMetas?.count ?? decoded.count) items")
                items += decoded
            } catch {
                let exchange = recorder.lastResponse
                probe.httpStatus = exchange?.status
                probe.outcome = Self.clientFailure(error, recorder: recorder, expectedKey: "metas", stage: "catalog")
            }
            probes.append(probe)
        }

        let failures = probes.filter { $0.outcome.status == .fail || $0.outcome.status == .timeout }
        let decodedTotal = probes.compactMap(\.decodedCount).reduce(0, +)
        let rawTotal = probes.compactMap(\.rawCount).reduce(0, +)
        let summary = "\(probes.count - failures.count)/\(probes.count) ok, \(decodedTotal)/\(rawTotal) items"
        if let first = failures.first {
            return (.init(status: first.outcome.status, cause: first.outcome.cause, detail: summary), probes, items)
        }
        if decodedTotal == 0 {
            let cause = probes.first(where: { $0.outcome.cause?.hasPrefix("decode:") == true })?.outcome.cause ?? "empty-catalog"
            return (.init(status: .empty, cause: cause, detail: summary), probes, items)
        }
        return (.init(status: .pass, detail: summary), probes, items)
    }

    /// A failure from one of the app's HTTP clients, explained with the recorded response.
    static func clientFailure(
        _ error: any Error,
        recorder: ExchangeRecorder,
        expectedKey: String,
        stage: String
    ) -> StageOutcome {
        let cause = Classifier.cause(of: error)
        if cause == "timeout" { return .init(status: .timeout, cause: "timeout", detail: "\(stage) timed out") }
        let generic = ["catalog:invalidCatalog", "playback:invalidPayload"]
        if generic.contains(cause) {
            if let transport = Classifier.transportCause(recorder.last) {
                return .init(status: .fail, cause: transport, detail: "\(cause) ← \(transport)")
            }
            if let response = recorder.lastResponse, let responseURL = response.responseURL,
               let requestURL = response.requestURL, responseURL != requestURL, stage == "meta" {
                return .init(status: .fail, cause: "decode:meta:redirect-rejected",
                             detail: "response came from a redirect")
            }
            let shape = Classifier.bodyShape(recorder.lastResponse, expectedKey: expectedKey)
            let scoped = shape.hasPrefix("decode:") ? "decode:\(stage):\(shape.dropFirst("decode:".count))" : shape
            return .init(status: .fail, cause: scoped, detail: cause)
        }
        return .init(status: .fail, cause: cause, detail: (error as? LocalizedError)?.errorDescription.map { String($0.prefix(120)) })
    }

    // MARK: Meta

    private func probeMeta(
        source: AppleSource,
        raw: RawManifest?,
        items: [AppleCatalogItem]
    ) async -> (StageOutcome, MetaProbe?) {
        guard source.resources.contains("meta") else { return (.skip("no meta resource"), nil) }
        let prefixes = raw?.prefixes(for: "meta") ?? []
        let ownItem = items.first { item in prefixes.isEmpty || prefixes.contains { item.mediaID.hasPrefix($0) } }
        let target: (type: String, id: String, fromCatalog: Bool)
        if let ownItem {
            target = (ownItem.type, ownItem.mediaID, true)
        } else if raw?.serves("meta", type: "movie", id: Self.movieID) == true {
            target = ("movie", Self.movieID, false)
        } else if items.isEmpty {
            return (.skip("no catalog item to look up"), nil)
        } else {
            return (.skip("no item with the add-on's meta prefix"), nil)
        }

        let recorder = ExchangeRecorder()
        let client = AppleStremioMetadataClient(loader: recorder.wrap(AppleStremioPlaybackClient.liveLoader))
        var probe = MetaProbe(type: target.type, idPrefix: Self.idPrefix(target.id), fromCatalog: target.fromCatalog,
                              outcome: .init(status: .pass))
        do {
            let details = try await withStageTimeout(.seconds(20)) {
                try await client.details(source: source, type: target.type, mediaID: target.id,
                                         isListingSource: target.fromCatalog, fallbackName: ownItem?.name)
            }
            probe.httpStatus = recorder.lastResponse?.status
            probe.outcome = .init(status: .pass, detail: details.title.map { _ in "details ok" } ?? "details (no title)")
        } catch {
            probe.httpStatus = recorder.lastResponse?.status
            probe.outcome = Self.metaFailure(error, recorder: recorder, requestedID: target.id)
        }

        if target.type == "series", AppleStremioMetadataClient.isIMDBIdentifier(target.id) {
            let episodeRecorder = ExchangeRecorder()
            let episodeClient = AppleStremioMetadataClient(
                loader: episodeRecorder.wrap(AppleStremioPlaybackClient.liveLoader)
            )
            do {
                let episodes = try await withStageTimeout(.seconds(20)) {
                    try await episodeClient.episodes(source: source, mediaID: target.id)
                }
                probe.episodeCount = episodes.count
                probe.episodes = .init(status: episodes.isEmpty ? .empty : .pass, detail: "\(episodes.count) episodes")
            } catch {
                var failure = Self.clientFailure(error, recorder: episodeRecorder, expectedKey: "meta", stage: "meta")
                if failure.cause == "decode:meta:meta-rejected",
                   let meta = (Classifier.json(episodeRecorder.lastResponse?.body) as? [String: Any])?["meta"]
                    as? [String: Any], meta["videos"] == nil {
                    failure.cause = meta.isEmpty ? "bad-response:meta-empty" : "bad-response:meta-no-videos"
                }
                probe.episodes = failure
            }
        }
        var outcome = probe.outcome
        outcome.detail = [outcome.detail, "\(target.type) \(probe.idPrefix)…",
                          probe.episodeCount.map { "\($0) eps" }].compactMap { $0 }.joined(separator: " · ")
        return (outcome, probe)
    }

    static func metaFailure(_ error: any Error, recorder: ExchangeRecorder, requestedID: String) -> StageOutcome {
        let cause = Classifier.cause(of: error)
        guard cause == "playback:invalidPayload" else {
            return clientFailure(error, recorder: recorder, expectedKey: "meta", stage: "meta")
        }
        // details() folds non-2xx, redirects, and rejected bodies into
        // invalidPayload; unfold them from the recorded exchange.
        let exchange = recorder.last
        if let transport = Classifier.transportCause(exchange) {
            return .init(status: .fail, cause: transport, detail: "details ← \(transport)")
        }
        if let exchange, let responseURL = exchange.responseURL, let requestURL = exchange.requestURL,
           responseURL != requestURL {
            return .init(status: .fail, cause: "decode:meta:redirect-rejected", detail: "details rejects a redirected response")
        }
        guard let object = Classifier.json(exchange?.body) as? [String: Any],
              let meta = object["meta"] as? [String: Any] else {
            return .init(status: .fail, cause: Classifier.bodyShape(exchange, expectedKey: "meta"), detail: "details")
        }
        let id = (meta["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (meta["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.isEmpty { return .init(status: .fail, cause: "bad-response:meta-no-id", detail: "meta has no id") }
        if id != requestedID {
            return .init(status: .fail, cause: "decode:meta:id-mismatch",
                         detail: "asked \(idPrefix(requestedID))…, got \(idPrefix(id))…")
        }
        if name.isEmpty { return .init(status: .fail, cause: "bad-response:meta-no-name", detail: "meta has no name") }
        return .init(status: .fail, cause: "decode:meta:details-rejected", detail: "meta object rejected by DetailsMeta")
    }

    static func idPrefix(_ id: String) -> String {
        if id.hasPrefix("tt") { return "tt" }
        if let colon = id.firstIndex(of: ":") { return String(id[..<colon].prefix(24)) + ":" }
        return String(id.prefix(6))
    }

    // MARK: Streams

    private func probeStreams(source: AppleSource, raw: RawManifest?) async -> (StageOutcome, [StreamProbe]) {
        guard source.resources.contains("stream") else { return (.skip("no stream resource"), []) }
        let targets: [(type: String, id: String, title: String, episode: (season: Int, episode: Int)?)] = [
            ("movie", Self.movieID, "The Shawshank Redemption", nil),
            ("series", Self.episodeID, "Breaking Bad", (1, 1)),
        ].filter { raw?.serves("stream", type: $0.type, id: $0.id) ?? true }
        guard !targets.isEmpty else { return (.skip("stream not for tt movie/series"), []) }

        var probes: [StreamProbe] = []
        for target in targets {
            let recorder = ExchangeRecorder()
            let client = AppleStremioPlaybackClient(loader: recorder.wrap(AppleStremioPlaybackClient.liveLoader))
            var probe = StreamProbe(type: target.type, mediaID: target.id, outcome: .init(status: .pass))
            do {
                let selection = try await withStageTimeout(.seconds(40)) {
                    try await client.streams(source: source, type: target.type, mediaID: target.id)
                }
                let exchange = recorder.lastResponse
                probe.httpStatus = exchange?.status
                probe.rawCount = ((Classifier.json(exchange?.body) as? [String: Any])?["streams"] as? [Any])?.count
                probe.httpCandidates = selection.httpCandidates.count
                for item in selection.unsupported {
                    probe.unsupported[Self.reasonName(item.reason), default: 0] += 1
                }
                // Exercise the ranking the player runs on these candidates.
                _ = AppleStremioCandidateRanking.rank(selection.httpCandidates)
                _ = AppleStremioCandidateRanking.rankForAutomaticPlayback(
                    selection.httpCandidates, episode: target.episode, title: target.title
                )
                let usable = selection.httpCandidates.count + selection.unsupported.count
                let detail = "\(selection.httpCandidates.count) http"
                    + (selection.unsupported.isEmpty ? "" : " + \(selection.unsupported.count) other")
                if usable == 0 {
                    let rawCount = probe.rawCount ?? 0
                    probe.outcome = .init(status: .empty,
                                          cause: rawCount > 0 ? "decode:stream:all-entries-dropped" : "no-streams",
                                          detail: "0/\(rawCount)")
                } else {
                    probe.outcome = .init(status: .pass, detail: detail)
                }
            } catch {
                probe.httpStatus = recorder.lastResponse?.status
                probe.outcome = Self.clientFailure(error, recorder: recorder, expectedKey: "streams", stage: "stream")
            }
            probes.append(probe)
        }

        let detail = probes.map { "\($0.type == "movie" ? "M" : "S"): \($0.outcome.detail ?? $0.outcome.status.rawValue)" }
            .joined(separator: "; ")
        if let failure = probes.first(where: { [.fail, .timeout].contains($0.outcome.status) }) {
            return (.init(status: failure.outcome.status, cause: failure.outcome.cause, detail: detail), probes)
        }
        if probes.allSatisfy({ $0.outcome.status == .empty }) {
            return (.init(status: .empty, cause: probes.first?.outcome.cause, detail: detail), probes)
        }
        return (.init(status: .pass, detail: detail), probes)
    }

    static func reasonName(_ reason: AppleStremioUnsupportedReason) -> String {
        switch reason {
        case .externalLink: "externalLink"
        case .youtube: "youtube"
        case .invalidHTTPURL: "invalidHTTPURL"
        case .invalidLocator: "invalidLocator"
        case .missingLocator: "missingLocator"
        }
    }

    // MARK: Subtitles

    private func probeSubtitles(source: AppleSource, raw: RawManifest?) async -> (StageOutcome, SubtitleProbe?) {
        guard source.resources.contains("subtitles") else { return (.skip("no subtitles resource"), nil) }
        guard raw?.serves("subtitles", type: "movie", id: Self.movieID) ?? true else {
            return (.skip("subtitles not for tt movies"), nil)
        }
        let recorder = ExchangeRecorder()
        let client = AppleStremioPlaybackClient(loader: recorder.wrap(AppleStremioPlaybackClient.liveLoader))
        let service = AppleExternalSubtitleService(client: client, timeout: .seconds(20))
        guard let query = AppleExternalSubtitleQuery(type: "movie", mediaID: Self.movieID) else {
            return (.skip("query rejected"), nil)
        }
        var probe = SubtitleProbe(outcome: .init(status: .pass))
        do {
            let english = try await withStageTimeout(.seconds(25)) {
                await service.tracks(for: query, sources: [source], preferredLanguages: ["en"])
            }
            probe.englishTracksFromService = english.count
        } catch {
            probe.outcome = .init(status: .timeout, cause: "timeout", detail: "service > 25 s")
            return (probe.outcome, probe)
        }
        // The service fails open (errors become "no tracks"), so explain the
        // answer with the app's own parser on the recorded body.
        let exchange = recorder.lastResponse
        probe.httpStatus = exchange?.status
        if let transport = Classifier.transportCause(recorder.last) {
            probe.outcome = .init(status: transport == "transport:timedOut" ? .timeout : .fail,
                                  cause: transport, detail: "service swallowed \(transport)")
            return (probe.outcome, probe)
        }
        guard let body = exchange?.body else {
            probe.outcome = .init(status: .timeout, cause: "timeout", detail: "no answer inside the service window")
            return (probe.outcome, probe)
        }
        probe.rawCount = ((Classifier.json(body) as? [String: Any])?["subtitles"] as? [Any])?.count
        do {
            let parsed = try AppleStremioPlaybackClient.parseSubtitles(body)
            probe.parsedTracks = parsed.count
            let detail = "\(parsed.count)/\(probe.rawCount ?? 0) tracks, \(probe.englishTracksFromService ?? 0) en"
            if parsed.isEmpty {
                probe.outcome = .init(status: .empty,
                                      cause: (probe.rawCount ?? 0) > 0 ? "decode:subtitles:all-tracks-dropped" : "no-subtitles",
                                      detail: detail)
            } else {
                probe.outcome = .init(status: .pass, detail: detail)
            }
        } catch {
            let shape = Classifier.bodyShape(exchange, expectedKey: "subtitles")
            probe.outcome = .init(status: .fail,
                                  cause: shape.hasPrefix("decode:") ? "decode:subtitles:envelope-rejected" : shape,
                                  detail: Classifier.cause(of: error))
        }
        return (probe.outcome, probe)
    }
}

#endif

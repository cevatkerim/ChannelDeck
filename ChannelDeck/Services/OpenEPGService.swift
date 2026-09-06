import Foundation

struct OpenEPGResult: Sendable {
    let rows: [GuideMatchRow]
    let candidates: [GuideChannel]
    let programmes: [ParsedProgramme]
    let warnings: [String]
}

/// Public guide data only. Playlist addresses and credentials never leave the existing provider transport.
actor OpenEPGService {
    static let shared = OpenEPGService()
    private let client: HTTPClient
    private let cacheDirectory: URL
    private var inFlight: [String: Task<Data, Error>] = [:]
    init(client: HTTPClient = HTTPClient(), cacheDirectory: URL? = nil) {
        self.client = client
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChannelDeck/OpenEPG", isDirectory: true)
    }

    func refresh(channels: [ParsedChannel], sourceID: UUID, preferences: GuidePreferences,
                 progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> OpenEPGResult {
        let live = channels.filter(EPGMatcher.isLive)
        guard !live.isEmpty else { return OpenEPGResult(rows: [], candidates: [], programmes: [], warnings: []) }
        let countries = Set(live.compactMap { EPGMatcher.country(for: $0) })
        await progress("Discovering country guides…")
        let catalogData = try await cached(URL(string: "https://www.open-epg.com/app/epgfetch.php")!)
        var seenFeeds: Set<URL> = []
        let catalog = try JSONDecoder().decode([OpenEPGFeed].self, from: catalogData)
            .filter { $0.isAllowed && seenFeeds.insert($0.url).inserted }
        let feeds = catalog.filter { countries.contains($0.country) }
        // Include explicitly selected feeds even if a provider did not label the channel's country.
        let selected = catalog.filter { feed in
            feeds.contains(feed) || preferences.overrides.values.contains { $0.hasPrefix(feed.url.absoluteString + "#") }
        }
        var candidates: [GuideChannel] = []
        var warnings: [String] = []
        for (index, feed) in selected.enumerated() {
            await progress("Loading \(feed.cou) · guide \(index + 1) of \(selected.count)…")
            try Task.checkCancellation()
            do {
                let data = try await cached(feed.url)
                let parsed = try await Task.detached(priority: .utility) {
                    try GuideChannelParser.parse(data, feed: feed)
                }.value
                candidates.append(contentsOf: parsed)
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("\(feed.cou): guide unavailable") }
        }
        let availableCountries = Set(selected.map(\.country))
        let missing = countries.subtracting(availableCountries).sorted()
        if !missing.isEmpty { warnings.append("No published feed for: " + missing.joined(separator: ", ").uppercased()) }
        await progress("Matching \(live.count) live channels…")
        let allCandidates = candidates
        let rows = await Task.detached(priority: .utility) {
            let byCountry = Dictionary(grouping: allCandidates, by: { $0.feed.country })
            let normalizedNames = Dictionary(allCandidates.map { ($0.id, EPGMatcher.normalized($0.name, country: $0.feed.country)) }, uniquingKeysWith: { first, _ in first })
            let normalizedIDs = Dictionary(allCandidates.map { ($0.id, EPGMatcher.normalized($0.channelID, country: $0.feed.country)) }, uniquingKeysWith: { first, _ in first })
            return live.map { channel in
                let hasOverride = preferences.overrides[channel.stableKey(sourceID: sourceID).rawValue] != nil
                let scoped = hasOverride ? allCandidates : (EPGMatcher.country(for: channel).flatMap { byCountry[$0] } ?? allCandidates)
                return EPGMatcher.match(channel, sourceID: sourceID, candidates: scoped, overrides: preferences.overrides, normalizedNames: normalizedNames, normalizedIDs: normalizedIDs)
            }
        }.value
        var output: [ParsedProgramme] = []
        let byFeed = Dictionary(grouping: rows.filter { $0.match != nil }, by: { $0.match!.feed })
        for (feed, matchedRows) in byFeed {
            await progress("Reading \(feed.cou) programme listings…")
            try Task.checkCancellation()
            do {
                let data = try await cached(feed.url)
                let programmes = try await Task.detached(priority: .utility) {
                    let targets = Dictionary(grouping: matchedRows, by: { $0.match!.channelID })
                    return try XMLTVParser().parse(data: data, channelIDs: Set(targets.keys),
                        timeWindow: Date.now.addingTimeInterval(-7200)..<Date.now.addingTimeInterval(36 * 3600))
                        .flatMap { programme in
                            (targets[programme.channelID] ?? []).map { row in
                                ParsedProgramme(channelID: row.id, title: programme.title, subtitle: programme.subtitle,
                                    description: programme.description, categories: programme.categories,
                                    start: programme.start, end: programme.end)
                            }
                        }
                }.value
                output.append(contentsOf: programmes)
                if programmes.isEmpty { warnings.append("\(feed.cou): no current schedules for matched channels") }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("\(feed.cou): schedules unavailable") }
        }
        return OpenEPGResult(rows: rows, candidates: candidates, programmes: output, warnings: warnings)
    }

    /// Shared disk cache and single-flight downloads; even forced playlist refreshes respect 24 hours.
    private func cached(_ url: URL) async throws -> Data {
        let key = url.lastPathComponent
        if let pending = inFlight[key] { return try await pending.value }
        let directory = cacheDirectory
        let client = client
        let task = Task.detached(priority: .utility) {
            let file = directory.appendingPathComponent(key)
            let attemptFile = directory.appendingPathComponent(key + ".attempt")
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let date = attributes?[.modificationDate] as? Date
            if let date, Date.now.timeIntervalSince(date) < 86400 { return try Data(contentsOf: file) }
            let diskAttempt = (try? FileManager.default.attributesOfItem(atPath: attemptFile.path))?[.modificationDate] as? Date
            if let recent = diskAttempt, Date.now.timeIntervalSince(recent) < 86400 {
                if let data = try? Data(contentsOf: file) { return data }
                throw HTTPClientError.invalidResponse
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: attemptFile, options: .atomic)
                let response = try await client.fetch(url, policy: .epg)
                guard case .modified(let payload) = response else { throw HTTPClientError.invalidResponse }
                if url.pathExtension == "xml" {
                    _ = try GuideChannelParser.parse(payload.data, feed: OpenEPGFeed(cou: "", url: url, img: ""))
                } else { _ = try JSONDecoder().decode([OpenEPGFeed].self, from: payload.data) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try payload.data.write(to: file, options: .atomic)
                return payload.data
            } catch {
                if let data = try? Data(contentsOf: file) { return data }
                throw error
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

private final class GuideChannelParser: NSObject, XMLParserDelegate {
    let feed: OpenEPGFeed
    var channels: [GuideChannel] = []
    var channelID: String?
    var name = ""
    var readingName = false
    var hasTVRoot = false
    init(feed: OpenEPGFeed) { self.feed = feed }
    static func parse(_ data: Data, feed: OpenEPGFeed) throws -> [GuideChannel] {
        let delegate = GuideChannelParser(feed: feed)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.hasTVRoot else { throw ParserError.malformedXML }
        return delegate.channels
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "tv" { hasTVRoot = true }
        if elementName == "channel" { channelID = attributes["id"]; name = "" }
        if elementName == "display-name", channelID != nil, name.isEmpty { readingName = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if readingName { name += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "display-name" { readingName = false }
        if elementName == "channel", let id = channelID {
            channels.append(GuideChannel(feed: feed, channelID: id, name: name.isEmpty ? id : name))
            channelID = nil
        }
    }
}

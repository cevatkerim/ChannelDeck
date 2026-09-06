import CryptoKit
import Foundation
import Observation

struct TVSource: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var guide: GuidePreferences?
    var guidePreferences: GuidePreferences { guide ?? GuidePreferences(mode: .automatic) }
}

struct TVChannel: Identifiable, Sendable {
    let id: String
    let sourceID: UUID
    let name: String
    let group: String
    let tvgID: String?
    let logoURL: URL?
    let streamURL: URL
    let order: Int
    var preferenceID: String { Self.preferenceID(id) }
    static func preferenceID(_ id: String) -> String {
        Data(SHA256.hash(data: Data(id.utf8))).base64EncodedString()
    }
}

struct TVUserState: Codable, Equatable {
    var sources: [TVSource] = []
    var favorites: Set<String> = []
    var recents: [String] = []
    var watchCounts: [String: Int]?
    var bufferMinutes = 10
    static let key = "channelDeck.tv.library.v1"
    // tvOS defaults have a 500 KB limit. Leave headroom for framework settings.
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count < 400 * 1024 else { throw TVLibraryError.preferencesFull }
        return data
    }
}

enum TVLibraryError: LocalizedError {
    case invalidURL, invalidName, response(Int), tooLarge, preferencesFull, missingCredential
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS address."
        case .invalidName: "Enter a playlist name."
        case .response(let code): "The provider returned HTTP \(code)."
        case .tooLarge: "The provider response exceeds the size limit."
        case .preferencesFull: "The saved library settings are full. Remove an unused source or favorite and retry."
        case .missingCredential: "This playlist needs its address entered again in Settings."
        }
    }
}

final class TVRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { SourceURLPolicy.validatedURL(from: $0.absoluteString) } == nil ? nil : request)
    }
}

struct TVHTTPClient: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard SourceURLPolicy.validatedURL(from: url.absoluteString) != nil else { throw TVLibraryError.invalidURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: TVRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw TVLibraryError.response(0) }
        guard (200..<300).contains(response.statusCode) else { throw TVLibraryError.response(response.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw TVLibraryError.tooLarge }
        var data = Data()
        for try await byte in stream {
            if data.count.isMultiple(of: 65536) { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw TVLibraryError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

@MainActor @Observable
final class TVLibrary {
    private(set) var state: TVUserState
    private(set) var channels: [TVChannel] = []
    private(set) var schedules: [String: [ParsedProgramme]] = [:]
    private(set) var groups: [TVChannelGroup] = []
    private(set) var refreshing: Set<UUID> = []
    private(set) var sourceErrors: [UUID: String] = [:]
    private(set) var guideProgress: [UUID: String] = [:]
    private(set) var guideResults: [UUID: OpenEPGResult] = [:]
    private(set) var revision = 0
    let artwork = TVArtworkLibrary()
    var notice: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any KeychainStoring
    @ObservationIgnored private let encryptedCache: EncryptedPlaylistCache
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var perSource: [UUID: [TVChannel]] = [:]
    @ObservationIgnored private var programmes: [UUID: [ParsedProgramme]] = [:]
    @ObservationIgnored private var searchIndex = ChannelSearchIndex()
    @ObservationIgnored private var channelLookup: [String: TVChannel] = [:]
    @ObservationIgnored private var guideIndex = GuideSearchIndex()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshGenerations: [UUID: UUID] = [:]
    @ObservationIgnored private var lastScheduledRefresh = Date.now

    init(defaults: UserDefaults = .standard, keychain: any KeychainStoring = KeychainStore(service: "com.kerimincedayi.ChannelDeckTV.sources"), directory: URL? = nil) {
        self.defaults = defaults
        self.keychain = keychain
        self.directory = directory ?? URL.cachesDirectory.appending(path: "ChannelDeckTV/Library", directoryHint: .isDirectory)
        encryptedCache = EncryptedPlaylistCache(keyStore: keychain, directoryURL: self.directory.appending(path: "Playlists"))
        state = defaults.data(forKey: TVUserState.key).flatMap { try? JSONDecoder().decode(TVUserState.self, from: $0) } ?? TVUserState()
    }

    var sources: [TVSource] { state.sources }
    var favorites: [TVChannel] { channels.filter { state.favorites.contains($0.preferenceID) } }
    var recents: [TVChannel] {
        let lookup = Dictionary(channels.map { ($0.preferenceID, $0) }, uniquingKeysWith: { first, _ in first })
        return state.recents.compactMap { lookup[$0] }
    }

    var shelfChannels: [TVChannel] { Self.shelfChannels(channels: channels, state: state) }
    nonisolated static func shelfChannels(channels: [TVChannel], state: TVUserState) -> [TVChannel] {
        let counts = state.watchCounts ?? [:]
        let recentOrder = Dictionary(state.recents.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let frequent = channels.filter { counts[$0.preferenceID] != nil || recentOrder[$0.preferenceID] != nil }
            .sorted {
                let a = counts[$0.preferenceID] ?? 0, b = counts[$1.preferenceID] ?? 0
                return a == b ? (recentOrder[$0.preferenceID] ?? Int.max) < (recentOrder[$1.preferenceID] ?? Int.max) : a > b
            }
        let pinned = Array(channels.filter { state.favorites.contains($0.preferenceID) }.prefix(6))
        let ids = Set(pinned.map(\.id))
        return Array(frequent.filter { !ids.contains($0.id) }.prefix(6)) + pinned
    }
    func channel(forShelfURL url: URL) -> TVChannel? {
        guard let key = TVShelfStore.channelKey(from: url) else { return nil }
        return channels.first { TVShelfStore.key($0.id) == key }
    }

    func advanceGuideClock() {
        revision &+= 1
        guard Date.now.timeIntervalSince(lastScheduledRefresh) >= 6 * 3600 else { return }
        lastScheduledRefresh = .now
        let pending = sources.filter { !refreshing.contains($0.id) }
        Task { for source in pending { await refresh(source) } }
    }

    func bootstrap() async {
        guard !started else { return }
        started = true
        for source in sources {
            do {
                if let bytes = try await encryptedCache.load(for: source.id), let url = try await keychain.playlistURL(for: source.id) {
                    let parsed = try await Task.detached { try M3UParser().parse(data: bytes, baseURL: url) }.value
                    install(parsed, source: source)
                }
                let cache = guideCacheURL(source.id)
                if let data = try? Data(contentsOf: cache), let guide = try? JSONDecoder().decode([ParsedProgramme].self, from: data) {
                    programmes[source.id] = guide.filter { $0.end > .now }
                }
            } catch { sourceErrors[source.id] = "The cached playlist needs to be refreshed." }
        }
        rebuild()
        let savedSources = sources
#if DEBUG
        // UI tests browse a fixed imported snapshot. Explicit fixture imports
        // still refresh, and source/network behavior has separate tests.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
#endif
        Task { for source in savedSources { await refresh(source) } }
    }

    func sourceAddresses(_ source: TVSource) async throws -> (String, String) {
        (try await keychain.playlistURL(for: source.id)?.absoluteString ?? "",
         try await keychain.epgURL(for: source.id)?.absoluteString ?? "")
    }

    func save(source: TVSource?, name: String, playlist: String, guide: String, mode: GuideProviderMode = .automatic) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw TVLibraryError.invalidName }
        guard let url = SourceURLPolicy.validatedURL(from: playlist) else { throw TVLibraryError.invalidURL }
        let guideText = guide.trimmingCharacters(in: .whitespacesAndNewlines)
        let guideURL = SourceURLPolicy.validatedURL(from: guideText)
        guard guideText.isEmpty || guideURL != nil else { throw TVLibraryError.invalidURL }
        var value = source ?? TVSource(name: name)
        value.name = name
        value.guide = value.guidePreferences
        value.guide?.mode = mode
        var updated = state
        if let offset = updated.sources.firstIndex(where: { $0.id == value.id }) { updated.sources[offset] = value }
        else { updated.sources.append(value) }
        _ = try updated.encoded()
        let previousURL = try await keychain.playlistURL(for: value.id)
        let previousGuide = try await keychain.epgURL(for: value.id)
        do {
            try await keychain.setPlaylistURL(url, for: value.id)
            try await keychain.setEPGURL(guideURL, for: value.id)
            try persist(updated)
        } catch {
            if let previousURL { try? await keychain.setPlaylistURL(previousURL, for: value.id) }
            else { try? await keychain.removeData(for: value.id, kind: .playlistURL) }
            try? await keychain.setEPGURL(previousGuide, for: value.id)
            throw error
        }
        let saved = value
        Task { await refresh(saved) }
    }

    func remove(_ source: TVSource) async {
        do {
            refreshTasks[source.id]?.cancel()
            refreshTasks[source.id] = nil
            refreshGenerations[source.id] = nil
            refreshing.remove(source.id)
            guideProgress[source.id] = nil
            guideResults[source.id] = nil
            var updated = state
            updated.sources.removeAll { $0.id == source.id }
            let removed = Set((perSource[source.id] ?? []).map(\.preferenceID))
            updated.favorites.subtract(removed)
            updated.recents.removeAll { removed.contains($0) }
            updated.watchCounts = updated.watchCounts?.filter { !removed.contains($0.key) }
            try await encryptedCache.remove(for: source.id)
            try await keychain.removeAll(for: source.id)
            try persist(updated)
            try? FileManager.default.removeItem(at: guideCacheURL(source.id))
            perSource[source.id] = nil; programmes[source.id] = nil; sourceErrors[source.id] = nil
            rebuild()
        } catch { notice = "The playlist could not be fully removed. Retry in Settings." }
    }

    func refresh(_ source: TVSource) async {
        guard let source = sources.first(where: { $0.id == source.id }) else { return }
        refreshTasks[source.id]?.cancel()
        let generation = UUID()
        refreshGenerations[source.id] = generation
        refreshing.insert(source.id)
        let task = Task { await performRefresh(source, generation: generation) }
        refreshTasks[source.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if refreshGenerations[source.id] == generation {
            refreshTasks[source.id] = nil
            refreshing.remove(source.id)
            guideProgress[source.id] = nil
        }
    }
    private func performRefresh(_ source: TVSource, generation: UUID) async {
        do {
            guard let url = try await keychain.playlistURL(for: source.id) else { throw TVLibraryError.missingCredential }
            let data = try await TVHTTPClient().fetch(url, maximumBytes: 50 * 1024 * 1024)
            let parsed = try await Task.detached { try M3UParser().parse(data: data, baseURL: url) }.value
            guard !Task.isCancelled, refreshGenerations[source.id] == generation, sources.contains(where: { $0.id == source.id }) else { return }
            try await encryptedCache.store(data, for: source.id)
            guard !Task.isCancelled, refreshGenerations[source.id] == generation else { return }
            install(parsed, source: source)
            sourceErrors[source.id] = nil
            await refreshGuide(parsed, source: source, generation: generation)
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled && refreshGenerations[source.id] == generation { sourceErrors[source.id] = Self.safeMessage(error) }
        }
    }

    private func refreshGuide(_ playlist: ParsedPlaylist, source: TVSource, generation: UUID) async {
        let preferences = source.guidePreferences
        var guide: [ParsedProgramme] = []
        var warnings: [String] = []
        if preferences.mode != .openEPG {
            do {
                if let url = try await keychain.epgURL(for: source.id) ?? playlist.epgURLs.first {
                    guideProgress[source.id] = "Loading playlist guide…"
                    let data = try await TVHTTPClient().fetch(url, maximumBytes: 100 * 1024 * 1024)
                    guide = try await Task.detached {
                        let xml = data.starts(with: [0x1f, 0x8b]) ? try GzipDecompressor.decompress(data, maximumExpandedBytes: 200 * 1024 * 1024) : data
                        let items = try XMLTVParser().parse(data: xml, channelIDs: Set(playlist.channels.compactMap(\.tvgID)), timeWindow: Date.now.addingTimeInterval(-3600)..<Date.now.addingTimeInterval(7 * 86400))
                        return Self.stableProgrammes(items, channels: playlist.channels, sourceID: source.id)
                    }.value
                }
            } catch is CancellationError { return }
            catch { warnings.append("The playlist guide is unavailable.") }
        }
        if preferences.mode != .playlist {
            do {
                let result = try await OpenEPGService.shared.refresh(channels: playlist.channels, sourceID: source.id, preferences: preferences) { [weak self] message in
                    await MainActor.run {
                        guard self?.refreshGenerations[source.id] == generation else { return }
                        self?.guideProgress[source.id] = message
                    }
                }
                guard !Task.isCancelled, refreshGenerations[source.id] == generation else { return }
                guideResults[source.id] = result
                let covered = Set(guide.map(\.channelID))
                let supplemental = result.programmes.filter { !covered.contains($0.channelID) || preferences.overrides[$0.channelID].map { !$0.isEmpty } == true }
                let replaced = Set(supplemental.map(\.channelID))
                guide.removeAll { replaced.contains($0.channelID) }
                guide.append(contentsOf: supplemental)
                warnings.append(contentsOf: result.warnings)
            } catch is CancellationError { return }
            catch { warnings.append("Open-EPG is unavailable. Saved listings remain available.") }
        } else { guideResults[source.id] = nil }
        guard !Task.isCancelled, refreshGenerations[source.id] == generation, sources.contains(where: { $0.id == source.id }) else { return }
        // Keep current cached listings for feeds that failed during this refresh.
        let replaced = Set(guide.map(\.channelID))
        let retained = (programmes[source.id] ?? []).filter { $0.end > .now && !replaced.contains($0.channelID) && preferences.overrides[$0.channelID] != "" }
        programmes[source.id] = retained + guide
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(programmes[source.id] ?? []) { try? encoded.write(to: guideCacheURL(source.id), options: .atomic) }
        sourceErrors[source.id] = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        rebuild()
    }

    nonisolated static func stableProgrammes(_ items: [ParsedProgramme], channels: [ParsedChannel], sourceID: UUID) -> [ParsedProgramme] {
        let targets = Dictionary(grouping: channels.filter { $0.tvgID != nil }, by: { $0.tvgID! })
        return items.flatMap { item in
            (targets[item.channelID] ?? []).map { channel in
                ParsedProgramme(channelID: channel.stableKey(sourceID: sourceID).rawValue, title: item.title, subtitle: item.subtitle,
                                description: item.description, categories: item.categories, start: item.start, end: item.end)
            }
        }
    }

    func setGuideMatch(sourceID: UUID, channelID: String, candidateID: String?) {
        guard let offset = state.sources.firstIndex(where: { $0.id == sourceID }) else { return }
        var updated = state
        var preferences = updated.sources[offset].guidePreferences
        preferences.overrides[channelID] = candidateID
        updated.sources[offset].guide = preferences
        do {
            try persist(updated)
            let source = updated.sources[offset]
            Task { await refresh(source) }
        } catch { notice = Self.safeMessage(error) }
    }

    func isFavorite(_ channel: TVChannel) -> Bool { state.favorites.contains(channel.preferenceID) }
    func toggleFavorite(_ channel: TVChannel) {
        var updated = state
        if updated.favorites.contains(channel.preferenceID) { updated.favorites.remove(channel.preferenceID) }
        else { updated.favorites.insert(channel.preferenceID) }
        do { try persist(updated); rebuild() } catch { notice = Self.safeMessage(error) }
    }
    func watched(_ channel: TVChannel) {
        var updated = state
        updated.recents.removeAll { $0 == channel.preferenceID }
        updated.recents.insert(channel.preferenceID, at: 0)
        updated.recents = Array(updated.recents.prefix(30))
        var counts = updated.watchCounts ?? [:]
        counts[channel.preferenceID] = min(99999, (counts[channel.preferenceID] ?? 0) + 1)
        if counts.count > 128 { counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) }) }
        updated.watchCounts = counts
        try? persist(updated)
    }
    func setBufferMinutes(_ minutes: Int) {
        var updated = state; updated.bufferMinutes = minutes == 5 ? 5 : 10
        do { try persist(updated) } catch { notice = Self.safeMessage(error) }
    }
    func current(_ channel: TVChannel, at date: Date = .now) -> ParsedProgramme? {
        schedules[channel.id]?.first { $0.isAiring(at: date) }
    }
    func search(_ query: String, guide: Bool = false, page: Int = 0) async -> [TVChannel] {
        let index = searchIndex, guideSnapshot = guideIndex
        let worker = Task.detached {
            if guide {
                return (try? guideSnapshot.matchingIDs(for: GuideSearchRequest(query: query, scope: .all, window: GuideWindow(containing: .now, page: page), listingsOnly: false), preferences: LibraryPreferences())) ?? []
            }
            return query.isEmpty ? index.entries.map(\.stableID) : index.matchingIDs(for: query)
        }
        let ids = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return [] }
        return ids.compactMap { channelLookup[$0] }
    }
    private func persist(_ value: TVUserState) throws {
        defaults.set(try value.encoded(), forKey: TVUserState.key); state = value
    }
    private func guideCacheURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).guide.json") }
    private func install(_ playlist: ParsedPlaylist, source: TVSource) {
        var seen = Set<String>()
        perSource[source.id] = playlist.channels.filter(EPGMatcher.isLive).compactMap { item in
            let id = item.stableKey(sourceID: source.id).rawValue
            guard seen.insert(id).inserted, SourceURLPolicy.validatedURL(from: item.streamURL.absoluteString) != nil else { return nil }
            return TVChannel(id: id, sourceID: source.id, name: item.name, group: item.group ?? "Ungrouped", tvgID: item.tvgID,
                             logoURL: item.logoURL, streamURL: item.streamURL, order: item.order)
        }
        rebuild()
    }
    private func rebuild() {
        channels = sources.flatMap { perSource[$0.id] ?? [] }
        groups = TVChannelGroup.groups(in: channels)
        channelLookup = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        schedules = [:]
        var entries: [ChannelSearchEntry] = []
        for (sourceOrder, source) in sources.enumerated() {
            let guide = Dictionary(grouping: programmes[source.id] ?? [], by: \.channelID)
            for channel in perSource[source.id] ?? [] {
                schedules[channel.id] = (guide[channel.id] ?? guide[channel.tvgID ?? ""] ?? []).sorted { $0.start < $1.start }
                entries.append(ChannelSearchEntry(stableID: channel.id, channelName: channel.name, groupName: channel.group, sourceName: source.name, sourceOrder: sourceOrder, channelOrder: channel.order))
            }
        }
        searchIndex = ChannelSearchIndex(entries: entries)
        guideIndex.replaceChannels(channels.map { GuideSearchChannel(stableID: $0.id, sourceID: $0.sourceID, name: $0.name, groupName: $0.group) }, favoriteIDs: Set(favorites.map(\.id)))
        guideIndex.replaceProgrammes(schedules.flatMap { id, programmes in programmes.map { GuideSearchProgramme(channelID: id, title: $0.title, start: $0.start, end: $0.end) } })
        revision &+= 1
    }
    nonisolated static func safeMessage(_ error: any Error) -> String {
        if let error = error as? TVLibraryError { return error.localizedDescription }
        if let error = error as? ParserError { return error.localizedDescription }
        return "The source could not be loaded. Check its address and your connection, then retry."
    }
}

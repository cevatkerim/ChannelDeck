import CryptoKit
import Foundation
import Observation
import SwiftData

enum SidebarSelection: Hashable {
    case favorites
    case recents
    case source(UUID)
    case group(UUID, String)
}

struct SourceDraft: Equatable {
    var displayName = ""
    var playlistURL = ""
    var epgURL = ""
}

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let sourceID: UUID?

    init(title: String, message: String, sourceID: UUID? = nil) {
        self.title = title
        self.message = message
        self.sourceID = sourceID
    }
}

@MainActor
@Observable
final class AppModel {
    let playerController: PlayerController
    let airPlayRelayController: AirPlayRelayController

    var sources: [PlaylistSourceRecord] = []
    var channels: [ChannelRecord] = []
    var programmes: [ProgrammeRecord] = []
    var recents: [RecentChannelRecord] = []

    var sidebarSelection: SidebarSelection? = .favorites
    var selectedChannelID: String?
    var searchText = ""
    var refreshingSourceIDs: Set<UUID> = []

    var isPresentingSourceEditor = false
    var isSavingSource = false
    var sourceDraft = SourceDraft()
    var sourceEditorError: String?
    var presentedAlert: AppAlert?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let keychain: any KeychainStoring
    @ObservationIgnored private let encryptedCache: EncryptedPlaylistCache
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored private let m3uParser = M3UParser()
    @ObservationIgnored private let xmlTVParser = XMLTVParser()
    @ObservationIgnored private var runtimePlaylists: [UUID: ParsedPlaylist] = [:]
    @ObservationIgnored private var streamURLs: [String: URL] = [:]
    @ObservationIgnored private var editingSourceID: UUID?
    @ObservationIgnored private var pendingRecentChannelID: String?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var playbackPreparationTask: Task<Void, Never>?

    init(
        modelContainer: ModelContainer,
        playerController: PlayerController = PlayerController(),
        keychain: (any KeychainStoring)? = nil,
        httpClient: HTTPClient = HTTPClient()
    ) {
        self.modelContext = ModelContext(modelContainer)
        self.playerController = playerController
        let resolvedKeychain = keychain ?? KeychainStore()
        self.keychain = resolvedKeychain
        self.airPlayRelayController = AirPlayRelayController(keychain: resolvedKeychain)
        self.encryptedCache = EncryptedPlaylistCache(keyStore: resolvedKeychain)
        self.httpClient = httpClient
        reloadLocalState()
        observePlaybackForRecents()
    }

    var selectedChannel: ChannelRecord? {
        guard let selectedChannelID else { return nil }
        return channel(withID: selectedChannelID)
    }

    var filteredChannels: [ChannelRecord] {
        let base: [ChannelRecord]
        switch sidebarSelection {
        case .favorites:
            base = channels.filter(\.isFavorite)
        case .recents:
            let positions = Dictionary(uniqueKeysWithValues: recents.enumerated().map { ($0.element.channelStableID, $0.offset) })
            base = channels
                .filter { positions[$0.stableID] != nil }
                .sorted { (positions[$0.stableID] ?? .max) < (positions[$1.stableID] ?? .max) }
        case .source(let sourceID):
            base = channels.filter { $0.sourceID == sourceID }
        case .group(let sourceID, let group):
            base = channels.filter { $0.sourceID == sourceID && $0.groupName == group }
        case nil:
            base = channels
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { channel in
            channel.name.localizedStandardContains(query)
                || channel.groupName.localizedStandardContains(query)
                || currentProgramme(for: channel)?.title.localizedStandardContains(query) == true
                || nextProgramme(for: channel)?.title.localizedStandardContains(query) == true
        }
    }

    var browserTitle: String {
        switch sidebarSelection {
        case .favorites: "Favorites"
        case .recents: "Recently Watched"
        case .source(let id): source(withID: id)?.displayName ?? "Channels"
        case .group(_, let group): group
        case nil: "Channels"
        }
    }

    var isEditingSource: Bool { editingSourceID != nil }
    var sourceEditorTitle: String { isEditingSource ? "Edit Playlist" : "Add Playlist" }

    var canCommitSourceDraft: Bool {
        guard let url = URL(string: sourceDraft.playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        reloadLocalState()
        Task { [airPlayRelayController] in
            await airPlayRelayController.bootstrap()
        }

        if sources.isEmpty {
            beginAddingSource()
            return
        }

        for source in sources {
            await loadCachedPlaylist(for: source.id)
        }

        if case .favorites = sidebarSelection, let firstSource = sources.first {
            sidebarSelection = .source(firstSource.id)
        }

        for source in sources {
            if refreshIsDue(lastRefresh: source.lastPlaylistRefresh, interval: 6 * 60 * 60) {
                await refresh(sourceID: source.id, force: false)
            }
        }
    }

    func groups(for sourceID: UUID) -> [String] {
        Array(Set(channels.lazy.filter { $0.sourceID == sourceID }.map(\.groupName)))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func sourceID(for selection: SidebarSelection?) -> UUID? {
        switch selection {
        case .source(let id), .group(let id, _): id
        default: nil
        }
    }

    func channel(withID stableID: String) -> ChannelRecord? {
        channels.first { $0.stableID == stableID }
    }

    func currentProgramme(for channel: ChannelRecord, at date: Date = .now) -> ProgrammeRecord? {
        programmes
            .filter { $0.channelStableID == channel.stableID && $0.startDate <= date && date < $0.endDate }
            .max { $0.startDate < $1.startDate }
    }

    func nextProgramme(for channel: ChannelRecord, at date: Date = .now) -> ProgrammeRecord? {
        let threshold = currentProgramme(for: channel, at: date)?.endDate ?? date
        return programmes
            .filter { $0.channelStableID == channel.stableID && $0.startDate >= threshold }
            .min { $0.startDate < $1.startDate }
    }

    func isPlaying(_ channel: ChannelRecord) -> Bool {
        selectedChannelID == channel.stableID && playerController.state != .idle
    }

    func play(_ channel: ChannelRecord) {
        selectedChannelID = channel.stableID
        guard channel.isTransportAllowed else {
            presentedAlert = AppAlert(
                title: "Insecure Stream Blocked",
                message: "This channel uses an HTTP media host that ChannelDeck has not been configured to trust."
            )
            return
        }
        guard let streamURL = streamURLs[channel.stableID] else {
            presentedAlert = AppAlert(
                title: "Channel Needs Refresh",
                message: "The protected stream address is not loaded. Refresh this playlist and try again."
            )
            return
        }

        playbackPreparationTask?.cancel()
        playerController.stop()
        pendingRecentChannelID = channel.stableID
        let stableID = channel.stableID
        let channelName = channel.name
        playbackPreparationTask = Task { [weak self] in
            guard let self else { return }
            let playbackURL = await airPlayRelayController.playbackURL(for: streamURL)
            guard !Task.isCancelled, selectedChannelID == stableID else { return }
            playerController.play(url: playbackURL, channelName: channelName)
        }
    }

    func toggleFavorite(_ channel: ChannelRecord) {
        channel.isFavorite.toggle()
        saveContext(showingErrorAs: "Favorite Could Not Be Saved")
        reloadLocalState()
    }

    func refreshSelection(force: Bool) async {
        guard let sourceID = sourceID(for: sidebarSelection) else { return }
        await refresh(sourceID: sourceID, force: force)
    }

    func refresh(sourceID: UUID, force: Bool) async {
        guard !refreshingSourceIDs.contains(sourceID), let initialSource = source(withID: sourceID) else { return }
        if !force,
           !refreshIsDue(lastRefresh: initialSource.lastPlaylistRefresh, interval: 6 * 60 * 60),
           runtimePlaylists[sourceID] != nil {
            return
        }

        refreshingSourceIDs.insert(sourceID)
        defer { refreshingSourceIDs.remove(sourceID) }

        do {
            guard let playlistURL = try await keychain.playlistURL(for: sourceID) else {
                throw AppModelError.missingSourceCredential
            }
            let validators = HTTPValidators(
                etag: initialSource.playlistETag,
                lastModified: initialSource.playlistLastModified
            )

            let fetchResult = try await httpClient.fetch(
                playlistURL,
                validators: validators,
                policy: .playlist
            )

            let parsedPlaylist: ParsedPlaylist
            let responseValidators: HTTPValidators
            switch fetchResult {
            case .modified(let payload):
                parsedPlaylist = try await parsePlaylist(payload.data, baseURL: playlistURL)
                try await encryptedCache.store(payload.data, for: sourceID)
                responseValidators = payload.validators
                try apply(parsedPlaylist, to: sourceID)
            case .notModified(let validators):
                responseValidators = validators
                if let loaded = runtimePlaylists[sourceID] {
                    parsedPlaylist = loaded
                } else {
                    guard let cachedData = try await encryptedCache.load(for: sourceID) else {
                        throw AppModelError.missingCachedPlaylist
                    }
                    parsedPlaylist = try await parsePlaylist(cachedData, baseURL: playlistURL)
                    try apply(parsedPlaylist, to: sourceID)
                }
            }

            guard let source = source(withID: sourceID) else { return }
            source.playlistETag = responseValidators.etag
            source.playlistLastModified = responseValidators.lastModified
            source.lastPlaylistRefresh = .now
            source.lastErrorMessage = nil
            try modelContext.save()
            reloadLocalState()

            let epgDue = force || refreshIsDue(lastRefresh: source.lastEPGRefresh, interval: 12 * 60 * 60)
            if epgDue {
                try await refreshEPG(for: sourceID, playlist: parsedPlaylist)
            }
        } catch is CancellationError {
            return
        } catch {
            if let source = source(withID: sourceID) {
                source.lastErrorMessage = safeMessage(for: error)
                try? modelContext.save()
            }
            reloadLocalState()
            presentedAlert = AppAlert(title: "Refresh Failed", message: safeMessage(for: error))
        }
    }

    func beginAddingSource() {
        editingSourceID = nil
        sourceDraft = SourceDraft()
        sourceEditorError = nil
        isPresentingSourceEditor = true
    }

    func beginEditingSource(_ source: PlaylistSourceRecord) async {
        do {
            guard let playlistURL = try await keychain.playlistURL(for: source.id) else {
                throw AppModelError.missingSourceCredential
            }
            let epgURL = try await keychain.epgURL(for: source.id)
            editingSourceID = source.id
            sourceDraft = SourceDraft(
                displayName: source.displayName,
                playlistURL: playlistURL.absoluteString,
                epgURL: epgURL?.absoluteString ?? ""
            )
            sourceEditorError = nil
            isPresentingSourceEditor = true
        } catch {
            presentedAlert = AppAlert(title: "Playlist Could Not Be Edited", message: safeMessage(for: error))
        }
    }

    func commitSourceDraft() async -> Bool {
        sourceEditorError = nil
        guard let playlistURL = secureHTTPSURL(from: sourceDraft.playlistURL) else {
            sourceEditorError = "Enter a valid HTTPS playlist URL."
            return false
        }

        let trimmedEPG = sourceDraft.epgURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let epgOverride: URL?
        if trimmedEPG.isEmpty {
            epgOverride = nil
        } else if let url = secureHTTPSURL(from: trimmedEPG) {
            epgOverride = url
        } else {
            sourceEditorError = "The EPG override must be a valid HTTPS URL."
            return false
        }

        isSavingSource = true
        defer { isSavingSource = false }

        do {
            let result = try await httpClient.fetch(playlistURL, policy: .playlist)
            guard case .modified(let payload) = result else {
                throw AppModelError.invalidFreshResponse
            }
            let parsed = try await parsePlaylist(payload.data, baseURL: playlistURL)
            let sourceID = editingSourceID ?? UUID()

            try await keychain.setPlaylistURL(playlistURL, for: sourceID)
            try await keychain.setEPGURL(epgOverride, for: sourceID)
            try await encryptedCache.store(payload.data, for: sourceID)

            let sourceRecord: PlaylistSourceRecord
            if let existing = source(withID: sourceID) {
                sourceRecord = existing
            } else {
                sourceRecord = PlaylistSourceRecord(
                    id: sourceID,
                    displayName: "",
                    sortIndex: (sources.map(\.sortIndex).max() ?? -1) + 1
                )
                modelContext.insert(sourceRecord)
            }
            let name = sourceDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceRecord.displayName = name.isEmpty ? (parsed.title ?? playlistURL.host ?? "Playlist") : name
            sourceRecord.lastPlaylistRefresh = .now
            sourceRecord.playlistETag = payload.validators.etag
            sourceRecord.playlistLastModified = payload.validators.lastModified
            sourceRecord.lastErrorMessage = nil
            try modelContext.save()
            try apply(parsed, to: sourceID)

            sidebarSelection = .source(sourceID)
            reloadLocalState()

            do {
                try await refreshEPG(for: sourceID, playlist: parsed)
            } catch {
                if let updatedSource = source(withID: sourceID) {
                    updatedSource.lastErrorMessage = "Playlist loaded, but the guide could not refresh: \(safeMessage(for: error))"
                    try? modelContext.save()
                }
            }
            reloadLocalState()
            editingSourceID = nil
            sourceDraft = SourceDraft()
            return true
        } catch {
            sourceEditorError = safeMessage(for: error)
            return false
        }
    }

    func requestRemoval(of source: PlaylistSourceRecord) {
        presentedAlert = AppAlert(
            title: "Remove \(source.displayName)?",
            message: "This removes its cached channels, guide data, favorites, recents, and protected credentials from this Mac.",
            sourceID: source.id
        )
    }

    func canMoveSource(id: UUID, offset: Int) -> Bool {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return false }
        return sources.indices.contains(index + offset)
    }

    func moveSource(id: UUID, offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              sources.indices.contains(index + offset) else { return }
        let destination = index + offset
        let first = sources[index]
        let second = sources[destination]
        let previousIndex = first.sortIndex
        first.sortIndex = second.sortIndex
        second.sortIndex = previousIndex
        saveContext(showingErrorAs: "Playlist Order Could Not Be Saved")
        reloadLocalState()
    }

    func removeSource(id sourceID: UUID) async {
        do {
            try await encryptedCache.remove(for: sourceID)
            try await keychain.removeAll(for: sourceID)

            for record in channels where record.sourceID == sourceID { modelContext.delete(record) }
            for record in programmes where record.sourceID == sourceID { modelContext.delete(record) }
            for record in recents where record.sourceID == sourceID { modelContext.delete(record) }
            if let source = source(withID: sourceID) { modelContext.delete(source) }
            try modelContext.save()

            runtimePlaylists[sourceID] = nil
            streamURLs = streamURLs.filter { key, _ in
                channels.first(where: { $0.stableID == key })?.sourceID != sourceID
            }
            if selectedChannel?.sourceID == sourceID {
                selectedChannelID = nil
                playbackPreparationTask?.cancel()
                playerController.stop()
            }
            reloadLocalState()
            sidebarSelection = sources.first.map { .source($0.id) } ?? .favorites
        } catch {
            presentedAlert = AppAlert(title: "Playlist Could Not Be Removed", message: safeMessage(for: error))
        }
    }

    private func loadCachedPlaylist(for sourceID: UUID) async {
        do {
            guard
                let data = try await encryptedCache.load(for: sourceID),
                let sourceURL = try await keychain.playlistURL(for: sourceID)
            else { return }
            let parsed = try await parsePlaylist(data, baseURL: sourceURL)
            try apply(parsed, to: sourceID)
        } catch {
            if let source = source(withID: sourceID) {
                source.lastErrorMessage = safeMessage(for: error)
                try? modelContext.save()
            }
            reloadLocalState()
        }
    }

    private func refreshEPG(for sourceID: UUID, playlist: ParsedPlaylist) async throws {
        let override = try await keychain.epgURL(for: sourceID)
        guard let epgURL = override ?? playlist.epgURLs.first else { return }
        guard let sourceRecord = source(withID: sourceID) else { return }

        let validators = HTTPValidators(etag: sourceRecord.epgETag, lastModified: sourceRecord.epgLastModified)
        let result = try await httpClient.fetch(epgURL, validators: validators, policy: .epg)
        let responseValidators: HTTPValidators

        switch result {
        case .notModified(let received):
            responseValidators = received
        case .modified(let payload):
            responseValidators = payload.validators
            let rawData = payload.data
            let needsGzip = epgURL.pathExtension.lowercased() == "gz"
                || (rawData.count >= 2 && rawData[rawData.startIndex] == 0x1f && rawData[rawData.index(after: rawData.startIndex)] == 0x8b)
            let xmlData = try await Task.detached(priority: .utility) {
                if needsGzip {
                    return try GzipDecompressor.decompress(rawData, maximumExpandedBytes: 512 * 1_024 * 1_024)
                }
                return rawData
            }.value

            let channelIDs = Set(playlist.channels.compactMap(\.tvgID))
            let lowerBound = Date.now.addingTimeInterval(-2 * 60 * 60)
            let upperBound = Date.now.addingTimeInterval(36 * 60 * 60)
            let parsedProgrammes = try await Task.detached(priority: .utility) { [xmlTVParser] in
                try xmlTVParser.parse(
                    data: xmlData,
                    channelIDs: channelIDs,
                    timeWindow: lowerBound ..< upperBound
                )
            }.value
            try apply(parsedProgrammes, to: sourceID)
        }

        guard let refreshedSource = source(withID: sourceID) else { return }
        refreshedSource.epgETag = responseValidators.etag
        refreshedSource.epgLastModified = responseValidators.lastModified
        refreshedSource.lastEPGRefresh = Date.now
        try modelContext.save()
        reloadLocalState()
    }

    private func apply(_ playlist: ParsedPlaylist, to sourceID: UUID) throws {
        runtimePlaylists[sourceID] = playlist
        let existing = Dictionary(
            uniqueKeysWithValues: channels.filter { $0.sourceID == sourceID }.map { ($0.stableID, $0) }
        )
        var retainedIDs: Set<String> = []

        streamURLs = streamURLs.filter { key, _ in
            channels.first(where: { $0.stableID == key })?.sourceID != sourceID
        }

        for parsed in playlist.channels {
            let stableID = parsed.stableKey(sourceID: sourceID).rawValue
            retainedIDs.insert(stableID)
            let transportAllowed = isAllowedMediaURL(parsed.streamURL)
            if transportAllowed { streamURLs[stableID] = parsed.streamURL }

            if let record = existing[stableID] {
                record.tvgID = parsed.tvgID
                record.name = parsed.name
                record.groupName = parsed.group ?? "Other"
                record.logoURLString = parsed.logoURL?.absoluteString
                record.sortIndex = parsed.order
                record.isTransportAllowed = transportAllowed
            } else {
                modelContext.insert(
                    ChannelRecord(
                        stableID: stableID,
                        sourceID: sourceID,
                        tvgID: parsed.tvgID,
                        name: parsed.name,
                        groupName: parsed.group ?? "Other",
                        logoURLString: parsed.logoURL?.absoluteString,
                        sortIndex: parsed.order,
                        isTransportAllowed: transportAllowed
                    )
                )
            }
        }

        for (stableID, record) in existing where !retainedIDs.contains(stableID) {
            modelContext.delete(record)
            for recent in recents where recent.channelStableID == stableID { modelContext.delete(recent) }
            for programme in programmes where programme.channelStableID == stableID { modelContext.delete(programme) }
        }
        try modelContext.save()
        reloadLocalState()
    }

    private func apply(_ parsedProgrammes: [ParsedProgramme], to sourceID: UUID) throws {
        for record in programmes where record.sourceID == sourceID {
            modelContext.delete(record)
        }

        let channelIDs = Dictionary(grouping: channels.filter { $0.sourceID == sourceID && $0.tvgID != nil }) {
            $0.tvgID ?? ""
        }
        for programme in parsedProgrammes {
            guard let matchingChannels = channelIDs[programme.channelID] else { continue }
            for channel in matchingChannels {
                let identifier = hashedIdentifier(
                    "\(sourceID.uuidString)|\(channel.stableID)|\(programme.start.timeIntervalSince1970)|\(programme.end.timeIntervalSince1970)|\(programme.title)"
                )
                modelContext.insert(
                    ProgrammeRecord(
                        stableID: identifier,
                        sourceID: sourceID,
                        channelStableID: channel.stableID,
                        title: programme.title,
                        programmeDescription: programme.description,
                        startDate: programme.start,
                        endDate: programme.end
                    )
                )
            }
        }
        try modelContext.save()
        reloadLocalState()
    }

    private func parsePlaylist(_ data: Data, baseURL: URL) async throws -> ParsedPlaylist {
        try await Task.detached(priority: .userInitiated) { [m3uParser] in
            try m3uParser.parse(data: data, baseURL: baseURL)
        }.value
    }

    private func recordRecentChannelIfReady() {
        guard case .playing = playerController.state,
              let channelID = pendingRecentChannelID,
              let channel = channel(withID: channelID) else { return }
        pendingRecentChannelID = nil

        if let existing = recents.first(where: { $0.channelStableID == channelID }) {
            existing.lastPlayedAt = .now
        } else {
            modelContext.insert(RecentChannelRecord(channelStableID: channelID, sourceID: channel.sourceID))
        }
        try? modelContext.save()
        reloadLocalState()

        for stale in recents.dropFirst(20) {
            modelContext.delete(stale)
        }
        try? modelContext.save()
        reloadLocalState()
    }

    private func observePlaybackForRecents() {
        withObservationTracking {
            _ = playerController.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordRecentChannelIfReady()
                self.observePlaybackForRecents()
            }
        }
    }

    private func reloadLocalState() {
        do {
            sources = try modelContext.fetch(FetchDescriptor<PlaylistSourceRecord>())
                .sorted { $0.sortIndex < $1.sortIndex }
            channels = try modelContext.fetch(FetchDescriptor<ChannelRecord>())
                .sorted { lhs, rhs in
                    lhs.sourceID == rhs.sourceID ? lhs.sortIndex < rhs.sortIndex : lhs.name < rhs.name
                }
            programmes = try modelContext.fetch(FetchDescriptor<ProgrammeRecord>())
            recents = try modelContext.fetch(FetchDescriptor<RecentChannelRecord>())
                .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "The local channel library could not be read.")
        }
    }

    private func source(withID id: UUID) -> PlaylistSourceRecord? {
        sources.first { $0.id == id }
    }

    private func secureHTTPSURL(from value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private func isAllowedMediaURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": url.host?.lowercased() == "vandijk.tvfor.pro"
        default: false
        }
    }

    private func refreshIsDue(lastRefresh: Date?, interval: TimeInterval) -> Bool {
        guard let lastRefresh else { return true }
        return Date.now.timeIntervalSince(lastRefresh) >= interval
    }

    private func hashedIdentifier(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func saveContext(showingErrorAs title: String) {
        do {
            try modelContext.save()
        } catch {
            presentedAlert = AppAlert(title: title, message: "The local library could not be updated.")
        }
    }

    private func safeMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The operation could not be completed."
    }
}

private enum AppModelError: LocalizedError {
    case missingSourceCredential
    case missingCachedPlaylist
    case invalidFreshResponse

    var errorDescription: String? {
        switch self {
        case .missingSourceCredential:
            "The playlist credential is missing from Keychain."
        case .missingCachedPlaylist:
            "The protected playlist cache is missing."
        case .invalidFreshResponse:
            "The server did not return a fresh playlist."
        }
    }
}

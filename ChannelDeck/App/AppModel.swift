import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftData

enum SidebarSelection: Hashable {
    case favorites
    case recents
    case recordings
    case source(UUID)
    case group(UUID, String)
}

enum BufferRecordingPhase: Equatable, Sendable {
    case idle
    case starting
    case recording(startedAt: Date)
    case finalizing
    case failed(String)

    var isEnabled: Bool {
        switch self {
        case .starting, .recording, .finalizing: true
        case .idle, .failed: false
        }
    }

    var isBusy: Bool {
        switch self {
        case .starting, .finalizing: true
        default: false
        }
    }
}

struct SourceDraft: Equatable {
    var displayName = ""
    var playlistURL = ""
    var epgURL = ""
}

enum SourceURLPolicy {
    static func validatedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func usesUnencryptedTransport(_ value: String) -> Bool {
        validatedURL(from: value)?.scheme?.lowercased() == "http"
    }
}

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let sourceID: UUID?
    let recordingID: UUID?

    init(
        title: String,
        message: String,
        sourceID: UUID? = nil,
        recordingID: UUID? = nil
    ) {
        self.title = title
        self.message = message
        self.sourceID = sourceID
        self.recordingID = recordingID
    }
}

/// Keeps programme lookups proportional to one channel's short schedule rather
/// than scanning the complete guide for every visible list row.
struct ProgrammeGuideIndex {
    private let schedules: [String: [ProgrammeRecord]]

    init(programmes: [ProgrammeRecord] = []) {
        schedules = Dictionary(grouping: programmes, by: \.channelStableID)
            .mapValues { schedule in
                schedule.sorted { $0.startDate < $1.startDate }
            }
    }

    func current(channelStableID: String, at date: Date) -> ProgrammeRecord? {
        schedules[channelStableID]?.last { programme in
            programme.startDate <= date && date < programme.endDate
        }
    }

    func next(channelStableID: String, at date: Date) -> ProgrammeRecord? {
        let schedule = schedules[channelStableID] ?? []
        let threshold = current(channelStableID: channelStableID, at: date)?.endDate ?? date
        return schedule.first { $0.startDate >= threshold }
    }
}

@MainActor
@Observable
final class AppModel {
    private struct PendingRecordingMetadata {
        let id: UUID
        let channelStableID: String
        let sourceID: UUID
        let channelName: String
        let groupName: String
        let logoURLString: String?
        let programmeTitle: String?
        let programmeDescription: String?
        let programmeStartDate: Date?
        let programmeEndDate: Date?
        let packageName: String
        let quality: BufferRecordingQuality
    }

    let playerController: PlayerController
    let airPlayRelayController: AirPlayRelayController

    var sources: [PlaylistSourceRecord] = []
    var channels: [ChannelRecord] = []
    var programmes: [ProgrammeRecord] = []
    var recents: [RecentChannelRecord] = []
    var recordings: [RecordingRecord] = []

    var sidebarSelection: SidebarSelection? = .favorites
    var selectedChannelID: String?
    var selectedRecordingID: UUID?
    var searchText = ""
    var refreshingSourceIDs: Set<UUID> = []
    var isLoadingProgrammeGuide = false

    var isPresentingSourceEditor = false
    var isSavingSource = false
    var sourceDraft = SourceDraft()
    var sourceEditorError: String?
    var presentedAlert: AppAlert?
    var bufferRecordingPhase: BufferRecordingPhase = .idle
    var bufferRecordingQuality: BufferRecordingQuality = .savedDefault {
        didSet {
            UserDefaults.standard.set(
                bufferRecordingQuality.rawValue,
                forKey: BufferRecordingQuality.defaultsKey
            )
        }
    }

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let keychain: any KeychainStoring
    @ObservationIgnored private let encryptedCache: EncryptedPlaylistCache
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored private let recordingStorage: RecordingStorage?
    @ObservationIgnored private let m3uParser = M3UParser()
    @ObservationIgnored private let xmlTVParser = XMLTVParser()
    @ObservationIgnored private var runtimePlaylists: [UUID: ParsedPlaylist] = [:]
    @ObservationIgnored private var streamURLs: [String: URL] = [:]
    @ObservationIgnored private var editingSourceID: UUID?
    @ObservationIgnored private var pendingRecentChannelID: String?
    @ObservationIgnored private var didBootstrap = false
    @ObservationIgnored private var playbackPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var bufferRecordingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingFinalizationTask: Task<Void, Never>?
    @ObservationIgnored private var activeRecordingMetadata: PendingRecordingMetadata?
    private var programmeGuideIndex = ProgrammeGuideIndex()

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
        self.recordingStorage = try? RecordingStorage()
        // Channels are enough to draw the first frame. Loading thousands of
        // guide rows here made App.init block and produced a beachball.
        reloadCoreState()
        isLoadingProgrammeGuide = !sources.isEmpty
        observePlaybackForRecents()
    }

    var selectedChannel: ChannelRecord? {
        guard let selectedChannelID else { return nil }
        return channel(withID: selectedChannelID)
    }

    var selectedRecording: RecordingRecord? {
        guard let selectedRecordingID else { return nil }
        return recordings.first { $0.id == selectedRecordingID }
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
        case .recordings:
            base = []
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

    var filteredRecordings: [RecordingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.channelName.localizedStandardContains(query)
                || recording.groupName.localizedStandardContains(query)
                || recording.programmeTitle?.localizedStandardContains(query) == true
                || recording.programmeDescription?.localizedStandardContains(query) == true
        }
    }

    var browserTitle: String {
        switch sidebarSelection {
        case .favorites: "Favorites"
        case .recents: "Recently Watched"
        case .recordings: "Recordings"
        case .source(let id): source(withID: id)?.displayName ?? "Channels"
        case .group(_, let group): group
        case nil: "Channels"
        }
    }

    var isEditingSource: Bool { editingSourceID != nil }
    var sourceEditorTitle: String { isEditingSource ? "Edit Playlist" : "Add Playlist" }

    var canCommitSourceDraft: Bool {
        SourceURLPolicy.validatedURL(from: sourceDraft.playlistURL) != nil
    }

    var sourceDraftUsesUnencryptedTransport: Bool {
        SourceURLPolicy.usesUnencryptedTransport(sourceDraft.playlistURL)
            || SourceURLPolicy.usesUnencryptedTransport(sourceDraft.epgURL)
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await Task.yield()
        // Enter the relay bootstrap phase before yielding to playlist refresh
        // work. Channel selection can still interleave while networking is in
        // progress, but playbackURL(for:) will now wait for that in-flight
        // restore instead of silently bypassing the persisted secure relay.
        await airPlayRelayController.bootstrap()

        if sources.isEmpty {
            isLoadingProgrammeGuide = false
            beginAddingSource()
            return
        }

        for source in sources {
            await loadCachedPlaylist(for: source.id)
        }
        reloadProgrammeState()
        isLoadingProgrammeGuide = false

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
        programmeGuideIndex.current(channelStableID: channel.stableID, at: date)
    }

    func nextProgramme(for channel: ChannelRecord, at date: Date = .now) -> ProgrammeRecord? {
        programmeGuideIndex.next(channelStableID: channel.stableID, at: date)
    }

    func isPlaying(_ channel: ChannelRecord) -> Bool {
        selectedChannelID == channel.stableID && playerController.state != .idle
    }

    func play(_ channel: ChannelRecord) {
        selectedChannelID = channel.stableID
        selectedRecordingID = nil
        guard channel.isTransportAllowed else {
            finishRecordingAfterRejectedSelection()
            presentedAlert = AppAlert(
                title: "Unsupported Stream",
                message: "This channel does not provide a valid HTTP or HTTPS media address."
            )
            return
        }
        guard let streamURL = streamURLs[channel.stableID] else {
            finishRecordingAfterRejectedSelection()
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
            await finishActiveRecording()
            let playbackURL = await airPlayRelayController.playbackURL(for: streamURL)
            guard !Task.isCancelled, selectedChannelID == stableID else { return }
            playerController.play(url: playbackURL, channelName: channelName)
        }
    }

    func play(_ recording: RecordingRecord) {
        selectedRecordingID = recording.id
        selectedChannelID = nil
        playbackPreparationTask?.cancel()
        playerController.stop()
        let recordingID = recording.id
        playbackPreparationTask = Task { [weak self] in
            guard let self else { return }
            await finishActiveRecording()
            guard !Task.isCancelled,
                  selectedRecordingID == recordingID,
                  let recording = recordings.first(where: { $0.id == recordingID }),
                  let recordingStorage else { return }
            do {
                let packageName = recording.packageName
                let playbackURL = try await Task.detached(priority: .userInitiated) {
                    try recordingStorage.playbackURL(inPackageNamed: packageName)
                }.value
                guard !Task.isCancelled, selectedRecordingID == recordingID else { return }
                playerController.play(
                    url: playbackURL,
                    channelName: recording.channelName,
                    allowsExternalPlayback: false
                )
                generateMissingThumbnail(for: recording, playbackURL: playbackURL)
            } catch {
                if selectedRecordingID == recordingID {
                    presentedAlert = AppAlert(
                        title: "Recording Unavailable",
                        message: safeMessage(for: error)
                    )
                }
            }
        }
    }

    func setSaveBufferEnabled(_ enabled: Bool) {
        guard enabled != bufferRecordingPhase.isEnabled else { return }
        bufferRecordingTask?.cancel()
        bufferRecordingTask = Task { [weak self] in
            guard let self else { return }
            if enabled {
                await beginSavingBuffer()
            } else {
                await finishActiveRecording()
            }
        }
    }

    func recordingThumbnailURL(for recording: RecordingRecord) -> URL? {
        guard let recordingStorage else { return nil }
        return try? recordingStorage.thumbnailURL(
            inPackageNamed: recording.packageName,
            fileName: recording.thumbnailFileName
        )
    }

    func requestRemoval(of recording: RecordingRecord) {
        presentedAlert = AppAlert(
            title: "Delete Recording?",
            message: "This permanently removes \(recording.programmeTitle ?? recording.channelName) from this Mac.",
            recordingID: recording.id
        )
    }

    func revealRecording(_ recording: RecordingRecord) {
        guard let recordingStorage else { return }
        do {
            let url = try recordingStorage.revealURL(
                inPackageNamed: recording.packageName
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentedAlert = AppAlert(
                title: "Recording Could Not Be Revealed",
                message: safeMessage(for: error)
            )
        }
    }

    func removeRecording(id: UUID) {
        guard let recording = recordings.first(where: { $0.id == id }),
              let recordingStorage else { return }
        do {
            try recordingStorage.removePackage(named: recording.packageName)
            if selectedRecordingID == id {
                playbackPreparationTask?.cancel()
                selectedRecordingID = nil
                playerController.stop()
            }
            modelContext.delete(recording)
            try modelContext.save()
            reloadRecordings()
        } catch {
            presentedAlert = AppAlert(
                title: "Recording Could Not Be Deleted",
                message: safeMessage(for: error)
            )
        }
    }

    private func beginSavingBuffer() async {
        guard let channel = selectedChannel else {
            bufferRecordingPhase = .failed("Choose a playing channel before saving its buffer.")
            return
        }
        guard airPlayRelayController.playbackIsRelayed,
              playerController.liveDVRState.isAvailable else {
            bufferRecordingPhase = .failed(
                "Wait for the secure live buffer to become available, then try again."
            )
            return
        }
        guard let recordingStorage else {
            bufferRecordingPhase = .failed("ChannelDeck could not access its recordings folder.")
            return
        }

        let id = UUID()
        let packageURL: URL
        do {
            packageURL = try recordingStorage.newPackageURL(for: id)
        } catch {
            bufferRecordingPhase = .failed(safeMessage(for: error))
            return
        }
        let programme = currentProgramme(for: channel)
        let metadata = PendingRecordingMetadata(
            id: id,
            channelStableID: channel.stableID,
            sourceID: channel.sourceID,
            channelName: channel.name,
            groupName: channel.groupName,
            logoURLString: channel.logoURLString,
            programmeTitle: programme?.title,
            programmeDescription: programme?.programmeDescription,
            programmeStartDate: programme?.startDate,
            programmeEndDate: programme?.endDate,
            packageName: recordingStorage.packageName(for: id),
            quality: bufferRecordingQuality
        )
        activeRecordingMetadata = metadata
        bufferRecordingPhase = .starting

        do {
            let initialBufferedDuration = try await airPlayRelayController.beginBufferRecording(
                id: id,
                packageDirectory: packageURL,
                quality: metadata.quality
            )
            guard activeRecordingMetadata?.id == id else { return }
            bufferRecordingPhase = .recording(
                startedAt: Date.now.addingTimeInterval(-initialBufferedDuration)
            )
        } catch {
            guard activeRecordingMetadata?.id == id else { return }
            activeRecordingMetadata = nil
            try? recordingStorage.removePackage(named: metadata.packageName)
            bufferRecordingPhase = .failed(safeMessage(for: error))
        }
    }

    private func finishActiveRecording() async {
        if let recordingFinalizationTask {
            await recordingFinalizationTask.value
            return
        }
        guard let metadata = activeRecordingMetadata else { return }
        activeRecordingMetadata = nil
        bufferRecordingPhase = .finalizing
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await finalizeRecording(metadata)
        }
        recordingFinalizationTask = task
        await task.value
        recordingFinalizationTask = nil
    }

    private func finalizeRecording(_ metadata: PendingRecordingMetadata) async {
        do {
            guard let artifact = try await airPlayRelayController.finishBufferRecording(),
                  artifact.id == metadata.id else {
                throw FFmpegLiveRecordingError.couldNotFinalize
            }
            let endedAt = Date.now
            let record = RecordingRecord(
                id: metadata.id,
                channelStableID: metadata.channelStableID,
                sourceID: metadata.sourceID,
                channelName: metadata.channelName,
                groupName: metadata.groupName,
                logoURLString: metadata.logoURLString,
                programmeTitle: metadata.programmeTitle,
                programmeDescription: metadata.programmeDescription,
                programmeStartDate: metadata.programmeStartDate,
                programmeEndDate: metadata.programmeEndDate,
                startedAt: endedAt.addingTimeInterval(-artifact.duration),
                endedAt: endedAt,
                duration: artifact.duration,
                packageName: metadata.packageName,
                thumbnailFileName: nil,
                qualityRawValue: artifact.quality.rawValue
            )
            do {
                modelContext.insert(record)
                try modelContext.save()
            } catch {
                modelContext.delete(record)
                throw error
            }
            reloadRecordings()
            bufferRecordingPhase = .idle

            Task { [weak self] in
                let thumbnail = await RecordingThumbnailGenerator.generate(
                    for: artifact.playbackURL,
                    in: artifact.packageDirectory
                )
                guard let self, let thumbnail,
                      let stored = recordings.first(where: { $0.id == metadata.id }) else { return }
                stored.thumbnailFileName = thumbnail
                try? modelContext.save()
                reloadRecordings()
            }
        } catch {
            if let recordingStorage {
                try? recordingStorage.removePackage(named: metadata.packageName)
            }
            bufferRecordingPhase = .failed(safeMessage(for: error))
        }
    }

    private func generateMissingThumbnail(
        for recording: RecordingRecord,
        playbackURL: URL
    ) {
        guard recording.thumbnailFileName == nil, let recordingStorage else { return }
        let recordingID = recording.id
        let packageName = recording.packageName
        Task { [weak self] in
            guard let package = try? recordingStorage.packageURL(named: packageName),
                  let thumbnail = await RecordingThumbnailGenerator.generate(
                    for: playbackURL,
                    in: package
                  ),
                  let self,
                  let stored = recordings.first(where: { $0.id == recordingID }),
                  stored.thumbnailFileName == nil else { return }
            stored.thumbnailFileName = thumbnail
            try? modelContext.save()
            reloadRecordings()
        }
    }

    private func finishRecordingAfterRejectedSelection() {
        guard activeRecordingMetadata != nil else { return }
        bufferRecordingTask?.cancel()
        bufferRecordingTask = Task { [weak self] in
            await self?.finishActiveRecording()
        }
    }

    func toggleFavorite(_ channel: ChannelRecord) {
        channel.isFavorite.toggle()
        saveContext(showingErrorAs: "Favorite Could Not Be Saved")
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
            reloadCoreState()

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
            reloadCoreState()
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
        guard let playlistURL = SourceURLPolicy.validatedURL(from: sourceDraft.playlistURL) else {
            sourceEditorError = "Enter a valid HTTP or HTTPS playlist URL."
            return false
        }

        let trimmedEPG = sourceDraft.epgURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let epgOverride: URL?
        if trimmedEPG.isEmpty {
            epgOverride = nil
        } else if let url = SourceURLPolicy.validatedURL(from: trimmedEPG) {
            epgOverride = url
        } else {
            sourceEditorError = "The EPG override must be a valid HTTP or HTTPS URL."
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
            reloadCoreState()

            do {
                try await refreshEPG(for: sourceID, playlist: parsed)
            } catch {
                if let updatedSource = source(withID: sourceID) {
                    updatedSource.lastErrorMessage = "Playlist loaded, but the guide could not refresh: \(safeMessage(for: error))"
                    try? modelContext.save()
                }
            }
            reloadCoreState()
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
        reloadCoreState()
    }

    func removeSource(id sourceID: UUID) async {
        do {
            if selectedChannel?.sourceID == sourceID {
                await finishActiveRecording()
            }
            try await encryptedCache.remove(for: sourceID)
            try await keychain.removeAll(for: sourceID)

            for record in channels where record.sourceID == sourceID { modelContext.delete(record) }
            let allProgrammes = try programmesStored(for: sourceID)
            for record in allProgrammes { modelContext.delete(record) }
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
            if channels.contains(where: { $0.sourceID == sourceID }) {
                hydrateRuntimePlaylist(parsed, for: sourceID)
            } else {
                try apply(parsed, to: sourceID)
            }
        } catch {
            if let source = source(withID: sourceID) {
                source.lastErrorMessage = safeMessage(for: error)
                try? modelContext.save()
            }
            reloadCoreState()
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

        let removedIDs = Set(existing.keys).subtracting(retainedIDs)
        let storedProgrammes = removedIDs.isEmpty ? [] : try programmesStored(for: sourceID)
        for (stableID, record) in existing where removedIDs.contains(stableID) {
            modelContext.delete(record)
            for recent in recents where recent.channelStableID == stableID { modelContext.delete(recent) }
            for programme in storedProgrammes where programme.channelStableID == stableID {
                modelContext.delete(programme)
            }
        }
        try modelContext.save()
        reloadCoreState()
    }

    private func apply(_ parsedProgrammes: [ParsedProgramme], to sourceID: UUID) throws {
        for record in try programmesStored(for: sourceID) {
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
        reloadProgrammeState()
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
        reloadRecents()

        for stale in recents.dropFirst(20) {
            modelContext.delete(stale)
        }
        try? modelContext.save()
        reloadRecents()
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
        reloadCoreState()
        reloadProgrammeState()
    }

    private func reloadCoreState() {
        do {
            sources = try modelContext.fetch(FetchDescriptor<PlaylistSourceRecord>())
                .sorted { $0.sortIndex < $1.sortIndex }
            channels = try modelContext.fetch(FetchDescriptor<ChannelRecord>())
                .sorted { lhs, rhs in
                    lhs.sourceID == rhs.sourceID ? lhs.sortIndex < rhs.sortIndex : lhs.name < rhs.name
                }
            reloadRecents()
            reloadRecordings()
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "The local channel library could not be read.")
        }
    }

    private func reloadProgrammeState(at date: Date = .now) {
        do {
            // The UI only presents the current and next programme. A six-hour
            // horizon covers long events while avoiding eager materialization
            // of the complete 36-hour guide during launch and list updates.
            let upperBound = date.addingTimeInterval(6 * 60 * 60)
            let descriptor = FetchDescriptor<ProgrammeRecord>(
                predicate: #Predicate { programme in
                    programme.endDate > date && programme.startDate < upperBound
                },
                sortBy: [
                    SortDescriptor(\.channelStableID),
                    SortDescriptor(\.startDate),
                ]
            )
            programmes = try modelContext.fetch(descriptor)
            programmeGuideIndex = ProgrammeGuideIndex(programmes: programmes)
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "The local programme guide could not be read.")
        }
    }

    private func reloadRecents() {
        do {
            recents = try modelContext.fetch(FetchDescriptor<RecentChannelRecord>())
                .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "Recently watched channels could not be read.")
        }
    }

    private func reloadRecordings() {
        do {
            recordings = try modelContext.fetch(
                FetchDescriptor<RecordingRecord>(
                    sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
                )
            )
        } catch {
            presentedAlert = AppAlert(
                title: "Library Error",
                message: "Saved recordings could not be read."
            )
        }
    }

    private func hydrateRuntimePlaylist(_ playlist: ParsedPlaylist, for sourceID: UUID) {
        runtimePlaylists[sourceID] = playlist
        let channelIDs = Set(channels.lazy.filter { $0.sourceID == sourceID }.map(\.stableID))
        streamURLs = streamURLs.filter { !channelIDs.contains($0.key) }

        for parsed in playlist.channels {
            let stableID = parsed.stableKey(sourceID: sourceID).rawValue
            guard channelIDs.contains(stableID), isAllowedMediaURL(parsed.streamURL) else { continue }
            streamURLs[stableID] = parsed.streamURL
        }
    }

    private func programmesStored(for sourceID: UUID) throws -> [ProgrammeRecord] {
        let descriptor = FetchDescriptor<ProgrammeRecord>(
            predicate: #Predicate { programme in
                programme.sourceID == sourceID
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func source(withID id: UUID) -> PlaylistSourceRecord? {
        sources.first { $0.id == id }
    }

    private func isAllowedMediaURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host?.isEmpty == false
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

import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftData

enum SidebarSelection: Hashable {
    case favorites
    case recents
    case recordings
    case guide
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
    var guideMode: GuideProviderMode = .playlist
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

    init(schedules: [String: [ProgrammeRecord]]) {
        self.schedules = schedules
    }

    func current(channelStableID: String, at date: Date) -> ProgrammeRecord? {
        schedules[channelStableID]?.last { programme in
            programme.startDate <= date && date < programme.endDate
        }
    }

    func schedule(channelStableID: String, from start: Date, to end: Date) -> [ProgrammeRecord] {
        (schedules[channelStableID] ?? []).filter { $0.endDate > start && $0.startDate < end }
    }

    func next(channelStableID: String, at date: Date) -> ProgrammeRecord? {
        let schedule = schedules[channelStableID] ?? []
        let threshold = current(channelStableID: channelStableID, at: date)?.endDate ?? date
        return schedule.first { $0.startDate >= threshold }
    }
}

private struct LaunchChannelSnapshot: Sendable {
    let id: String
    let name: String
    let group: String
    let sourceID: UUID
    let sourceName: String
    let sourceOrder: Int
    let order: Int
    let isFavorite: Bool
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
    private enum PlaybackTarget: Equatable {
        case channel(String)
        case recording(UUID)
    }
    private var playbackTarget: PlaybackTarget?
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleGlobalChannelSearch()
        }
    }
    var globalChannelSearchResultIDs: [String] = []
    var isSearchingChannels = false
    var isBootstrapping = true
    var launchStatus = "Getting your channels ready"
    private(set) var channelIndexRevision = 0
    private(set) var guideSearchRevision = 0
    var refreshingSourceIDs: Set<UUID> = []
    var isLoadingProgrammeGuide = false

    var isPresentingSourceEditor = false
    var isSavingSource = false
    var sourceSaveStatus = "Saving settings…"
    var guideProgress: [UUID: String] = [:]
    var sourceDraft = SourceDraft()
    var sourceEditorError: String?
    var guideResults: [UUID: OpenEPGResult] = [:]
    var refreshingGuides: Set<UUID> = []
    var editingGuideSourceID: UUID? { editingSourceID }

    func guidePreferences(for sourceID: UUID) -> GuidePreferences {
        preferenceStore.data(forKey: "channelDeck.guide.\(sourceID.uuidString)")
            .flatMap { try? JSONDecoder().decode(GuidePreferences.self, from: $0) } ?? GuidePreferences()
    }

    func saveGuidePreferences(_ preferences: GuidePreferences, for sourceID: UUID) {
        if let data = try? JSONEncoder().encode(preferences) {
            preferenceStore.set(data, forKey: "channelDeck.guide.\(sourceID.uuidString)")
        }
    }

    func setGuideMatch(_ matchID: String?, channelID: String, sourceID: UUID) async {
        var preferences = guidePreferences(for: sourceID)
        preferences.overrides[channelID] = matchID
        saveGuidePreferences(preferences, for: sourceID)
        if preferences.managedChannels.contains(channelID) {
            for record in (try? programmesStored(for: sourceID)) ?? [] where record.channelStableID == channelID {
                modelContext.delete(record)
            }
            try? modelContext.save()
            reloadProgrammeState()
        }
        await refreshGuideOnly(sourceID)
    }

    func refreshGuideOnly(_ sourceID: UUID) async {
        guard let playlist = runtimePlaylists[sourceID], !refreshingGuides.contains(sourceID) else { return }
        do { try await refreshEPG(for: sourceID, playlist: playlist) }
        catch {
            sourceEditorError = "Guide refresh failed: \(safeMessage(for: error))"
            source(withID: sourceID)?.lastErrorMessage = sourceEditorError
            try? modelContext.save()
            reloadCoreState()
        }
    }

    private func startGuideRefreshTimer() {
        guard guideRefreshTask == nil else { return }
        guideRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshDueGuides()
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            }
        }
    }

    private func refreshDueGuides() async {
        for source in sources where guidePreferences(for: source.id).mode != .playlist {
            if refreshIsDue(lastRefresh: source.lastEPGRefresh, interval: 24 * 3600) {
                await refreshGuideOnly(source.id)
            }
        }
    }
    var presentedAlert: AppAlert?
    var playbackPreparation: PlaybackPreparation?
    var playbackIssue: PlaybackIssue?
    var availableRecordingBytes: Int64?
    var libraryPreferences: LibraryPreferences {
        didSet {
            guideSearchRevision &+= 1
            if let data = try? JSONEncoder().encode(libraryPreferences) {
                preferenceStore.set(data, forKey: LibraryPreferences.defaultsKey)
            }
        }
    }
    var bufferRecordingPhase: BufferRecordingPhase = .idle
    var bufferRecordingQuality: BufferRecordingQuality = .savedDefault {
        didSet {
            UserDefaults.standard.set(
                bufferRecordingQuality.rawValue,
                forKey: BufferRecordingQuality.defaultsKey
            )
        }
    }

    @ObservationIgnored private let preferenceStore: UserDefaults
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
    @ObservationIgnored private var channelByID: [String: ChannelRecord] = [:]
    @ObservationIgnored private var channelsBySourceID: [UUID: [ChannelRecord]] = [:]
    @ObservationIgnored private var channelsByGroup: [ChannelGroupKey: [ChannelRecord]] = [:]
    @ObservationIgnored private var groupNamesBySourceID: [UUID: [String]] = [:]
    @ObservationIgnored private var channelCountBySourceID: [UUID: Int] = [:]
    @ObservationIgnored private var sourceNameByID: [UUID: String] = [:]
    @ObservationIgnored private var channelSearchIndex = ChannelSearchIndex()
    @ObservationIgnored private var channelSearchTask: Task<Void, Never>?
    @ObservationIgnored private var guideRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var guideWindowRefreshTask: Task<Void, Never>?
    private var programmeGuideIndex = ProgrammeGuideIndex()
    @ObservationIgnored private var guideSearchIndex = GuideSearchIndex()

    var guideSearchSnapshot: GuideSearchIndex { guideSearchIndex }
    var guideHasFavorites: Bool { !guideSearchIndex.favoriteIDs.isEmpty }

    private struct ChannelGroupKey: Hashable {
        let sourceID: UUID
        let groupName: String
    }

    init(
        modelContainer: ModelContainer,
        playerController: PlayerController = PlayerController(),
        keychain: (any KeychainStoring)? = nil,
        httpClient: HTTPClient = HTTPClient(),
        preferenceStore: UserDefaults = .standard
    ) {
        self.preferenceStore = preferenceStore
        self.libraryPreferences = preferenceStore.data(forKey: LibraryPreferences.defaultsKey)
            .flatMap { try? JSONDecoder().decode(LibraryPreferences.self, from: $0) } ?? LibraryPreferences()
        self.modelContext = ModelContext(modelContainer)
        self.playerController = playerController
        let resolvedKeychain = keychain ?? KeychainStore()
        self.keychain = resolvedKeychain
        self.airPlayRelayController = AirPlayRelayController(keychain: resolvedKeychain)
        self.encryptedCache = EncryptedPlaylistCache(keyStore: resolvedKeychain)
        self.httpClient = httpClient
        self.recordingStorage = try? RecordingStorage()
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
        _ = channelIndexRevision
        if isGlobalChannelSearchActive {
            return globalChannelSearchResultIDs.compactMap { channelByID[$0] }.filter(isChannelVisible)
        }

        let base: [ChannelRecord]
        switch sidebarSelection {
        case .favorites:
            base = favoriteChannels
        case .recents:
            base = recents.compactMap { channelByID[$0.channelStableID] }
        case .recordings:
            base = []
        case .guide:
            // The timeline owns its catalogue. The outgoing native channel list
            // must not expand to every playlist during the navigation transition.
            base = []
        case .source(let sourceID):
            base = channelsBySourceID[sourceID] ?? []
        case .group(let sourceID, let group):
            base = channelsByGroup[ChannelGroupKey(sourceID: sourceID, groupName: group)] ?? []
        case nil:
            base = channels
        }
        if sidebarSelection == .favorites || sidebarSelection == .recents { return base }
        return base.filter(isChannelVisible)
    }

    var favoriteChannels: [ChannelRecord] {
        let favorites = channels.filter(\.isFavorite)
        let byID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.stableID, $0) })
        return libraryPreferences.orderedFavoriteIDs(favorites.map(\.stableID)).compactMap { byID[$0] }
    }

    func isChannelVisible(_ channel: ChannelRecord) -> Bool {
        libraryPreferences.isGroupVisible(channel.groupName, sourceID: channel.sourceID)
    }

    func setGroupVisible(_ visible: Bool, group: String, sourceID: UUID) {
        libraryPreferences.setGroupVisible(visible, group: group, sourceID: sourceID)
        if !visible, sidebarSelection == .group(sourceID, group) { sidebarSelection = .source(sourceID) }
    }

    func moveFavorites(from offsets: IndexSet, to destination: Int) {
        libraryPreferences.moveFavorites(from: offsets, to: destination, availableIDs: favoriteChannels.map(\.stableID))
    }

    func moveFavorite(_ channel: ChannelRecord, by offset: Int) {
        let favorites = favoriteChannels
        guard let index = favorites.firstIndex(where: { $0.stableID == channel.stableID }),
              favorites.indices.contains(index + offset) else { return }
        moveFavorites(from: IndexSet(integer: index), to: offset > 0 ? index + offset + 1 : index + offset)
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
        if isGlobalChannelSearchActive { return "Search All Channels" }
        return switch sidebarSelection {
        case .favorites: "Favorites"
        case .recents: "Recently Watched"
        case .recordings: "Recordings"
        case .guide: "TV guide"
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

    var isGlobalChannelSearchActive: Bool {
        sidebarSelection != .recordings && sidebarSelection != .guide
            && !ChannelSearchIndex.normalize(searchText).isEmpty
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await Task.yield()
        // Defer catalogue reads until after SwiftUI can draw the launch view.
        // Large libraries should never delay creation of the first window.
        launchStatus = "Loading your channel library…"
        await restoreCatalogueForLaunch()
        isLoadingProgrammeGuide = !sources.isEmpty
        defer { isBootstrapping = false }
        // Enter the relay bootstrap phase before yielding to playlist refresh
        // work. Channel selection can still interleave while networking is in
        // progress, but playbackURL(for:) will now wait for that in-flight
        // restore instead of silently bypassing the persisted secure relay.
        launchStatus = "Restoring playback settings…"
        await airPlayRelayController.bootstrap()

        if sources.isEmpty {
            startGuideRefreshTimer()
            isLoadingProgrammeGuide = false
            beginAddingSource()
            return
        }

        for source in sources {
            launchStatus = "Restoring stream addresses…"
            await loadCachedPlaylist(for: source.id)
        }
        launchStatus = "Preparing your programme guide…"
        await restoreProgrammeWindow()
        isLoadingProgrammeGuide = false

        if case .favorites = sidebarSelection, let firstSource = sources.first {
            sidebarSelection = .source(firstSource.id)
        }

        // Cached content is ready to use. Network refreshes continue with the
        // normal interface visible instead of extending the launch screen.
        isBootstrapping = false

        startGuideRefreshTimer()

        for source in sources {
            if refreshIsDue(lastRefresh: source.lastPlaylistRefresh, interval: 6 * 60 * 60) {
                await refresh(sourceID: source.id, force: false)
            }
        }
    }

    func groups(for sourceID: UUID) -> [String] {
        _ = channelIndexRevision
        return groupNamesBySourceID[sourceID] ?? []
    }

    func channelCount(for sourceID: UUID) -> Int {
        _ = channelIndexRevision
        return channelCountBySourceID[sourceID] ?? 0
    }

    func searchContext(for channel: ChannelRecord) -> String {
        _ = channelIndexRevision
        let sourceName = sourceNameByID[channel.sourceID] ?? "Playlist"
        guard !channel.groupName.isEmpty else { return sourceName }
        return "\(sourceName) · \(channel.groupName)"
    }

    func sourceID(for selection: SidebarSelection?) -> UUID? {
        switch selection {
        case .source(let id), .group(let id, _): id
        default: nil
        }
    }

    func channel(withID stableID: String) -> ChannelRecord? {
        _ = channelIndexRevision
        return channelByID[stableID]
    }

    func currentProgramme(for channel: ChannelRecord, at date: Date = .now) -> ProgrammeRecord? {
        programmeGuideIndex.current(channelStableID: channel.stableID, at: date)
    }

    func nextProgramme(for channel: ChannelRecord, at date: Date = .now) -> ProgrammeRecord? {
        programmeGuideIndex.next(channelStableID: channel.stableID, at: date)
    }

    func schedule(for channel: ChannelRecord, from start: Date, to end: Date) -> [ProgrammeRecord] {
        programmeGuideIndex.schedule(channelStableID: channel.stableID, from: start, to: end)
    }

    func isPlaying(_ channel: ChannelRecord) -> Bool {
        playbackTarget == .channel(channel.stableID) && playerController.state != .idle
    }

    func play(_ channel: ChannelRecord, force: Bool = false) {
        // A List updates its selection binding before this action runs. Compare
        // the actual playback target so a new selection can replace old media.
        if !force, playbackTarget == .channel(channel.stableID), playbackIssue == nil,
           playbackPreparation != nil || playerController.state != .idle { return }
        playbackTarget = .channel(channel.stableID)
        playbackPreparationTask?.cancel()
        pendingRecentChannelID = nil
        playbackPreparation = nil
        playbackIssue = nil
        selectedChannelID = channel.stableID
        selectedRecordingID = nil
        playerController.stop()
        guard channel.isTransportAllowed else {
            finishRecordingAfterRejectedSelection()
            playbackIssue = PlaybackIssue(title: "This channel can't be opened",
                message: "The playlist doesn't contain a supported media address for this channel.")
            return
        }
        guard let streamURL = streamURLs[channel.stableID] else {
            finishRecordingAfterRejectedSelection()
            playbackIssue = PlaybackIssue(title: "Let's reconnect this channel",
                message: "Refresh its playlist to load the latest stream address.", sourceToRefresh: channel.sourceID)
            return
        }

        pendingRecentChannelID = channel.stableID
        let preparation = PlaybackPreparation(kind: .channel)
        playbackPreparation = preparation
        playbackPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if playbackPreparation?.id == preparation.id { playbackPreparation = nil } }
            await finishActiveRecording()
            guard !Task.isCancelled, playbackPreparation?.id == preparation.id else { return }
            do {
                let playbackURL = try await airPlayRelayController.playbackURL(for: streamURL)
                guard !Task.isCancelled, playbackPreparation?.id == preparation.id,
                      selectedChannelID == channel.stableID else { return }
                playerController.play(
                    url: playbackURL, channelName: channel.name,
                    allowsExternalPlayback: !airPlayRelayController.playbackIsRelayed,
                    preferQuickStart: airPlayRelayController.playbackIsRelayed
                )
                // Dismiss the blocking overlay now. Readiness continues on the
                // same task (and is cancelled on stop/change), but never reloads
                // this item or resets the live buffer/recording.
                playbackPreparation = nil
                guard airPlayRelayController.playbackIsRelayed else { return }
                let airPlayReady = await airPlayRelayController.prepareAirPlayForCurrentPlayback()
                guard !Task.isCancelled, selectedChannelID == channel.stableID else { return }
                playerController.setExternalPlaybackAllowed(airPlayReady)
            } catch {
                guard !Task.isCancelled, playbackPreparation?.id == preparation.id else { return }
                playbackIssue = PlaybackIssue(title: "This channel couldn't open", message: safeMessage(for: error))
            }
        }
    }

    func play(_ recording: RecordingRecord, force: Bool = false) {
        if !force, playbackTarget == .recording(recording.id), playbackIssue == nil,
           playbackPreparation != nil || playerController.state != .idle { return }
        playbackTarget = .recording(recording.id)
        playbackPreparationTask?.cancel()
        pendingRecentChannelID = nil
        playbackIssue = nil
        selectedRecordingID = recording.id
        selectedChannelID = nil
        playerController.stop()
        let preparation = PlaybackPreparation(kind: .recording)
        playbackPreparation = preparation
        playbackPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if playbackPreparation?.id == preparation.id { playbackPreparation = nil } }
            await finishActiveRecording()
            guard !Task.isCancelled, playbackPreparation?.id == preparation.id else { return }
            do {
                guard let recordingStorage else { throw RecordingStorageError.applicationSupportUnavailable }
                let packageName = recording.packageName
                let playbackURL = try await Task.detached(priority: .userInitiated) {
                    try recordingStorage.playbackURL(inPackageNamed: packageName)
                }.value
                guard !Task.isCancelled, playbackPreparation?.id == preparation.id else { return }
                playerController.play(url: playbackURL, channelName: recording.channelName, allowsExternalPlayback: false)
                generateMissingThumbnail(for: recording, playbackURL: playbackURL)
            } catch {
                guard !Task.isCancelled, playbackPreparation?.id == preparation.id else { return }
                playbackIssue = PlaybackIssue(title: "This recording couldn't open", message: safeMessage(for: error))
            }
        }
    }

    func stopPlayback() {
        playbackPreparationTask?.cancel()
        playbackTarget = nil
        pendingRecentChannelID = nil
        playbackPreparation = nil
        playbackIssue = nil
        playerController.stop()
        if bufferRecordingPhase.isEnabled { setSaveBufferEnabled(false) }
    }

    func retryPlayback() {
        if let sourceID = playbackIssue?.sourceToRefresh, let channel = selectedChannel {
            let preparation = PlaybackPreparation(kind: .channel)
            playbackPreparation = preparation
            playbackIssue = nil
            playbackPreparationTask?.cancel()
            playbackPreparationTask = Task { [weak self] in
                guard let self else { return }
                await refresh(sourceID: sourceID, force: true)
                guard !Task.isCancelled, playbackPreparation?.id == preparation.id else { return }
                playbackPreparation = nil
                if let refreshed = self.channel(withID: channel.stableID) {
                    play(refreshed, force: true)
                } else {
                    selectedChannelID = nil
                }
            }
        } else if let channel = selectedChannel { play(channel, force: true) }
        else if let recording = selectedRecording { play(recording, force: true) }
    }

    func refreshRecordingDiskSpace() async {
        guard let recordingStorage else { return }
        let root = recordingStorage.rootURL.deletingLastPathComponent()
        availableRecordingBytes = await Task.detached(priority: .utility) {
            let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        }.value
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
            bufferRecordingPhase = .failed("Choose a playing channel before starting a recording.")
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
        guideSearchIndex.setFavorite(channel.isFavorite, channelID: channel.stableID)
        guideSearchRevision &+= 1
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
            sourceDraft.guideMode = guidePreferences(for: source.id).mode
            sourceEditorError = nil
            isPresentingSourceEditor = true
        } catch {
            presentedAlert = AppAlert(title: "Playlist Could Not Be Edited", message: safeMessage(for: error))
        }
    }

    func commitSourceDraft() async -> Bool {
        sourceEditorError = nil
        if let sourceID = editingSourceID, refreshingGuides.contains(sourceID) {
            sourceEditorError = "The guide is refreshing. Please wait for it to finish before saving changes."
            return false
        }
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
        sourceSaveStatus = "Saving settings…"
        defer { isSavingSource = false }

        do {
            // Editing a guide or display name must not fetch/re-import a large unchanged playlist.
            if let sourceID = editingSourceID,
               let existing = source(withID: sourceID),
               try await keychain.playlistURL(for: sourceID) == playlistURL {
                try await keychain.setEPGURL(epgOverride, for: sourceID)
                var preferences = guidePreferences(for: sourceID)
                preferences.mode = sourceDraft.guideMode
                saveGuidePreferences(preferences, for: sourceID)
                let name = sourceDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { existing.displayName = name }
                sourceNameByID[sourceID] = existing.displayName
                existing.epgETag = nil
                existing.epgLastModified = nil
                existing.lastEPGRefresh = nil
                existing.lastErrorMessage = nil
                try modelContext.save()
                editingSourceID = nil
                sourceDraft = SourceDraft()
                Task { [weak self] in
                    guard let self else { return }
                    if self.runtimePlaylists[sourceID] == nil { await self.loadCachedPlaylist(for: sourceID) }
                    await self.refreshGuideOnly(sourceID)
                }
                return true
            }
            sourceSaveStatus = "Downloading playlist…"
            let result = try await httpClient.fetch(playlistURL, policy: .playlist)
            guard case .modified(let payload) = result else {
                throw AppModelError.invalidFreshResponse
            }
            sourceSaveStatus = "Reading playlist…"
            let parsed = try await parsePlaylist(payload.data, baseURL: playlistURL)
            let sourceID = editingSourceID ?? UUID()

            try await keychain.setPlaylistURL(playlistURL, for: sourceID)
            try await keychain.setEPGURL(epgOverride, for: sourceID)
            try await encryptedCache.store(payload.data, for: sourceID)

            var preferences = guidePreferences(for: sourceID)
            preferences.mode = sourceDraft.guideMode
            saveGuidePreferences(preferences, for: sourceID)

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
            sourceRecord.epgETag = nil
            sourceRecord.epgLastModified = nil
            try modelContext.save()
            sourceSaveStatus = "Updating channel library…"
            try apply(parsed, to: sourceID)

            sidebarSelection = .source(sourceID)
            reloadCoreState()

            // Guide downloads can span many countries. Do not hold the editor open while they run.
            Task { [weak self] in await self?.refreshGuideOnly(sourceID) }
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
            guideResults[sourceID] = nil
            preferenceStore.removeObject(forKey: "channelDeck.guide.\(sourceID.uuidString)")
            streamURLs = streamURLs.filter { key, _ in
                channelByID[key]?.sourceID != sourceID
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
                try await hydrateRuntimePlaylist(parsed, for: sourceID)
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
        guard refreshingGuides.insert(sourceID).inserted else { return }
        guideProgress[sourceID] = "Preparing programme guide…"
        defer { refreshingGuides.remove(sourceID); guideProgress[sourceID] = nil }
        var preferences = guidePreferences(for: sourceID)
        if preferences.mode == .playlist {
            for record in try programmesStored(for: sourceID) where preferences.managedChannels.contains(record.channelStableID) {
                modelContext.delete(record)
            }
            preferences.managedChannels = []
            saveGuidePreferences(preferences, for: sourceID)
            try modelContext.save()
            reloadProgrammeState()
            _ = try await refreshPlaylistEPG(for: sourceID, playlist: playlist)
            return
        }
        var providerError: Error?
        if preferences.mode == .automatic {
            guideProgress[sourceID] = "Refreshing playlist guide…"
            do {
                if try await refreshPlaylistEPG(for: sourceID, playlist: playlist) {
                    preferences.managedChannels = guidePreferences(for: sourceID).managedChannels
                }
            }
            catch { providerError = error }
        }
        let result = try await OpenEPGService.shared.refresh(channels: playlist.channels, sourceID: sourceID, preferences: preferences) { [weak self] message in
            await MainActor.run { self?.guideProgress[sourceID] = message }
        }
        guard source(withID: sourceID) != nil, runtimePlaylists[sourceID] == playlist else { return }
        guideResults[sourceID] = result
        guideProgress[sourceID] = "Saving programme listings…"
        let existing = try programmesStored(for: sourceID)
        let covered = Set(existing.filter { $0.endDate > .now && !preferences.managedChannels.contains($0.channelStableID) }.map(\.channelStableID))
        let supplemental = result.programmes.filter {
            preferences.mode == .openEPG || !covered.contains($0.channelID)
                || preferences.overrides[$0.channelID].map { !$0.isEmpty } == true
        }
        // Never erase a working guide because a public feed failed or went stale.
        let replacing = Set(supplemental.map(\.channelID))
        try await apply(supplemental, to: sourceID, replacingAll: false, usesStableIDs: true, replacingChannels: replacing)
        preferences.managedChannels.formUnion(replacing)
        saveGuidePreferences(preferences, for: sourceID)
        source(withID: sourceID)?.lastEPGRefresh = .now
        var warnings = result.warnings
        if let providerError { warnings.insert("Playlist guide unavailable: \(safeMessage(for: providerError))", at: 0) }
        source(withID: sourceID)?.lastErrorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        try modelContext.save()
        reloadLocalState()
    }

    private func refreshPlaylistEPG(for sourceID: UUID, playlist: ParsedPlaylist) async throws -> Bool {
        let override = try await keychain.epgURL(for: sourceID)
        guard let epgURL = override ?? playlist.epgURLs.first else { return false }
        guard let sourceRecord = source(withID: sourceID) else { return false }

        let validators = HTTPValidators(etag: sourceRecord.epgETag, lastModified: sourceRecord.epgLastModified)
        let result = try await httpClient.fetch(epgURL, validators: validators, policy: .epg)
        let responseValidators: HTTPValidators
        let changed: Bool

        switch result {
        case .notModified(let received):
            changed = false
            responseValidators = received
        case .modified(let payload):
            changed = true
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

            let channelIDs = Set(playlist.channels.filter(EPGMatcher.isLive).compactMap(\.tvgID))
            let lowerBound = Date.now.addingTimeInterval(-2 * 60 * 60)
            let upperBound = Date.now.addingTimeInterval(36 * 60 * 60)
            let parsedProgrammes = try await Task.detached(priority: .utility) { [xmlTVParser] in
                try xmlTVParser.parse(
                    data: xmlData,
                    channelIDs: channelIDs,
                    timeWindow: lowerBound ..< upperBound
                )
            }.value
            var preferences = guidePreferences(for: sourceID)
            let incomingIDs = Set(parsedProgrammes.map(\.channelID))
            let providerChannels = Set(channels.filter { $0.sourceID == sourceID && incomingIDs.contains($0.tvgID ?? "") }.map(\.stableID))
            let preserved = preferences.mode == .automatic ? preferences.managedChannels.subtracting(providerChannels) : []
            try await apply(parsedProgrammes, to: sourceID, preservingChannels: preserved)
            preferences.managedChannels = preserved
            saveGuidePreferences(preferences, for: sourceID)
        }

        guard let refreshedSource = source(withID: sourceID) else { return false }
        refreshedSource.epgETag = responseValidators.etag
        refreshedSource.epgLastModified = responseValidators.lastModified
        refreshedSource.lastEPGRefresh = Date.now
        try modelContext.save()
        reloadLocalState()
        return changed
    }

    private func apply(_ playlist: ParsedPlaylist, to sourceID: UUID) throws {
        runtimePlaylists[sourceID] = playlist
        let existing = Dictionary(
            uniqueKeysWithValues: channels.filter { $0.sourceID == sourceID }.map { ($0.stableID, $0) }
        )
        var retainedIDs: Set<String> = []

        // Use the catalogue index here: a linear scan per URL makes large
        // playlist refreshes quadratic and blocks the main thread for minutes.
        streamURLs = streamURLs.filter { key, _ in
            channelByID[key]?.sourceID != sourceID
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

    private func apply(_ parsedProgrammes: [ParsedProgramme], to sourceID: UUID, replacingAll: Bool = true, usesStableIDs: Bool = false, preservingChannels: Set<String> = [], replacingChannels: Set<String> = []) async throws {
        let oldRecords = try programmesStored(for: sourceID)
        for (index, record) in oldRecords.enumerated() where (replacingAll && !preservingChannels.contains(record.channelStableID)) || replacingChannels.contains(record.channelStableID) {
            modelContext.delete(record)
            if index % 200 == 199 {
                try await Task.sleep(for: .milliseconds(1))
                guard source(withID: sourceID) != nil else { return }
            }
        }

        let parsedChannels = runtimePlaylists[sourceID]?.channels ?? []
        let liveIDs = await Task.detached(priority: .utility) {
            Set(parsedChannels.filter(EPGMatcher.isLive).map { $0.stableKey(sourceID: sourceID).rawValue })
        }.value
        let channelIDs = Dictionary(grouping: channels.filter { $0.sourceID == sourceID && liveIDs.contains($0.stableID) && (usesStableIDs || $0.tvgID != nil) }) {
            usesStableIDs ? $0.stableID : ($0.tvgID ?? "")
        }
        for (index, programme) in parsedProgrammes.enumerated() {
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
            if index % 200 == 199 {
                guideProgress[sourceID] = "Saving listings · \(index + 1) of \(parsedProgrammes.count)…"
                try await Task.sleep(for: .milliseconds(1))
                guard source(withID: sourceID) != nil else { return }
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

    /// The launch profile showed several seconds in the all-at-once model fetch
    /// and Swift comparator. Read and sort on a background model actor, attach
    /// main-context model references in batches, then publish the catalogue once.
    func restoreCatalogueForLaunch() async {
        do {
            let restoredSources = try modelContext.fetch(FetchDescriptor<PlaylistSourceRecord>(
                sortBy: [SortDescriptor(\.sortIndex)]
            ))
            let sourceOrders = Dictionary(uniqueKeysWithValues: restoredSources.enumerated().map { ($0.element.id, $0.offset) })
            let sourceNames = Dictionary(uniqueKeysWithValues: restoredSources.map { ($0.id, $0.displayName) })
            let container = modelContext.container
            let records = try await Task.detached(priority: .userInitiated) {
                let reader = CatalogueSnapshotReader(modelContainer: container)
                return try await reader.channels().filter { sourceOrders[$0.sourceID] != nil }.sorted {
                    if $0.sourceID != $1.sourceID { return sourceOrders[$0.sourceID]! < sourceOrders[$1.sourceID]! }
                    if $0.order != $1.order { return $0.order < $1.order }
                    return $0.id < $1.id
                }
            }.value
            try Task.checkCancellation()
            var restoredChannels: [ChannelRecord] = []
            var byID: [String: ChannelRecord] = [:]
            var bySource: [UUID: [ChannelRecord]] = [:]
            var byGroup: [ChannelGroupKey: [ChannelRecord]] = [:]
            var groups: [UUID: Set<String>] = [:]
            var snapshots: [LaunchChannelSnapshot] = []
            for (offset, record) in records.enumerated() {
                guard let channel = modelContext.model(for: record.persistentID) as? ChannelRecord else { continue }
                let id = record.id, group = record.group, sourceID = record.sourceID
                restoredChannels.append(channel)
                bySource[sourceID, default: []].append(channel)
                byID[id] = channel
                byGroup[ChannelGroupKey(sourceID: sourceID, groupName: group), default: []].append(channel)
                if !group.isEmpty { groups[sourceID, default: []].insert(group) }
                snapshots.append(LaunchChannelSnapshot(id: id, name: record.name, group: group,
                    sourceID: sourceID, sourceName: sourceNames[sourceID] ?? "", sourceOrder: sourceOrders[sourceID] ?? .max,
                    order: record.order, isFavorite: record.isFavorite))
                if offset.isMultiple(of: 256) {
                    launchStatus = "Restoring channels · \(restoredChannels.count.formatted())"
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            launchStatus = "Preparing channel search…"
            let searchInput = snapshots
            let indexes = await Task.detached(priority: .userInitiated) {
                let channelIndex = ChannelSearchIndex(entries: searchInput.map {
                    ChannelSearchEntry(stableID: $0.id, channelName: $0.name, groupName: $0.group,
                                       sourceName: $0.sourceName, sourceOrder: $0.sourceOrder, channelOrder: $0.order)
                })
                var guideIndex = GuideSearchIndex()
                guideIndex.replaceChannels(searchInput.map {
                    GuideSearchChannel(stableID: $0.id, sourceID: $0.sourceID, name: $0.name, groupName: $0.group)
                }, favoriteIDs: Set(searchInput.lazy.filter(\.isFavorite).map(\.id)))
                return (channelIndex, guideIndex)
            }.value
            try Task.checkCancellation()
            sources = restoredSources
            channels = restoredChannels
            sourceNameByID = Dictionary(restoredSources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            channelByID = byID
            channelsBySourceID = bySource
            channelsByGroup = byGroup
            channelCountBySourceID = bySource.mapValues(\.count)
            groupNamesBySourceID = groups.mapValues { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
            channelSearchIndex = indexes.0
            guideSearchIndex = indexes.1
            channelIndexRevision &+= 1
            guideSearchRevision &+= 1
            scheduleGlobalChannelSearch()
            reloadRecents()
            reloadRecordings()
        } catch is CancellationError {
            return
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "The local channel library could not be read.")
        }
    }

    private func restoreProgrammeWindow(at date: Date = .now) async {
        let initialRevision = guideSearchRevision
        do {
            let upperBound = date.addingTimeInterval(6 * 60 * 60)
            let container = modelContext.container
            let snapshots = try await Task.detached(priority: .userInitiated) {
                let reader = CatalogueSnapshotReader(modelContainer: container)
                return try await reader.programmes(from: date, to: upperBound)
            }.value
            try Task.checkCancellation()
            var restored: [ProgrammeRecord] = []
            var schedules: [String: [ProgrammeRecord]] = [:]
            for (offset, snapshot) in snapshots.enumerated() {
                guard let programme = modelContext.model(for: snapshot.persistentID) as? ProgrammeRecord else { continue }
                restored.append(programme)
                schedules[snapshot.channelID, default: []].append(programme)
                if offset.isMultiple(of: 256) { try await Task.sleep(for: .milliseconds(1)) }
            }
            let searchInput = snapshots
            let channelIndex = guideSearchIndex
            let index = await Task.detached(priority: .userInitiated) {
                var index = channelIndex
                index.replaceProgrammes(searchInput.map {
                    GuideSearchProgramme(channelID: $0.channelID, title: $0.title, start: $0.start, end: $0.end)
                })
                return index
            }.value
            try Task.checkCancellation()
            let programmeIndex = ProgrammeGuideIndex(schedules: schedules)
            // A provider refresh or favorite edit may have published newer guide
            // state while we yielded. Never replace it with this older snapshot.
            guard !Task.isCancelled, guideSearchRevision == initialRevision else { return }
            programmes = restored
            programmeGuideIndex = programmeIndex
            guideSearchIndex = index
            guideSearchRevision &+= 1
        } catch is CancellationError {
            return
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "The local programme guide could not be read.")
        }
    }

    private func reloadCoreState() {
        do {
            sources = try modelContext.fetch(FetchDescriptor<PlaylistSourceRecord>())
                .sorted { $0.sortIndex < $1.sortIndex }
            channels = try modelContext.fetch(FetchDescriptor<ChannelRecord>())
                .sorted { lhs, rhs in
                    lhs.sourceID == rhs.sourceID ? lhs.sortIndex < rhs.sortIndex : lhs.name < rhs.name
                }
            rebuildChannelIndexes()
            reloadRecents()
            reloadRecordings()
        } catch {
            presentedAlert = AppAlert(title: "Library Error", message: "The local channel library could not be read.")
        }
    }

    private func rebuildChannelIndexes() {
        sourceNameByID = Dictionary(
            sources.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let sourceOrderByID = Dictionary(
            uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) }
        )
        channelByID = Dictionary(
            channels.map { ($0.stableID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        channelsBySourceID = Dictionary(grouping: channels, by: \.sourceID)
        channelCountBySourceID = channelsBySourceID.mapValues(\.count)

        channelsByGroup = Dictionary(
            grouping: channels,
            by: { ChannelGroupKey(sourceID: $0.sourceID, groupName: $0.groupName) }
        )
        groupNamesBySourceID = channelsBySourceID.mapValues { sourceChannels in
            Array(Set(sourceChannels.lazy.map(\.groupName)))
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        channelSearchIndex = ChannelSearchIndex(
            entries: channels.map { channel in
                ChannelSearchEntry(
                    stableID: channel.stableID,
                    channelName: channel.name,
                    groupName: channel.groupName,
                    sourceName: sourceNameByID[channel.sourceID] ?? "",
                    sourceOrder: sourceOrderByID[channel.sourceID] ?? .max,
                    channelOrder: channel.sortIndex
                )
            }
        )
        guideSearchIndex.replaceChannels(channels.map { channel in
            GuideSearchChannel(stableID: channel.stableID, sourceID: channel.sourceID,
                               name: channel.name, groupName: channel.groupName)
        }, favoriteIDs: Set(channels.lazy.filter(\.isFavorite).map(\.stableID)))
        guideSearchRevision &+= 1
        channelIndexRevision &+= 1
        scheduleGlobalChannelSearch()
    }

    private func scheduleGlobalChannelSearch() {
        channelSearchTask?.cancel()
        let query = ChannelSearchIndex.normalize(searchText)
        guard !query.isEmpty else {
            globalChannelSearchResultIDs = []
            isSearchingChannels = false
            return
        }

        globalChannelSearchResultIDs = []
        isSearchingChannels = true
        let index = channelSearchIndex
        channelSearchTask = Task { @MainActor [weak self] in
            do {
                // Coalesce fast typing without blocking navigation or playback.
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            let resultIDs = await Task.detached(priority: .userInitiated) {
                index.matchingIDs(for: query)
            }.value
            guard !Task.isCancelled,
                  let self,
                  ChannelSearchIndex.normalize(searchText) == query else { return }
            globalChannelSearchResultIDs = resultIDs
            isSearchingChannels = false
        }
    }

    func refreshGuideWindow() {
        guard guideWindowRefreshTask == nil else { return }
        guideWindowRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { guideWindowRefreshTask = nil }
            await restoreProgrammeWindow()
        }
    }

    private func reloadProgrammeState(at date: Date = .now) {
        do {
            // Load the current broadcast plus the timeline's three two-hour pages,
            // without materializing the complete 36-hour provider guide.
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
            guideSearchIndex.replaceProgrammes(programmes.map { programme in
                GuideSearchProgramme(channelID: programme.channelStableID, title: programme.title,
                                     start: programme.startDate, end: programme.endDate)
            })
            guideSearchRevision &+= 1
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

    private func hydrateRuntimePlaylist(_ playlist: ParsedPlaylist, for sourceID: UUID) async throws {
        // Stable-key Unicode normalization over tens of thousands of cached
        // entries is CPU work, not UI work. Only immutable values leave this actor.
        var channelIDs = Set<String>()
        let sourceChannels = channelsBySourceID[sourceID] ?? []
        for (offset, channel) in sourceChannels.enumerated() {
            channelIDs.insert(channel.stableID)
            if offset.isMultiple(of: 256) { await Task.yield() }
        }
        let knownIDs = channelIDs
        let worker = Task.detached(priority: .userInitiated) {
            try RuntimeStreamIndex.build(playlist, sourceID: sourceID, channelIDs: knownIDs)
        }
        let restoredURLs = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard source(withID: sourceID) != nil else { return }
        runtimePlaylists[sourceID] = playlist
        streamURLs = streamURLs.filter { !channelIDs.contains($0.key) }
        streamURLs.merge(restoredURLs, uniquingKeysWith: { _, restored in restored })
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

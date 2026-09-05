import Foundation
import Observation

enum GuideScope: Hashable, Sendable {
    case favorites, all, source(UUID)
}

struct GuideSearchRequest: Hashable, Sendable {
    let query: String
    let scope: GuideScope
    let window: GuideWindow
    let listingsOnly: Bool
    var revision: Int = 0
}

/// Immutable values keep SwiftData objects and their observation machinery out of search work.
struct GuideSearchChannel: Sendable {
    let stableID: String
    let sourceID: UUID
    let groupName: String
    let normalizedName: String
    let normalizedGroup: String

    init(stableID: String, sourceID: UUID, name: String, groupName: String) {
        self.stableID = stableID
        self.sourceID = sourceID
        self.groupName = groupName
        normalizedName = ChannelSearchIndex.normalize(name)
        normalizedGroup = ChannelSearchIndex.normalize(groupName)
    }
}

struct GuideSearchProgramme: Sendable {
    let channelID: String
    let normalizedTitle: String
    let start: Date
    let end: Date

    init(channelID: String, title: String, start: Date, end: Date) {
        self.channelID = channelID
        normalizedTitle = ChannelSearchIndex.normalize(title)
        self.start = start
        self.end = end
    }
}

struct GuideSearchIndex: Sendable {
    private var channels: [GuideSearchChannel] = []
    private var channelsWithListings: [GuideSearchChannel] = []
    private var channelOffsets: [String: Int] = [:]
    private var schedules: [String: [GuideSearchProgramme]] = [:]
    private(set) var favoriteIDs = Set<String>()

    mutating func replaceChannels(_ channels: [GuideSearchChannel], favoriteIDs: Set<String>) {
        self.channels = channels
        channelOffsets = Dictionary(channels.enumerated().map { ($0.element.stableID, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })
        self.favoriteIDs = favoriteIDs
        rebuildListedChannels()
    }

    mutating func replaceProgrammes(_ programmes: [GuideSearchProgramme]) {
        schedules = Dictionary(grouping: programmes, by: \.channelID)
        rebuildListedChannels()
    }

    private mutating func rebuildListedChannels() {
        channelsWithListings = schedules.keys.compactMap { channelOffsets[$0] }.sorted().map { channels[$0] }
    }

    mutating func setFavorite(_ isFavorite: Bool, channelID: String) {
        if isFavorite { favoriteIDs.insert(channelID) } else { favoriteIDs.remove(channelID) }
    }

    func matchingIDs(for request: GuideSearchRequest, preferences: LibraryPreferences) throws -> [String] {
        try Task.checkCancellation()
        let query = ChannelSearchIndex.normalize(request.query)
        // Favorite searches touch only favorites, even when the catalogue has 60,000 channels.
        let candidates: [GuideSearchChannel]
        if request.scope == .favorites {
            let cataloguedFavorites = favoriteIDs.compactMap { channelOffsets[$0] }.sorted().map { channels[$0] }
            let orderedIDs = preferences.orderedFavoriteIDs(cataloguedFavorites.map(\.stableID))
            candidates = orderedIDs.compactMap { channelOffsets[$0].map { channels[$0] } }
        } else {
            // Most large IPTV catalogues include many channels with no EPG.
            // Skip those entirely when the guide is showing channels with listings.
            candidates = request.listingsOnly ? channelsWithListings : channels
        }

        var matches: [String] = []
        for (offset, channel) in candidates.enumerated() {
            // Cancel abandoned scans promptly, including a query with no matches.
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            if case .source(let sourceID) = request.scope, channel.sourceID != sourceID { continue }
            if request.scope != .favorites,
               !preferences.isGroupVisible(channel.groupName, sourceID: channel.sourceID) { continue }

            let channelMatches = query.isEmpty || channel.normalizedName.contains(query) || channel.normalizedGroup.contains(query)
            if channelMatches && !request.listingsOnly {
                matches.append(channel.stableID)
                continue
            }
            // No per-channel temporary schedule arrays, and titles are folded once at refresh time.
            let schedule = schedules[channel.stableID] ?? []
            var matchesListing = false
            for (position, programme) in schedule.enumerated() {
                if position.isMultiple(of: 128) { try Task.checkCancellation() }
                if programme.end > request.window.start && programme.start < request.window.end,
                   channelMatches || programme.normalizedTitle.contains(query) {
                    matchesListing = true
                    break
                }
            }
            if matchesListing { matches.append(channel.stableID) }
        }
        try Task.checkCancellation()
        return matches
    }
}

@MainActor
@Observable
final class GuideSearchController {
    private(set) var channelIDs: [String] = []
    private(set) var isSearching = false
    @ObservationIgnored private var generation = UUID()

    func update(request: GuideSearchRequest, index: GuideSearchIndex, preferences: LibraryPreferences) async {
        let currentGeneration = UUID()
        generation = currentGeneration
        isSearching = true
        defer { if generation == currentGeneration { isSearching = false } }
        do {
            // Keep current rows visible while a burst of typing settles. Clearing is immediate.
            if !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await Task.sleep(for: .milliseconds(120))
            }
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                try index.matchingIDs(for: request, preferences: preferences)
            }
            let matches = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            channelIDs = matches
        } catch is CancellationError {
            // A newer query or leaving the guide owns the next result.
        } catch {
            // The in-memory matcher only throws cancellation.
        }
    }
}

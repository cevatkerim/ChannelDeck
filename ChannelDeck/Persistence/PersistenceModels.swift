import Foundation
import SwiftData

struct CatalogueChannelSnapshot: Sendable {
    let persistentID: PersistentIdentifier
    let id: String
    let sourceID: UUID
    let name: String
    let group: String
    let order: Int
    let isFavorite: Bool
}

struct CatalogueProgrammeSnapshot: Sendable {
    let persistentID: PersistentIdentifier
    let id: String
    let channelID: String
    let title: String
    let start: Date
    let end: Date
}

/// Created on a detached task so its model executor is not bound to the UI
/// context. Only immutable snapshots/identifiers cross the actor boundary.
@ModelActor
actor CatalogueSnapshotReader {
    func channels() throws -> [CatalogueChannelSnapshot] {
        var descriptor = FetchDescriptor<ChannelRecord>()
        descriptor.includePendingChanges = false
        return try modelContext.fetch(descriptor).map {
            CatalogueChannelSnapshot(persistentID: $0.persistentModelID, id: $0.stableID,
                sourceID: $0.sourceID, name: $0.name, group: $0.groupName, order: $0.sortIndex, isFavorite: $0.isFavorite)
        }
    }

    func programmes(from date: Date, to upperBound: Date) throws -> [CatalogueProgrammeSnapshot] {
        var descriptor = FetchDescriptor<ProgrammeRecord>(
            predicate: #Predicate { $0.endDate > date && $0.startDate < upperBound }
        )
        descriptor.includePendingChanges = false
        return try modelContext.fetch(descriptor).map {
            CatalogueProgrammeSnapshot(persistentID: $0.persistentModelID, id: $0.stableID,
                channelID: $0.channelStableID, title: $0.title, start: $0.startDate, end: $0.endDate)
        }.sorted {
            if $0.channelID != $1.channelID { return $0.channelID < $1.channelID }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }
}

@Model
final class PlaylistSourceRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var sortIndex: Int
    var lastPlaylistRefresh: Date?
    var lastEPGRefresh: Date?
    var playlistETag: String?
    var playlistLastModified: String?
    var epgETag: String?
    var epgLastModified: String?
    var lastErrorMessage: String?

    init(id: UUID = UUID(), displayName: String, sortIndex: Int) {
        self.id = id
        self.displayName = displayName
        self.sortIndex = sortIndex
    }
}

@Model
final class ChannelRecord {
    @Attribute(.unique) var stableID: String
    var sourceID: UUID
    var tvgID: String?
    var name: String
    var groupName: String
    var logoURLString: String?
    var sortIndex: Int
    var isFavorite: Bool
    var isTransportAllowed: Bool

    init(
        stableID: String,
        sourceID: UUID,
        tvgID: String?,
        name: String,
        groupName: String,
        logoURLString: String?,
        sortIndex: Int,
        isFavorite: Bool = false,
        isTransportAllowed: Bool = true
    ) {
        self.stableID = stableID
        self.sourceID = sourceID
        self.tvgID = tvgID
        self.name = name
        self.groupName = groupName
        self.logoURLString = logoURLString
        self.sortIndex = sortIndex
        self.isFavorite = isFavorite
        self.isTransportAllowed = isTransportAllowed
    }

    var logoURL: URL? {
        guard let logoURLString else { return nil }
        return URL(string: logoURLString)
    }
}

@Model
final class ProgrammeRecord {
    @Attribute(.unique) var stableID: String
    var sourceID: UUID
    var channelStableID: String
    var title: String
    var programmeDescription: String?
    var startDate: Date
    var endDate: Date

    init(
        stableID: String,
        sourceID: UUID,
        channelStableID: String,
        title: String,
        programmeDescription: String?,
        startDate: Date,
        endDate: Date
    ) {
        self.stableID = stableID
        self.sourceID = sourceID
        self.channelStableID = channelStableID
        self.title = title
        self.programmeDescription = programmeDescription
        self.startDate = startDate
        self.endDate = endDate
    }
}

@Model
final class RecentChannelRecord {
    @Attribute(.unique) var channelStableID: String
    var sourceID: UUID
    var lastPlayedAt: Date

    init(channelStableID: String, sourceID: UUID, lastPlayedAt: Date = .now) {
        self.channelStableID = channelStableID
        self.sourceID = sourceID
        self.lastPlayedAt = lastPlayedAt
    }
}

@Model
final class RecordingRecord {
    @Attribute(.unique) var id: UUID
    var channelStableID: String
    var sourceID: UUID
    var channelName: String
    var groupName: String
    var logoURLString: String?
    var programmeTitle: String?
    var programmeDescription: String?
    var programmeStartDate: Date?
    var programmeEndDate: Date?
    var startedAt: Date
    var endedAt: Date
    var duration: TimeInterval
    var packageName: String
    var thumbnailFileName: String?
    var qualityRawValue: String?

    init(
        id: UUID,
        channelStableID: String,
        sourceID: UUID,
        channelName: String,
        groupName: String,
        logoURLString: String?,
        programmeTitle: String?,
        programmeDescription: String?,
        programmeStartDate: Date?,
        programmeEndDate: Date?,
        startedAt: Date,
        endedAt: Date,
        duration: TimeInterval,
        packageName: String,
        thumbnailFileName: String?,
        qualityRawValue: String? = nil
    ) {
        self.id = id
        self.channelStableID = channelStableID
        self.sourceID = sourceID
        self.channelName = channelName
        self.groupName = groupName
        self.logoURLString = logoURLString
        self.programmeTitle = programmeTitle
        self.programmeDescription = programmeDescription
        self.programmeStartDate = programmeStartDate
        self.programmeEndDate = programmeEndDate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.packageName = packageName
        self.thumbnailFileName = thumbnailFileName
        self.qualityRawValue = qualityRawValue
    }
}

enum ChannelDeckSchema {
    static let schema = Schema([
        PlaylistSourceRecord.self,
        ChannelRecord.self,
        ProgrammeRecord.self,
        RecentChannelRecord.self,
        RecordingRecord.self
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "ChannelDeck",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

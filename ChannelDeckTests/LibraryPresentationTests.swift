import Foundation
import SwiftData
import XCTest
@testable import ChannelDeck

final class LibraryPreferencesTests: XCTestCase {
    func testHiddenGroupsAreScopedToTheirPlaylistAndCanBeRestored() throws {
        let first = UUID(), second = UUID()
        var preferences = LibraryPreferences()
        preferences.setGroupVisible(false, group: "Sports", sourceID: first)
        XCTAssertFalse(preferences.isGroupVisible("Sports", sourceID: first))
        XCTAssertTrue(preferences.isGroupVisible("Sports", sourceID: second))
        XCTAssertTrue(preferences.isGroupVisible("News", sourceID: first))
        let restored = try JSONDecoder().decode(LibraryPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        preferences.setGroupVisible(true, group: "Sports", sourceID: first)
        XCTAssertTrue(preferences.hiddenGroups.isEmpty)
    }

    func testFavoriteOrderSurvivesRefreshAndAppendsNewFavoritesWithoutDuplicates() {
        let preferences = LibraryPreferences(favoriteOrder: ["removed", "b", "b", "a"])
        XCTAssertEqual(preferences.orderedFavoriteIDs(["a", "new", "b", "new"]), ["b", "a", "new"])
    }

    func testMovingFavoritesInEitherDirectionUsesListInsertionSemantics() {
        var preferences = LibraryPreferences()
        let ids = ["a", "b", "c", "d"]
        preferences.moveFavorites(from: IndexSet(integer: 0), to: 3, availableIDs: ids)
        XCTAssertEqual(preferences.favoriteOrder, ["b", "c", "a", "d"])
        preferences.moveFavorites(from: IndexSet(integer: 3), to: 0, availableIDs: ids)
        XCTAssertEqual(preferences.favoriteOrder, ["d", "b", "c", "a"])
    }

    func testMovingMultipleFavoritesPreservesRelativeOrderAndIgnoresStaleOffsets() {
        var preferences = LibraryPreferences()
        preferences.moveFavorites(from: IndexSet([1, 3, 100]), to: 5, availableIDs: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(preferences.favoriteOrder, ["a", "c", "e", "b", "d"])
    }
}

final class GuideWindowTests: XCTestCase {
    private let window = GuideWindow(containing: Date(timeIntervalSince1970: 1800 * 100 + 123))

    func testWindowAlignsToHalfHourAndPagesAreContiguous() {
        XCTAssertEqual(window.start.timeIntervalSince1970, 1800 * 100)
        XCTAssertEqual(GuideWindow(containing: window.start, page: 1).start, window.end)
    }

    func testProgrammesAreClippedToVisibleTimeWithoutNegativeWidths() throws {
        let spanning = try XCTUnwrap(window.placement(start: window.start.addingTimeInterval(-1000), end: window.end.addingTimeInterval(1000)))
        XCTAssertEqual(spanning.offset, 0)
        XCTAssertEqual(spanning.width, 1)
        let clipped = try XCTUnwrap(window.placement(start: window.start.addingTimeInterval(-1800), end: window.start.addingTimeInterval(1800)))
        XCTAssertEqual(clipped.offset, 0)
        XCTAssertEqual(clipped.width, 0.25)
        XCTAssertNil(window.placement(start: window.end, end: window.end.addingTimeInterval(10)))
        XCTAssertNil(window.placement(start: window.start, end: window.start))
        XCTAssertNil(window.placement(start: window.end, end: window.start))
        XCTAssertNil(window.position(of: window.start.addingTimeInterval(-1)))
    }

    func testIndexedScheduleReturnsOnlyOverlappingProgrammesInTimeOrder() {
        let sourceID = UUID()
        func programme(_ id: String, channel: String = "one", start: Double, end: Double) -> ProgrammeRecord {
            ProgrammeRecord(stableID: id, sourceID: sourceID, channelStableID: channel,
                title: id, programmeDescription: nil,
                startDate: window.start.addingTimeInterval(start), endDate: window.start.addingTimeInterval(end))
        }
        let index = ProgrammeGuideIndex(programmes: [
            programme("later", start: 3600, end: 9000), programme("ended", start: -1000, end: 0),
            programme("other", channel: "two", start: 0, end: 1800), programme("current", start: -100, end: 1800),
            programme("outside", start: 7200, end: 9000)
        ])
        XCTAssertEqual(index.schedule(channelStableID: "one", from: window.start, to: window.end).map(\.stableID), ["current", "later"])
    }
}

@MainActor
final class PlaybackPresentationTests: XCTestCase {
    func testStartupRestoresBatchedCatalogueAndBothSearchIndexes() async throws {
        let container = try ChannelDeckSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let first = PlaylistSourceRecord(displayName: "First", sortIndex: 0)
        let second = PlaylistSourceRecord(displayName: "Second", sortIndex: 1)
        context.insert(second)
        context.insert(first)
        for offset in (0..<650).reversed() {
            context.insert(ChannelRecord(stableID: "channel-\(offset)", sourceID: first.id, tvgID: nil,
                name: offset == 42 ? "Télévision Unique" : "Channel \(offset)", groupName: "Sports",
                logoURLString: nil, sortIndex: offset, isFavorite: offset == 42))
        }
        context.insert(ChannelRecord(stableID: "second", sourceID: second.id, tvgID: nil,
            name: "Other", groupName: "News", logoURLString: nil, sortIndex: 0))
        let now = Date.now
        context.insert(ProgrammeRecord(stableID: "on-now", sourceID: first.id, channelStableID: "channel-42",
            title: "Current programme", programmeDescription: nil,
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(3600)))
        try context.save()
        let defaultsName = "ChannelDeckTests.Startup.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(modelContainer: container, keychain: PresentationTestKeychain(), preferenceStore: defaults)
        await model.restoreCatalogueForLaunch()

        XCTAssertNil(model.presentedAlert)
        XCTAssertEqual(model.sources.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.channels.count, 651)
        XCTAssertEqual(model.channelCount(for: first.id), 650)
        XCTAssertEqual(model.channelCount(for: second.id), 1)
        XCTAssertEqual(model.groups(for: first.id), ["Sports"])
        model.sidebarSelection = .source(first.id)
        XCTAssertEqual(model.filteredChannels.map(\.sortIndex), Array(0..<650))
        XCTAssertEqual(model.channel(withID: "channel-42")?.name, "Télévision Unique")
        XCTAssertTrue(model.guideHasFavorites)
        let request = GuideSearchRequest(query: "television unique", scope: .source(first.id),
                                        window: GuideWindow(containing: .now), listingsOnly: false)
        XCTAssertEqual(try model.guideSearchSnapshot.matchingIDs(for: request, preferences: model.libraryPreferences), ["channel-42"])
        model.searchText = "television unique"
        for _ in 0..<100 where model.isSearchingChannels { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.filteredChannels.map(\.stableID), ["channel-42"])

        model.refreshGuideWindow()
        XCTAssertTrue(model.programmes.isEmpty, "Opening the guide must not synchronously fetch its schedule")
        for _ in 0..<100 where model.programmes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let matchedChannel = try XCTUnwrap(model.channel(withID: "channel-42"))
        XCTAssertEqual(model.currentProgramme(for: matchedChannel)?.title, "Current programme")
        let listings = GuideSearchRequest(query: "current programme", scope: .source(first.id),
                                         window: GuideWindow(containing: now), listingsOnly: true)
        XCTAssertEqual(try model.guideSearchSnapshot.matchingIDs(for: listings, preferences: model.libraryPreferences), ["channel-42"])

        let snapshots = try await Task.detached {
            let reader = CatalogueSnapshotReader(modelContainer: container)
            return try await reader.channels()
        }.value
        XCTAssertEqual(Set(snapshots.map(\.id)).count, 651)
        let snapshot = try XCTUnwrap(snapshots.first { $0.id == "channel-42" })
        let attached = try XCTUnwrap(context.model(for: snapshot.persistentID) as? ChannelRecord)
        XCTAssertEqual(attached.name, snapshot.name)
        XCTAssertTrue(snapshot.isFavorite)
    }

    func testBoundChannelSelectionReplacesAnExistingPlayerItem() throws {
        let model = try makeModel()
        defer { model.stopPlayback() }
        model.playerController.play(url: URL(fileURLWithPath: "/tmp/channeldeck-test-missing.mov"), channelName: "Previous")
        let next = channel(id: "next")
        // SwiftUI writes the selection before calling the onChange action.
        model.selectedChannelID = next.stableID
        model.play(next)
        XCTAssertEqual(model.playbackIssue?.sourceToRefresh, next.sourceID)
        XCTAssertNil(model.playerController.player.currentItem)
    }

    func testBoundRecordingSelectionReplacesLivePlaybackAndDeduplicatesItsOwnAction() throws {
        let model = try makeModel()
        defer { model.stopPlayback() }
        model.selectedChannelID = "live"
        model.playerController.play(url: URL(fileURLWithPath: "/tmp/channeldeck-test-missing.mov"), channelName: "Live")
        let first = recording(), second = recording()
        model.selectedRecordingID = first.id
        model.play(first)
        XCTAssertNil(model.selectedChannelID)
        XCTAssertNil(model.playerController.player.currentItem)
        let firstPreparation = try XCTUnwrap(model.playbackPreparation?.id)
        model.play(first)
        XCTAssertEqual(model.playbackPreparation?.id, firstPreparation)

        model.selectedRecordingID = second.id
        model.play(second)
        XCTAssertNotEqual(model.playbackPreparation?.id, firstPreparation)
        XCTAssertNotNil(model.playbackPreparation)
    }

    func testMissingStreamOffersRefreshAndStopClearsTheIssue() throws {
        let model = try makeModel()
        let channel = channel(id: "unloaded")
        model.play(channel)
        XCTAssertEqual(model.selectedChannelID, channel.stableID)
        XCTAssertEqual(model.playbackIssue?.sourceToRefresh, channel.sourceID)
        XCTAssertNil(model.playbackPreparation)
        XCTAssertNil(model.presentedAlert, "Recoverable playback errors belong in the player")
        model.stopPlayback()
        XCTAssertNil(model.playbackIssue)
        XCTAssertNil(model.playbackPreparation)
        XCTAssertEqual(model.playerController.state, .idle)
    }

    func testChangingToUnsupportedChannelReplacesRefreshRecovery() throws {
        let model = try makeModel()
        model.play(channel(id: "unloaded"))
        let unsupported = channel(id: "unsupported")
        unsupported.isTransportAllowed = false
        model.play(unsupported)
        XCTAssertEqual(model.selectedChannelID, "unsupported")
        XCTAssertNotNil(model.playbackIssue)
        XCTAssertNil(model.playbackIssue?.sourceToRefresh)
        XCTAssertNil(model.playbackPreparation)
    }

    func testGuideNavigationDoesNotExpandTheOutgoingBrowserToEveryPlaylist() throws {
        let model = try makeModel()
        model.channels = [channel(id: "one"), channel(id: "two")]
        model.sidebarSelection = .guide
        model.searchText = "one"
        XCTAssertFalse(model.isGlobalChannelSearchActive, "The retained browser must not handle the guide's search")
        XCTAssertTrue(model.filteredChannels.isEmpty)
        XCTAssertEqual(model.channels.count, 2, "The guide still owns the complete catalogue")
    }

    func testHidingAGroupKeepsItsFavoritesReachableInTheirSavedOrder() throws {
        let model = try makeModel()
        let first = channel(id: "first"), second = channel(id: "second")
        first.isFavorite = true
        second.isFavorite = true
        model.channels = [first, second]
        model.libraryPreferences.favoriteOrder = ["second", "first"]
        model.setGroupVisible(false, group: first.groupName, sourceID: first.sourceID)
        model.sidebarSelection = .favorites
        XCTAssertEqual(model.filteredChannels.map(\.stableID), ["second", "first"])
        XCTAssertFalse(model.isChannelVisible(first))
    }

    func testLibraryPreferencesPersistAcrossModelInstances() throws {
        let name = "ChannelDeckTests.Library.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try makeModel(defaults: defaults)
        let sourceID = UUID()
        first.setGroupVisible(false, group: "Sports", sourceID: sourceID)
        first.libraryPreferences.favoriteOrder = ["c", "a"]
        let second = try makeModel(defaults: defaults)
        XCTAssertFalse(second.libraryPreferences.isGroupVisible("Sports", sourceID: sourceID))
        XCTAssertEqual(second.libraryPreferences.favoriteOrder, ["c", "a"])
    }

    private func makeModel(defaults: UserDefaults? = nil) throws -> AppModel {
        let store = defaults ?? UserDefaults(suiteName: "ChannelDeckTests.Empty.\(UUID())")!
        return AppModel(modelContainer: try ChannelDeckSchema.makeContainer(inMemory: true),
                        keychain: PresentationTestKeychain(), preferenceStore: store)
    }

    private func channel(id: String) -> ChannelRecord {
        ChannelRecord(stableID: id, sourceID: UUID(), tvgID: nil, name: id,
                      groupName: "Sports", logoURLString: nil, sortIndex: 0)
    }

    private func recording() -> RecordingRecord {
        RecordingRecord(id: UUID(), channelStableID: "recorded", sourceID: UUID(),
            channelName: "Recorded", groupName: "Sports", logoURLString: nil,
            programmeTitle: nil, programmeDescription: nil, programmeStartDate: nil,
            programmeEndDate: nil, startedAt: .now, endedAt: .now, duration: 60,
            packageName: "missing-test-package", thumbnailFileName: nil)
    }
}

private actor PresentationTestKeychain: KeychainStoring {
    func data(for playlistID: UUID, kind: KeychainSecretKind) -> Data? { nil }
    func setData(_ data: Data, for playlistID: UUID, kind: KeychainSecretKind) {}
    func removeData(for playlistID: UUID, kind: KeychainSecretKind) {}
    func removeAll(for playlistID: UUID) {}
}

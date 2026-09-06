import Foundation
import XCTest
#if os(tvOS)
@testable import ChannelDeckTV
#else
@testable import ChannelDeck
#endif

final class GuideSearchIndexTests: XCTestCase {
    private let firstSource = UUID()
    private let secondSource = UUID()
    private let window = GuideWindow(containing: Date(timeIntervalSince1970: 180_000))

    func testSearchMatchesFoldedChannelGroupAndProgrammeText() throws {
        let index = fixture()
        XCTAssertEqual(try index.matchingIDs(for: request("TELEVISION"), preferences: .init()), ["one"])
        XCTAssertEqual(try index.matchingIDs(for: request("documentaries"), preferences: .init()), ["two"])
        XCTAssertEqual(try index.matchingIDs(for: request("  grand   prix  "), preferences: .init()), ["one"])
        XCTAssertTrue(try index.matchingIDs(for: request("not present"), preferences: .init()).isEmpty)
    }

    func testProgrammeMatchesRespectWindowOverlapAndListingsFilter() throws {
        let index = fixture()
        XCTAssertTrue(try index.matchingIDs(for: request("expired"), preferences: .init()).isEmpty)
        XCTAssertTrue(try index.matchingIDs(for: request("future"), preferences: .init()).isEmpty)
        XCTAssertEqual(try index.matchingIDs(for: request("", listings: true), preferences: .init()), ["one", "two"])
        XCTAssertEqual(try index.matchingIDs(for: request("", listings: false), preferences: .init()), ["one", "two", "empty"])
        XCTAssertEqual(try index.matchingIDs(for: request("no listings", listings: false), preferences: .init()), ["empty"])
    }

    func testPlaylistVisibilityAndFavoriteOrderArePreserved() throws {
        let index = fixture()
        var preferences = LibraryPreferences(favoriteOrder: ["two", "one"])
        preferences.setGroupVisible(false, group: "Sports", sourceID: firstSource)
        XCTAssertEqual(try index.matchingIDs(for: request(""), preferences: preferences), ["two"])
        XCTAssertEqual(try index.matchingIDs(for: request("", scope: .source(secondSource)), preferences: .init()), ["two"])
        XCTAssertEqual(try index.matchingIDs(for: request("", scope: .favorites), preferences: preferences), ["two", "one"])
    }

    func testUpdatedSnapshotsDoNotChangeAnInFlightSnapshot() throws {
        var index = fixture()
        let previous = index
        index.setFavorite(false, channelID: "one")
        index.replaceProgrammes([])
        XCTAssertEqual(try previous.matchingIDs(for: request("", scope: .favorites), preferences: .init()), ["one", "two"])
        XCTAssertTrue(try index.matchingIDs(for: request(""), preferences: .init()).isEmpty)
        XCTAssertEqual(try index.matchingIDs(for: request("", scope: .favorites, listings: false), preferences: .init()), ["two"])
    }

    func testSearchAtLargeLibraryScale() throws {
        let count = 60_000
        var index = GuideSearchIndex()
        index.replaceChannels((0..<count).map {
            GuideSearchChannel(stableID: "channel-\($0)", sourceID: firstSource, name: "Channel \($0)", groupName: "Sports")
        }, favoriteIDs: [])
        index.replaceProgrammes((0..<count).flatMap { channel in
            (0..<6).map { slot in
                GuideSearchProgramme(channelID: "channel-\(channel)",
                    title: channel.isMultiple(of: 600) ? "Grand Prix qualifying" : "Daily programme \(slot)",
                    start: window.start.addingTimeInterval(Double(slot) * 1800),
                    end: window.start.addingTimeInterval(Double(slot + 1) * 1800))
            }
        })
        let query = request("grand prix")
        let start = ContinuousClock.now
        let matches = try index.matchingIDs(for: query, preferences: .init())
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(matches.count, 100)
        print("Guide search: 60,000 channels / 360,000 programmes, matching took \(elapsed)")
        // A generous ceiling catches accidental quadratic scans without fragile frame-time assertions.
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    private func request(_ query: String, scope: GuideScope = .all, listings: Bool = true) -> GuideSearchRequest {
        GuideSearchRequest(query: query, scope: scope, window: window, listingsOnly: listings)
    }

    private func fixture() -> GuideSearchIndex {
        var index = GuideSearchIndex()
        index.replaceChannels([
            GuideSearchChannel(stableID: "one", sourceID: firstSource, name: "Télévision One", groupName: "Sports"),
            GuideSearchChannel(stableID: "two", sourceID: secondSource, name: "Channel Two", groupName: "Documentaries"),
            GuideSearchChannel(stableID: "empty", sourceID: firstSource, name: "No listings", groupName: "Other")
        ], favoriteIDs: ["one", "two"])
        index.replaceProgrammes([
            programme("one", title: "Grand Prix", start: -100, end: 1000),
            programme("one", title: "Expired", start: -1000, end: 0),
            programme("two", title: "Into the wild", start: 1000, end: 4000),
            programme("two", title: "Future", start: 7200, end: 9000)
        ])
        return index
    }

    private func programme(_ channel: String, title: String, start: Double, end: Double) -> GuideSearchProgramme {
        GuideSearchProgramme(channelID: channel, title: title,
            start: window.start.addingTimeInterval(start), end: window.start.addingTimeInterval(end))
    }
}

@MainActor
final class GuideSearchControllerTests: XCTestCase {
    func testAnOlderQueryCannotOverwriteNewerResultsEvenWithoutCancellation() async {
        let controller = GuideSearchController()
        let index = fixture()
        let old = Task { await controller.update(request: request("one"), index: index, preferences: .init()) }
        // update() marks itself searching before its debounce suspension.
        while !controller.isSearching { await Task.yield() }
        await controller.update(request: request(""), index: index, preferences: .init())
        await old.value
        XCTAssertEqual(controller.channelIDs, ["one", "two"])
        XCTAssertFalse(controller.isSearching)
    }

    func testCancelledQueryKeepsPreviousRowsAndClearsProgress() async {
        let controller = GuideSearchController()
        let index = fixture()
        await controller.update(request: request(""), index: index, preferences: .init())
        let pending = Task { await controller.update(request: request("one"), index: index, preferences: .init()) }
        while !controller.isSearching { await Task.yield() }
        pending.cancel()
        await pending.value
        XCTAssertEqual(controller.channelIDs, ["one", "two"])
        XCTAssertFalse(controller.isSearching)
    }

    private func request(_ query: String) -> GuideSearchRequest {
        GuideSearchRequest(query: query, scope: .all, window: GuideWindow(containing: .now), listingsOnly: false)
    }

    private func fixture() -> GuideSearchIndex {
        var index = GuideSearchIndex()
        let sourceID = UUID()
        index.replaceChannels(["one", "two"].map {
            GuideSearchChannel(stableID: $0, sourceID: sourceID, name: $0, groupName: "Sports")
        }, favoriteIDs: [])
        return index
    }
}

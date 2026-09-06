import XCTest
@testable import ChannelDeckTV

final class TVLibraryTests: XCTestCase {
    func testLargeLibraryGroupsKeepEveryChannelReachable() {
        let source = UUID()
        let channels = (0..<3200).map { index in
            TVChannel(id: "channel-\(index)", sourceID: source, name: "Channel \(index)", group: index < 500 ? "Large group" : "Group \(index / 50)",
                      tvgID: nil, logoURL: nil, streamURL: URL(string: "http://example.invalid/live")!, order: index)
        }
        let groups = TVChannelGroup.groups(in: channels)
        let large = groups.first { $0.name == "Large group" }!
        let members = channels.filter(large.contains)
        XCTAssertEqual(members.count, 500)
        let visited = groups.flatMap { group in channels.filter(group.contains).map(\.id) }
        XCTAssertEqual(Set(visited), Set(channels.map(\.id)))
        XCTAssertEqual(visited.count, channels.count, "Grouping must not drop or duplicate channels.")
        let other = TVChannelGroup(sourceID: UUID(), name: large.name)
        XCTAssertNotEqual(other.id, large.id, "Same-named groups from different playlists stay separate.")
        XCTAssertFalse(other.contains(channels[0]))
    }
    func testLibrarySettingsSurviveLossOfDownloadedCachesAndContainNoAddresses() throws {
        var state = TVUserState()
        state.sources = [TVSource(name: "Living room")]
        state.favorites.insert(TVChannel.preferenceID("a long stable channel id"))
        state.recents = Array(state.favorites)
        state.bufferMinutes = 5
        let data = try state.encoded()
        XCTAssertEqual(try JSONDecoder().decode(TVUserState.self, from: data), state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("https://"))
        XCTAssertEqual(state.favorites.first?.count, 44)
    }
    func testPreferencesHaveHeadroomBelowTVOSLimit() {
        var state = TVUserState()
        state.sources = [TVSource(name: String(repeating: "a", count: 410000))]
        XCTAssertThrowsError(try state.encoded())
    }
    func testM3UToGuideSearchSupportsTransportStreamsAndProgrammeTitles() throws {
        let source = UUID()
        let playlist = try M3UParser().parse(data: Data("""
        #EXTM3U url-tvg="https://example.invalid/guide.xml"
        #EXTINF:-1 tvg-id="sport" group-title="Sports",Sport HD
        https://example.invalid/live.ts
        """.utf8))
        XCTAssertEqual(playlist.channels.first?.streamURL.pathExtension, "ts")
        let id = playlist.channels[0].stableKey(sourceID: source).rawValue
        var index = GuideSearchIndex()
        index.replaceChannels([GuideSearchChannel(stableID: id, sourceID: source, name: "Sport HD", groupName: "Sports")], favoriteIDs: [])
        index.replaceProgrammes([GuideSearchProgramme(channelID: id, title: "Grand Prix", start: .now, end: .now.addingTimeInterval(3600))])
        XCTAssertEqual(try index.matchingIDs(for: GuideSearchRequest(query: "grand", scope: .all, window: GuideWindow(containing: .now), listingsOnly: true), preferences: LibraryPreferences()), [id])
    }
    func testSourceValidationAndErrorRedaction() {
        XCTAssertNil(SourceURLPolicy.validatedURL(from: "file:///etc/passwd"))
        XCTAssertNil(SourceURLPolicy.validatedURL(from: "javascript:alert(1)"))
        XCTAssertNotNil(SourceURLPolicy.validatedURL(from: "http://example.invalid/list"))
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://example.invalid/?password=secret"])
        XCTAssertFalse(TVLibrary.safeMessage(error).contains("secret"))
    }
    @MainActor func testPlaybackClockFormatting() {
        XCTAssertEqual(TVPlaybackController.clock(600), "10:00")
        XCTAssertEqual(TVPlaybackController.clock(-5), "0:00")
    }

    func testCustomGuideMapsToEveryQualityVariantUsingStableChannelIDs() {
        let source = UUID()
        let channels = ["TR: News HD", "TR: News SD"].enumerated().map { offset, name in
            ParsedChannel(tvgID: "news.tr", tvgName: nil, name: name, group: "Turkey", logoURL: nil,
                          streamURL: URL(string: "https://example.invalid/live/\(offset)")!, order: offset, duration: -1)
        }
        let programme = ParsedProgramme(channelID: "news.tr", title: "News", subtitle: nil, description: nil, categories: [], start: .now, end: .now.addingTimeInterval(3600))
        let mapped = TVLibrary.stableProgrammes([programme], channels: channels, sourceID: source)
        XCTAssertEqual(Set(mapped.map(\.channelID)), Set(channels.map { $0.stableKey(sourceID: source).rawValue }))
        XCTAssertEqual(mapped.count, 2)
    }

    @MainActor func testNativeKeychainAndLibrarySettingsSurviveCacheEviction() async throws {
        let suite = "ChannelDeckTVTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = URL.temporaryDirectory.appending(path: suite)
        let keychain = KeychainStore(service: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = TVSource(name: "Home", guide: GuidePreferences(mode: .openEPG))
        try await keychain.setPlaylistURL(URL(string: "https://example.invalid/list?password=fixture")!, for: source.id)
        var state = TVUserState()
        state.sources = [source]
        defaults.set(try state.encoded(), forKey: TVUserState.key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: directory)
        let reopened = TVLibrary(defaults: defaults, keychain: keychain, directory: directory)
        XCTAssertEqual(reopened.sources, [source])
        let addresses = try await reopened.sourceAddresses(source)
        XCTAssertTrue(addresses.0.contains("password=fixture"))
        XCTAssertFalse(String(decoding: defaults.data(forKey: TVUserState.key)!, as: UTF8.self).contains("password"))
        try await keychain.removeAll(for: source.id)
    }
}

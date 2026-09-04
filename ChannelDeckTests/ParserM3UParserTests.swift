import XCTest
@testable import ChannelDeck

final class ParserM3UParserTests: XCTestCase {
    func testParsesExtendedMetadataUnicodeAndRelativeURLs() throws {
        let playlist = """
        \u{feff}#EXTM3U playlist-name="Ev & Spor" url-tvg="../epg/guide.xml, https://guide.example/epg.xml"
        #EXTINF:-1 tvg-id="sport.1" tvg-name="Spor, Bir" tvg-logo="logos/sport.png" group-title="Ignored",Spor, Bir HD
        #EXTGRP:Spor
        streams/sport.m3u8
        #EXTGRP:Uluslararası
        #EXTINF:0 tvg-id="world.1" tvg-name="Dünya",Dünya TV
        https://media.example/world.ts
        """.replacingOccurrences(of: "\n", with: "\r\n")

        let parsed = try M3UParser().parse(
            data: Data(playlist.utf8),
            baseURL: URL(string: "https://provider.example/path/list.m3u")!
        )

        XCTAssertEqual(parsed.title, "Ev & Spor")
        XCTAssertEqual(
            parsed.epgURLs,
            [
                URL(string: "https://provider.example/epg/guide.xml")!,
                URL(string: "https://guide.example/epg.xml")!
            ]
        )
        XCTAssertEqual(parsed.channels.count, 2)

        let sport = parsed.channels[0]
        XCTAssertEqual(sport.tvgID, "sport.1")
        XCTAssertEqual(sport.tvgName, "Spor, Bir")
        XCTAssertEqual(sport.name, "Spor, Bir HD")
        XCTAssertEqual(sport.group, "Spor")
        XCTAssertEqual(sport.logoURL, URL(string: "https://provider.example/path/logos/sport.png"))
        XCTAssertEqual(sport.streamURL, URL(string: "https://provider.example/path/streams/sport.m3u8"))
        XCTAssertEqual(sport.duration, -1)
        XCTAssertEqual(sport.order, 0)

        let world = parsed.channels[1]
        XCTAssertEqual(world.group, "Uluslararası")
        XCTAssertEqual(world.order, 1)
        XCTAssertEqual(world.duration, 0)
    }

    func testSkipsMalformedPairsAndPreservesValidEntryOrder() throws {
        let playlist = """
        #EXTM3U
        https://media.example/orphan.ts
        #EXTINF:-1 tvg-id="missing",Missing URI
        #EXTINF:-1 tvg-id="one",One
        relative/one.m3u8
        #EXTINF:-1 tvg-id="bad",Bad URL

        #EXTINF:-1 tvg-id="two",Two
        https://media.example/two.ts
        """

        let parsed = try M3UParser().parse(
            data: Data(playlist.utf8),
            baseURL: URL(string: "https://provider.example/list.m3u")!
        )

        XCTAssertEqual(parsed.channels.map(\.tvgID), ["one", "two"])
        XCTAssertEqual(parsed.channels.map(\.order), [0, 1])
    }

    func testStableKeyNormalizesMetadataButIncludesSource() throws {
        let source = UUID(uuidString: "1197BEB7-DFB1-4A7C-8D64-3E38584C4474")!
        let first = ChannelStableKey(
            sourceID: source,
            tvgID: "  ÇHANNEL.ONE ",
            name: " Wörld  TV ",
            group: " News "
        )
        let normalized = ChannelStableKey(
            sourceID: source,
            tvgID: "channel.one",
            name: "wörld  tv",
            group: "news"
        )
        let otherSource = ChannelStableKey(
            sourceID: UUID(uuidString: "FF2CC0C1-C1B2-489E-B4E3-F9110462AA47")!,
            tvgID: "channel.one",
            name: "world  tv",
            group: "news"
        )

        XCTAssertEqual(first, normalized)
        XCTAssertNotEqual(first, otherSource)
        XCTAssertFalse(first.rawValue.contains("https://"))
    }

    func testReportsTypedErrorsWithoutIncludingInput() {
        XCTAssertThrowsError(try M3UParser().parse(data: Data([0xff, 0xfe]))) { error in
            XCTAssertEqual(error as? ParserError, .invalidTextEncoding)
        }

        XCTAssertThrowsError(
            try M3UParser().parse(data: Data("https://example.test/channel".utf8))
        ) { error in
            XCTAssertEqual(error as? ParserError, .missingM3UHeader)
        }

        XCTAssertThrowsError(
            try M3UParser().parse(data: Data("#EXTM3U\n#EXTINF:-1,Missing URL".utf8))
        ) { error in
            XCTAssertEqual(error as? ParserError, .noPlayableChannels)
            XCTAssertFalse(error.localizedDescription.contains("Missing URL"))
        }
    }
}

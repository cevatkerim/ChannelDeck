import XCTest
@testable import ChannelDeck

final class ParserXMLTVParserTests: XCTestCase {
    func testParsesExactChannelMatchesMetadataAndTimezoneDates() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="news.one"><display-name>News One</display-name></channel>
          <programme channel="news.one" start="20260904090000 +0200" stop="20260904100000 +0200">
            <title lang="de"><![CDATA[Morgen & News]]></title>
            <sub-title>Frühausgabe</sub-title>
            <desc>Die wichtigsten Nachrichten.</desc>
            <category>News</category>
            <category>Live</category>
          </programme>
          <programme channel="News.One" start="20260904090000 +0200" stop="20260904100000 +0200">
            <title>Wrong case</title>
          </programme>
          <programme channel="news.two" start="20260904090000 +0200" stop="20260904100000 +0200">
            <title>Other channel</title>
          </programme>
        </tv>
        """
        let lower = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T06:30:00Z"))
        let upper = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T08:30:00Z"))

        let programmes = try XMLTVParser().parse(
            data: Data(xml.utf8),
            channelIDs: ["news.one"],
            timeWindow: lower..<upper
        )

        XCTAssertEqual(programmes.count, 1)
        let programme = try XCTUnwrap(programmes.first)
        XCTAssertEqual(programme.channelID, "news.one")
        XCTAssertEqual(programme.title, "Morgen & News")
        XCTAssertEqual(programme.subtitle, "Frühausgabe")
        XCTAssertEqual(programme.description, "Die wichtigsten Nachrichten.")
        XCTAssertEqual(programme.categories, ["News", "Live"])
        XCTAssertEqual(
            programme.start,
            ISO8601DateFormatter().date(from: "2026-09-04T07:00:00Z")
        )
        XCTAssertEqual(
            programme.end,
            ISO8601DateFormatter().date(from: "2026-09-04T08:00:00Z")
        )
    }

    func testFiltersUsingHalfOpenOverlapSemantics() throws {
        let xml = """
        <tv>
          <programme channel="one" start="20260904050000 +0000" stop="20260904060000 +0000"><title>Ends at start</title></programme>
          <programme channel="one" start="20260904053000 +0000" stop="20260904063000 +0000"><title>Overlaps start</title></programme>
          <programme channel="one" start="20260904070000 +0000" stop="20260904073000 +0000"><title>Starts at end</title></programme>
          <programme channel="one" start="20260904063000 +0000" stop="20260904070000 +0000"><title>Inside</title></programme>
          <programme channel="one" start="invalid" stop="20260904070000 +0000"><title>Invalid date</title></programme>
        </tv>
        """
        let lower = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T06:00:00Z"))
        let upper = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T07:00:00Z"))

        let programmes = try XMLTVParser().parse(
            data: Data(xml.utf8),
            channelIDs: ["one"],
            timeWindow: lower..<upper
        )

        XCTAssertEqual(programmes.map(\.title), ["Overlaps start", "Inside"])
    }

    func testEmptyChannelFilterReturnsNoProgrammes() throws {
        let xml = """
        <tv>
          <programme channel="one" start="20260904060000 +0000" stop="20260904070000 +0000"><title>One</title></programme>
        </tv>
        """
        let lower = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-04T00:00:00Z"))
        let upper = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-05T00:00:00Z"))

        let programmes = try XMLTVParser().parse(
            data: Data(xml.utf8),
            channelIDs: [],
            timeWindow: lower..<upper
        )

        XCTAssertTrue(programmes.isEmpty)
    }

    func testMalformedXMLReportsTypedError() {
        let lower = Date(timeIntervalSince1970: 0)
        let upper = Date(timeIntervalSince1970: 100)

        XCTAssertThrowsError(
            try XMLTVParser().parse(
                data: Data("<tv><programme>".utf8),
                channelIDs: ["one"],
                timeWindow: lower..<upper
            )
        ) { error in
            XCTAssertEqual(error as? ParserError, .malformedXML)
        }
    }
}

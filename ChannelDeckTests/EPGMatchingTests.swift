import Foundation
import XCTest
#if os(tvOS)
@testable import ChannelDeckTV
#else
@testable import ChannelDeck
#endif

final class EPGMatchingTests: XCTestCase {
    let sourceID = UUID()
    func channel(_ name: String, id: String? = nil, group: String = "TURK SPOR", path: String = "/live/1.ts", duration: Int? = -1) -> ParsedChannel {
        ParsedChannel(tvgID: id, tvgName: nil, name: name, group: group, logoURL: nil,
                      streamURL: URL(string: "https://example.invalid" + path)!, order: 0, duration: duration)
    }
    func guide(_ name: String, country: String = "turkey") -> GuideChannel {
        GuideChannel(feed: OpenEPGFeed(cou: country, url: URL(string: "https://www.open-epg.com/files/\(country).xml")!, img: country), channelID: name, name: name)
    }
    func testNormalizesQualityAndCountryWithoutLosingChannelNumbers() {
        let guides = [guide("beIN SPORTS 1.tr"), guide("beIN SPORTS 2.tr"), guide("beIN SPORTS HABER.tr")]
        let result = EPGMatcher.match(channel("TR: beIN SPORTS 1 HD", id: "beinsports1.tr"), sourceID: sourceID, candidates: guides, overrides: [:])
        XCTAssertEqual(result.match?.channelID, "beIN SPORTS 1.tr")
        let haber = EPGMatcher.match(channel("TR: beIN SPORTS HABER HD", id: "beIN SPORTS HABER"), sourceID: sourceID, candidates: guides, overrides: [:])
        XCTAssertEqual(haber.match?.channelID, "beIN SPORTS HABER.tr")
        let missing = EPGMatcher.match(channel("TR: beIN SPORTS 3 HD"), sourceID: sourceID, candidates: guides, overrides: [:])
        XCTAssertNil(missing.match)
        XCTAssertTrue(missing.suggestions.isEmpty)
    }
    func testGenericProviderIDDoesNotOverrideNumberedName() {
        let result = EPGMatcher.match(channel("TR: beIN SPORTS 2 HD", id: "beIN SPORTS"), sourceID: sourceID,
                                      candidates: [guide("beIN SPORTS 1.tr"), guide("beIN SPORTS 2.tr")], overrides: [:])
        XCTAssertEqual(result.match?.channelID, "beIN SPORTS 2.tr")
    }
    func testCountryIsolationAndUnknownCountry() {
        let result = EPGMatcher.match(channel("TR: Eurosport 1 HD"), sourceID: sourceID,
                                      candidates: [guide("Eurosport 1.de", country: "germany")], overrides: [:])
        XCTAssertNil(result.match)
        XCTAssertNil(EPGMatcher.country(for: channel("International News", group: "International")))
        XCTAssertEqual(EPGMatcher.country(for: channel("Sky Sports [UK]", group: "Sports")), "gb")
        XCTAssertEqual(EPGMatcher.country(for: channel("Channel", group: "ALBANIEN")), "al")
    }
    func testFuzzySuggestionsRequireConfirmation() {
        let result = EPGMatcher.match(channel("TR: Eurosporr 1 HD"), sourceID: sourceID,
                                      candidates: [guide("Eurosport 1.tr")], overrides: [:])
        XCTAssertNil(result.match)
        XCTAssertEqual(result.suggestions.count, 1)
    }
    func testManualOverrideAndDisableSurviveEncoding() throws {
        let channel = channel("TR: Sport Channel")
        let candidate = guide("S SPORT.tr")
        let key = channel.stableKey(sourceID: sourceID).rawValue
        let preferences = GuidePreferences(mode: .automatic, overrides: [key: candidate.id])
        let saved = try JSONDecoder().decode(GuidePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(EPGMatcher.match(channel, sourceID: sourceID, candidates: [candidate], overrides: saved.overrides).match, candidate)
        XCTAssertNil(EPGMatcher.match(channel, sourceID: sourceID, candidates: [candidate], overrides: [key: ""]).match)
    }
    func testExcludesVODBeforeMatchingEvenWithTVGID() {
        for group in ["TR/FILM ~ YERLI", "US MOVIES", "DE SERIEN", "TR DIZI", "VOD", "Фильмы", "ES PELICULAS"] {
            XCTAssertFalse(EPGMatcher.isLive(channel("TR: ATV HD", id: "ATV.tr", group: group)), group)
        }
        XCTAssertFalse(EPGMatcher.isLive(channel("Movie", group: "Other", path: "/movie/account/123.ts")))
        XCTAssertFalse(EPGMatcher.isLive(channel("Episode", group: "Other", path: "/series/account/123.ts")))
        XCTAssertFalse(EPGMatcher.isLive(channel("Movie", group: "Other", path: "/123.mkv")))
        XCTAssertFalse(EPGMatcher.isLive(channel("Programme S02E12", group: "Other")))
        XCTAssertFalse(EPGMatcher.isLive(channel("Movie", group: "Other", duration: 7200)))
        XCTAssertTrue(EPGMatcher.isLive(channel("TR: TRT SPOR HD")))
    }
    func testFeedURLsAreRestrictedToPublicProviderFiles() {
        for url in ["http://www.open-epg.com/files/test.xml", "https://evil.invalid/files/test.xml", "https://www.open-epg.com/files/test.xml?token=secret"] {
            XCTAssertFalse(OpenEPGFeed(cou: "Turkey", url: URL(string: url)!, img: "turkey").isAllowed)
        }
        XCTAssertTrue(guide("Test.tr").feed.isAllowed)
    }
}

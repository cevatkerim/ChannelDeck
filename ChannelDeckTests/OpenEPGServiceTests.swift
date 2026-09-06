import Foundation
import XCTest
#if os(tvOS)
@testable import ChannelDeckTV
#else
@testable import ChannelDeck
#endif

final class OpenEPGServiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenEPGTests-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        EPGURLProtocol.handler = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func channel(group: String = "TURK SPOR") -> ParsedChannel {
        ParsedChannel(tvgID: "beinsports1.tr", tvgName: nil, name: "TR: beIN SPORTS 1 HD", group: group,
            logoURL: nil, streamURL: URL(string: "http://example.invalid/live/private/1.ts")!, order: 0, duration: -1)
    }
    private func client(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> HTTPClient {
        EPGURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EPGURLProtocol.self]
        return HTTPClient(session: URLSession(configuration: config))
    }
    func testCountryDiscoveryMatchingAndSharedDiskCache() async throws {
        let now = Date()
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMddHHmmss Z"
        let start = format.string(from: now.addingTimeInterval(-60))
        let stop = format.string(from: now.addingTimeInterval(3600))
        let xml = Data("""
        <tv><channel id="beIN SPORTS 1.tr"><display-name>beIN SPORTS 1.tr</display-name></channel>
        <programme channel="beIN SPORTS 1.tr" start="\(start)" stop="\(stop)"><title>Live match</title></programme></tv>
        """.utf8)
        let client = client { request in
            XCTAssertEqual(request.url?.host, "www.open-epg.com")
            XCTAssertNil(request.url?.query)
            switch request.url?.lastPathComponent {
            case "epgfetch.php": return (200, Data(#"[{"cou":"Turkey 1","img":"turkey","url":"https://www.open-epg.com/files/turkey1.xml"},{"cou":"Germany","img":"germany","url":"https://www.open-epg.com/files/germany.xml"}]"#.utf8))
            case "turkey1.xml": return (200, xml)
            default: XCTFail("Should download only the detected country"); return (404, Data())
            }
        }
        let sourceID = UUID()
        let service = OpenEPGService(client: client, cacheDirectory: directory)
        let result = try await service.refresh(channels: [channel()], sourceID: sourceID, preferences: GuidePreferences(mode: .automatic))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.programmes.count, 1)
        XCTAssertEqual(result.programmes.first?.channelID, channel().stableKey(sourceID: sourceID).rawValue)
        EPGURLProtocol.handler = { _ in XCTFail("Second instance must use shared disk cache"); throw URLError(.notConnectedToInternet) }
        let reopened = OpenEPGService(client: client, cacheDirectory: directory)
        let cached = try await reopened.refresh(channels: [channel()], sourceID: UUID(), preferences: GuidePreferences(mode: .openEPG))
        XCTAssertEqual(cached.programmes.first?.title, "Live match")
    }
    func testVODOnlyPlaylistDoesNotContactOpenEPG() async throws {
        let service = OpenEPGService(client: client { _ in XCTFail("VOD must not trigger downloads"); return (500, Data()) }, cacheDirectory: directory)
        let result = try await service.refresh(channels: [channel(group: "TR/FILM")], sourceID: UUID(), preferences: GuidePreferences(mode: .openEPG))
        XCTAssertTrue(result.rows.isEmpty)
    }
    func testFeedFailureIsReportedAndNotRetriedOnRestart() async throws {
        let client = client { request in
            if request.url?.lastPathComponent == "epgfetch.php" {
                return (200, Data(#"[{"cou":"Turkey","img":"turkey","url":"https://www.open-epg.com/files/turkey.xml"}]"#.utf8))
            }
            return (503, Data())
        }
        let result = try await OpenEPGService(client: client, cacheDirectory: directory)
            .refresh(channels: [channel()], sourceID: UUID(), preferences: GuidePreferences(mode: .openEPG))
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.programmes.isEmpty)
        EPGURLProtocol.handler = { _ in XCTFail("Failed feed must respect the daily attempt limit"); return (503, Data()) }
        let second = try await OpenEPGService(client: client, cacheDirectory: directory)
            .refresh(channels: [channel()], sourceID: UUID(), preferences: GuidePreferences(mode: .openEPG))
        XCTAssertFalse(second.warnings.isEmpty)
    }
}

private final class EPGURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

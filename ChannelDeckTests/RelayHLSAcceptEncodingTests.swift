import XCTest
@testable import ChannelDeck

final class RelayHLSAcceptEncodingTests: XCTestCase {
    func testAcceptsExplicitGzipAndWildcardWithPositiveQuality() {
        for value in [
            "gzip",
            "br, GZip",
            "gzip ; q=0.5",
            "gzip;q=1.000",
            "br, *",
            "*;q=0.001",
            "*;q=0, gzip;q=0.4"
        ] {
            XCTAssertTrue(HLSRelayAcceptEncoding.acceptsGzip(value), value)
        }
    }

    func testRejectsAbsentExcludedAndMalformedGzipQualities() {
        let values: [String?] = [
            nil,
            "",
            "br, deflate",
            "gzip;q=0",
            "*;q=0",
            "gzip;q=0, *;q=1",
            "gzip;q=invalid",
            "gzip;q=1.001",
            "gzip;q=.5",
            "gzip;q=-1",
            "gzip;q=0.5;q=1",
            "x-gzip"
        ]
        for value in values {
            XCTAssertFalse(HLSRelayAcceptEncoding.acceptsGzip(value), value ?? "nil")
        }
    }

    func testExplicitGzipExclusionWinsRegardlessOfOrderingOrWildcard() {
        XCTAssertFalse(HLSRelayAcceptEncoding.acceptsGzip("gzip, gzip;q=0"))
        XCTAssertFalse(HLSRelayAcceptEncoding.acceptsGzip("gzip;q=0, gzip"))
        XCTAssertFalse(HLSRelayAcceptEncoding.acceptsGzip("*;q=1, gzip;q=0"))
    }
}

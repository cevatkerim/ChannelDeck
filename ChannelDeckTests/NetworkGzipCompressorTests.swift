import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkGzipCompressorTests: XCTestCase {
    func testProducesGzipThatRoundTripsThroughSystemZlib() throws {
        let input = Data(String(repeating: "#EXTINF:4,\nsegment.ts\n", count: 1_000).utf8)

        let compressed = try GzipCompressor.compress(input)

        XCTAssertEqual(Array(compressed.prefix(2)), [0x1f, 0x8b])
        XCTAssertLessThan(compressed.count, input.count)
        XCTAssertEqual(
            try GzipDecompressor.decompress(
                compressed,
                maximumExpandedBytes: input.count
            ),
            input
        )
    }

    func testRoundTripsEmptyInputAsAValidGzipMember() throws {
        let compressed = try GzipCompressor.compress(Data())

        XCTAssertEqual(Array(compressed.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(
            try GzipDecompressor.decompress(compressed, maximumExpandedBytes: 0),
            Data()
        )
    }
}

import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkGzipDecompressorTests: XCTestCase {
    func testDecompressesValidGzipDocument() throws {
        let compressed = try XCTUnwrap(
            Data(base64Encoded: "H4sIAC4Qm2oAA8tIzcnJV0jOSMzLS81JSU3OBgDJ1ra7EQAAAA==")
        )

        let result = try GzipDecompressor.decompress(compressed, maximumExpandedBytes: 1_024)

        XCTAssertEqual(String(data: result, encoding: .utf8), "hello channeldeck")
    }

    func testStopsExpansionAtConfiguredLimit() throws {
        let compressed = try XCTUnwrap(
            Data(base64Encoded: "H4sIAC4Qm2oAA0tMpAwAAFVltIlAAAAA")
        )

        XCTAssertThrowsError(
            try GzipDecompressor.decompress(compressed, maximumExpandedBytes: 32)
        ) { error in
            XCTAssertEqual(error as? GzipDecompressionError, .expandedDataTooLarge)
        }
    }

    func testRejectsMalformedAndTruncatedGzipBytes() throws {
        XCTAssertThrowsError(
            try GzipDecompressor.decompress(Data("not gzip".utf8), maximumExpandedBytes: 1_024)
        )

        let valid = try XCTUnwrap(
            Data(base64Encoded: "H4sIAC4Qm2oAA8tIzcnJV0jOSMzLS81JSU3OBgDJ1ra7EQAAAA==")
        )
        XCTAssertThrowsError(
            try GzipDecompressor.decompress(valid.dropLast(5), maximumExpandedBytes: 1_024)
        )
    }
}

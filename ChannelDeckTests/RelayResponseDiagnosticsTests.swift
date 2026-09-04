import Foundation
import XCTest
@testable import ChannelDeck

final class RelayResponseDiagnosticsTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)

    func testClassifiesTranscodedMasterMediaAndSegmentWithoutRetainingPath() throws {
        let cases: [(String, HLSRelayDiagnosticRouteKind, HLSRelayUpstreamMethod, Int)] = [
            ("index.m3u8", .master, .get, 147),
            ("media-0.m3u8", .media, .head, 0),
            ("segment-0-000000042.ts", .segment, .get, 2_500_000),
        ]

        for (fileName, expectedKind, method, byteCount) in cases {
            let request = request(
                method: method,
                path: "/s/\(token)/transcoded/\(fileName)"
            )
            let diagnostic = try XCTUnwrap(
                HLSRelayResponseDiagnostic.make(
                    request: request,
                    statusCode: method == .head ? 206 : 200,
                    responseBodyBytes: byteCount
                )
            )

            XCTAssertEqual(diagnostic.routeKind, expectedKind)
            XCTAssertEqual(diagnostic.method, method)
            XCTAssertEqual(diagnostic.statusCode, method == .head ? 206 : 200)
            XCTAssertEqual(diagnostic.responseBodyBytes, byteCount)
            XCTAssertFalse(String(reflecting: diagnostic).contains(token))
            XCTAssertFalse(String(reflecting: diagnostic).contains(fileName))
        }
    }

    func testClassifiesRootAndResourceProxyRoutesOnlyAsUpstream() throws {
        let secretResourceID = "credentialBearingResource"
        let paths = [
            "/s/\(token)/index.m3u8",
            "/s/\(token)/r/\(secretResourceID).ts",
        ]

        for path in paths {
            let diagnostic = try XCTUnwrap(
                HLSRelayResponseDiagnostic.make(
                    request: request(method: .get, path: path),
                    statusCode: 502,
                    responseBodyBytes: 0
                )
            )
            XCTAssertEqual(diagnostic.routeKind, .upstream)
            XCTAssertFalse(String(reflecting: diagnostic).contains(token))
            XCTAssertFalse(String(reflecting: diagnostic).contains(secretResourceID))
        }
    }

    func testRejectsTargetsThatCouldCarryUnclassifiedSensitiveData() {
        let targets = [
            "/s/short/transcoded/index.m3u8",
            "/s/\(token)/transcoded/index.m3u8?credential=secret",
            "/s/\(token)/transcoded/%69ndex.m3u8",
            "/s/\(token)/transcoded/segment-0-42.ts",
            "/s/\(token)/transcoded/segment-0-000000042.ts/extra",
            "https://provider.example/s/\(token)/transcoded/index.m3u8",
            "/unknown/\(token)/private-value",
        ]

        for target in targets {
            XCTAssertNil(
                HLSRelayResponseDiagnostic.make(
                    request: request(method: .get, path: target),
                    statusCode: 400,
                    responseBodyBytes: 0
                ),
                "Unexpectedly classified a malformed request target"
            )
        }
    }

    func testMetadataHasOnlyClosedClassificationAndScalarResponseFields() throws {
        let diagnostic = try XCTUnwrap(
            HLSRelayResponseDiagnostic.make(
                request: request(
                    method: .get,
                    path: "/s/\(token)/transcoded/media-0.m3u8"
                ),
                statusCode: 200,
                responseBodyBytes: -1
            )
        )

        XCTAssertEqual(diagnostic.responseBodyBytes, 0)
        XCTAssertEqual(
            Set(Mirror(reflecting: diagnostic).children.compactMap(\.label)),
            ["routeKind", "method", "statusCode", "responseBodyBytes"]
        )
    }

    private func request(method: HLSRelayUpstreamMethod, path: String) -> HLSRelayRequest {
        HLSRelayRequest(
            method: method,
            path: path,
            range: nil,
            ifNoneMatch: nil,
            ifModifiedSince: nil
        )
    }
}

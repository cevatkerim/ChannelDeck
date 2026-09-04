import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkAsyncHTTPClientHLSRelayUpstreamFetcherTests: XCTestCase {
    func testFollowsHTTPSRedirectToNumericHTTPAndPreservesAllowedHeaders() async throws {
        let transport = MockHLSRelayHTTPTransport(responses: [
            HLSRelayHTTPTransportResponse(
                statusCode: 302,
                location: "http://192.0.2.44:8080/live/index.m3u8"
            ),
            HLSRelayHTTPTransportResponse(
                statusCode: 206,
                body: Data("segment".utf8),
                contentType: "application/vnd.apple.mpegurl",
                contentLength: 7,
                contentRange: "bytes 0-6/7",
                acceptRanges: "bytes",
                etag: "\"edge-v1\"",
                lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
                cacheControl: "max-age=5"
            ),
        ])
        let fetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: transport,
            addressResolver: MockPublicAddressResolver()
        )

        let response = try await fetcher.fetch(
            HLSRelayUpstreamRequest(
                url: try XCTUnwrap(URL(string: "https://provider.example/live/channel.m3u8#ignored")),
                range: "bytes=0-6",
                ifNoneMatch: "\"client-v1\"",
                ifModifiedSince: "Wed, 21 Oct 2015 07:28:00 GMT"
            )
        )

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.body, Data("segment".utf8))
        XCTAssertEqual(response.finalURL.absoluteString, "http://192.0.2.44:8080/live/index.m3u8")
        XCTAssertEqual(response.contentLength, 7)
        XCTAssertEqual(response.contentRange, "bytes 0-6/7")
        XCTAssertEqual(response.etag, "\"edge-v1\"")

        let requests = await transport.receivedRequests()
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://provider.example/live/channel.m3u8",
            "http://192.0.2.44:8080/live/index.m3u8",
        ])
        XCTAssertEqual(requests[1].headers, [
            "Range": "bytes=0-6",
            "If-None-Match": "\"client-v1\"",
            "If-Modified-Since": "Wed, 21 Oct 2015 07:28:00 GMT",
        ])
        XCTAssertNil(requests[1].headers["Authorization"])
        XCTAssertNil(requests[1].headers["Cookie"])
    }

    func testResolvesRelativeRedirectAndPreservesHEADSemantics() async throws {
        let transport = MockHLSRelayHTTPTransport(responses: [
            HLSRelayHTTPTransportResponse(statusCode: 307, location: "../edge/master.m3u8?token=secret"),
            HLSRelayHTTPTransportResponse(
                statusCode: 200,
                body: Data("ignored".utf8),
                contentType: "application/vnd.apple.mpegurl",
                contentLength: 12
            ),
        ])
        let fetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: transport,
            addressResolver: MockPublicAddressResolver()
        )
        let response = try await fetcher.fetch(
            HLSRelayUpstreamRequest(
                url: try XCTUnwrap(URL(string: "https://provider.example/a/b/master.m3u8")),
                method: .head
            )
        )

        XCTAssertEqual(response.finalURL.absoluteString, "https://provider.example/a/edge/master.m3u8?token=secret")
        XCTAssertEqual(response.contentLength, 12)
        XCTAssertTrue(response.body.isEmpty)
        let requests = await transport.receivedRequests()
        XCTAssertEqual(requests.map(\.method), [.head, .head])
    }

    func testRejectsRedirectCycleAndRedirectLimit() async throws {
        let cycleTransport = MockHLSRelayHTTPTransport(responses: [
            HLSRelayHTTPTransportResponse(statusCode: 302, location: "/two"),
            HLSRelayHTTPTransportResponse(statusCode: 301, location: "/one"),
        ])
        let cycleFetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: cycleTransport,
            addressResolver: MockPublicAddressResolver()
        )

        await XCTAssertThrowsRelayError(.upstreamFailure) {
            _ = try await cycleFetcher.fetch(
                HLSRelayUpstreamRequest(url: try XCTUnwrap(URL(string: "https://example.com/one")))
            )
        }

        let limitTransport = MockHLSRelayHTTPTransport(responses: [
            HLSRelayHTTPTransportResponse(statusCode: 302, location: "/two"),
        ])
        let limitFetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: limitTransport,
            addressResolver: MockPublicAddressResolver(),
            maximumRedirects: 0
        )
        await XCTAssertThrowsRelayError(.upstreamFailure) {
            _ = try await limitFetcher.fetch(
                HLSRelayUpstreamRequest(url: try XCTUnwrap(URL(string: "https://example.com/one")))
            )
        }
    }

    func testRejectsURLCredentialsWithoutContactingTransport() async throws {
        let transport = MockHLSRelayHTTPTransport(responses: [])
        let fetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: transport,
            addressResolver: MockPublicAddressResolver()
        )

        await XCTAssertThrowsRelayError(.upstreamFailure) {
            _ = try await fetcher.fetch(
                HLSRelayUpstreamRequest(
                    url: try XCTUnwrap(URL(string: "https://user:password@example.com/live.m3u8"))
                )
            )
        }
        let requests = await transport.receivedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testMapsOversizeResponseAndRedactsTransportFailure() async throws {
        let oversizedTransport = MockHLSRelayHTTPTransport(responses: [
            HLSRelayHTTPTransportResponse(statusCode: 200, body: Data(repeating: 1, count: 5)),
        ])
        let oversizedFetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: oversizedTransport,
            addressResolver: MockPublicAddressResolver(),
            maximumBodyBytes: 4
        )
        await XCTAssertThrowsRelayError(.responseTooLarge) {
            _ = try await oversizedFetcher.fetch(
                HLSRelayUpstreamRequest(url: try XCTUnwrap(URL(string: "https://example.com/credential-path")))
            )
        }

        let failingTransport = MockHLSRelayHTTPTransport(responses: [], failure: .secretURL)
        let failingFetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(
            transport: failingTransport,
            addressResolver: MockPublicAddressResolver()
        )
        do {
            _ = try await failingFetcher.fetch(
                HLSRelayUpstreamRequest(url: try XCTUnwrap(URL(string: "https://example.com/token-in-path")))
            )
            XCTFail("Expected a redacted error")
        } catch let error as HLSRelayError {
            XCTAssertEqual(error, .upstreamFailure)
            XCTAssertFalse(error.localizedDescription.contains("token-in-path"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testRejectsPrivateUpstreamAddressBeforeTransport() async throws {
        let transport = MockHLSRelayHTTPTransport(responses: [
            HLSRelayHTTPTransportResponse(statusCode: 200, body: Data("should-not-load".utf8)),
        ])
        let fetcher = AsyncHTTPClientHLSRelayUpstreamFetcher(transport: transport)

        await XCTAssertThrowsRelayError(.upstreamFailure) {
            _ = try await fetcher.fetch(
                HLSRelayUpstreamRequest(
                    url: try XCTUnwrap(URL(string: "http://169.254.169.254/latest/meta-data"))
                )
            )
        }
        let receivedRequests = await transport.receivedRequests()
        XCTAssertTrue(receivedRequests.isEmpty)
    }

    private func XCTAssertThrowsRelayError(
        _ expected: HLSRelayError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as HLSRelayError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }
}

private struct MockPublicAddressResolver: HLSRelayUpstreamAddressResolving {
    func allowedConnectionAddress(for url: URL) -> String { "93.184.216.34" }
}

private actor MockHLSRelayHTTPTransport: HLSRelayHTTPTransporting {
    enum Failure: Error, Sendable {
        case secretURL
        case noScriptedResponse
    }

    private var responses: [HLSRelayHTTPTransportResponse]
    private let failure: Failure?
    private var requests: [HLSRelayHTTPTransportRequest] = []

    init(responses: [HLSRelayHTTPTransportResponse], failure: Failure? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func execute(
        _ request: HLSRelayHTTPTransportRequest,
        timeout: TimeInterval,
        maximumBodyBytes: Int
    ) async throws -> HLSRelayHTTPTransportResponse {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else { throw Failure.noScriptedResponse }
        return responses.removeFirst()
    }

    func receivedRequests() -> [HLSRelayHTTPTransportRequest] {
        requests
    }
}

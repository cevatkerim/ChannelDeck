import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkHLSRelayUpstreamFetcherTests: XCTestCase {
    override func tearDown() {
        RelayUpstreamURLProtocol.handler = nil
        super.tearDown()
    }

    func testForwardsOnlyMediaHeadersAndPreservesFinalNumericHTTPURL() async throws {
        let finalURL = URL(string: "http://192.0.2.20/live/variant.m3u8")!
        let session = makeSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "etag-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), "yesterday")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let response = HTTPURLResponse(
                url: finalURL,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/vnd.apple.mpegurl",
                    "Content-Length": "8",
                    "Content-Range": "bytes 10-17/100",
                    "Accept-Ranges": "bytes",
                    "ETag": "etag-2",
                    "Last-Modified": "today",
                    "Cache-Control": "max-age=30",
                ]
            )!
            return (response, Data("#EXTM3U".utf8))
        }
        defer { session.invalidateAndCancel() }
        let fetcher = URLSessionHLSRelayUpstreamFetcher(session: session)

        let response = try await fetcher.fetch(
            HLSRelayUpstreamRequest(
                url: URL(string: "https://provider.example/start")!,
                range: "bytes=10-20",
                ifNoneMatch: "etag-1",
                ifModifiedSince: "yesterday"
            )
        )

        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(response.finalURL, finalURL)
        XCTAssertEqual(response.body, Data("#EXTM3U".utf8))
        XCTAssertEqual(response.contentLength, 8)
        XCTAssertEqual(response.contentRange, "bytes 10-17/100")
        XCTAssertEqual(response.acceptRanges, "bytes")
        XCTAssertEqual(response.etag, "etag-2")
        XCTAssertEqual(response.lastModified, "today")
        XCTAssertEqual(response.cacheControl, "max-age=30")
    }

    func testHEADReturnsNoBodyAndRetainsLargeContentLength() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "999999"]
            )!
            return (response, Data("ignored".utf8))
        }
        defer { session.invalidateAndCancel() }
        let fetcher = URLSessionHLSRelayUpstreamFetcher(
            session: session,
            maximumBodyBytes: 4
        )

        let response = try await fetcher.fetch(
            HLSRelayUpstreamRequest(
                url: URL(string: "http://192.0.2.20/segment.ts")!,
                method: .head
            )
        )

        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(response.contentLength, 999_999)
    }

    func testRejectsOversizedGETResponse() async throws {
        let session = makeSession { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data(repeating: 0, count: 5))
        }
        defer { session.invalidateAndCancel() }
        let fetcher = URLSessionHLSRelayUpstreamFetcher(
            session: session,
            maximumBodyBytes: 4
        )

        do {
            _ = try await fetcher.fetch(
                HLSRelayUpstreamRequest(url: URL(string: "https://provider.example/segment.ts")!)
            )
            XCTFail("Expected response size rejection")
        } catch {
            XCTAssertEqual(error as? HLSRelayError, .responseTooLarge)
        }
    }

    func testDropsInjectedHeadersAndRedactsTransportErrors() async throws {
        let secretURL = URL(string: "https://user:secret@provider.example/live.m3u8")!
        let session = makeSession { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotConnectToHost,
                userInfo: [NSLocalizedDescriptionKey: secretURL.absoluteString]
            )
        }
        defer { session.invalidateAndCancel() }
        let fetcher = URLSessionHLSRelayUpstreamFetcher(session: session)

        do {
            _ = try await fetcher.fetch(
                HLSRelayUpstreamRequest(
                    url: secretURL,
                    range: "bytes=0-1\r\nAuthorization: leaked",
                    ifNoneMatch: "tag\r\nCookie: leaked"
                )
            )
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(error as? HLSRelayError, .upstreamFailure)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertFalse(error.localizedDescription.contains("provider.example"))
        }
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        RelayUpstreamURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.protocolClasses = [RelayUpstreamURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RelayUpstreamURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

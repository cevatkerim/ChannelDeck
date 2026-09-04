import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkHTTPClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSendsConditionalValidatorsAndReturnsRefreshedMetadata() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "old-tag")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), "yesterday")
            return try Self.response(
                request: request,
                status: 200,
                headers: [
                    "ETag": "new-tag",
                    "Last-Modified": "today",
                    "Content-Type": "application/x-mpegURL",
                ],
                data: Data("#EXTM3U".utf8)
            )
        }
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/private/list.m3u"))

        let result = try await client.fetch(
            url,
            validators: HTTPValidators(etag: "old-tag", lastModified: "yesterday"),
            policy: .playlist
        )

        guard case let .modified(payload) = result else {
            XCTFail("Expected a modified payload")
            return
        }
        XCTAssertEqual(payload.data, Data("#EXTM3U".utf8))
        XCTAssertEqual(payload.validators, HTTPValidators(etag: "new-tag", lastModified: "today"))
        XCTAssertEqual(payload.contentType, "application/x-mpegURL")
    }

    func testNotModifiedRetainsValidatorsOmittedByServer() async throws {
        let session = makeSession { request in
            try Self.response(request: request, status: 304)
        }
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let validators = HTTPValidators(etag: "existing", lastModified: "earlier")
        let url = try XCTUnwrap(URL(string: "https://example.invalid/guide.xml.gz"))

        let result = try await client.fetch(url, validators: validators, policy: .epg)

        XCTAssertEqual(result, .notModified(validators))
    }

    func testRejectsNonHTTPSSourceBeforeTransport() async throws {
        let session = makeSession { request in
            XCTFail("Transport should not receive a request")
            return try Self.response(request: request, status: 200)
        }
        defer { session.invalidateAndCancel() }
        let client = HTTPClient(session: session)
        let url = try XCTUnwrap(URL(string: "http://example.invalid/private/list.m3u"))

        do {
            _ = try await client.fetch(url, policy: .playlist)
            XCTFail("Expected insecure transport to be rejected")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .insecureTransport)
        }
    }

    func testValidatesStatusAndRedactsCredentialBearingURL() async throws {
        let statusSession = makeSession { request in
            try Self.response(request: request, status: 401)
        }
        defer { statusSession.invalidateAndCancel() }
        let secretURL = try XCTUnwrap(
            URL(string: "https://subscriber:very-secret@example.invalid/list.m3u")
        )

        do {
            _ = try await HTTPClient(session: statusSession).fetch(secretURL, policy: .playlist)
            XCTFail("Expected the request to fail")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .unacceptableStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("very-secret"))
            XCTAssertFalse(error.localizedDescription.contains(secretURL.absoluteString))
        }
    }

    func testValidatesFinalResponseSize() async throws {
        let session = makeSession { request in
            try Self.response(
                request: request,
                status: 200,
                data: Data([0, 1, 2, 3])
            )
        }
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/list.m3u"))

        do {
            _ = try await HTTPClient(session: session).fetch(
                url,
                policy: HTTPResourcePolicy(maximumResponseBytes: 3)
            )
            XCTFail("Expected the response to exceed the limit")
        } catch {
            XCTAssertEqual(error as? HTTPClientError, .responseTooLarge)
        }
    }

    func testMapsCancelledURLLoadingToTaskCancellation() async throws {
        let session = makeSession { _ in
            throw URLError(.cancelled)
        }
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/list.m3u"))

        do {
            _ = try await HTTPClient(session: session).fetch(url, policy: .playlist)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        request: URLRequest,
        status: Int,
        headers: [String: String] = [:],
        data: Data = Data()
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        )
        return (response, data)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
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

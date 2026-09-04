import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkDNSPropagationCheckerTests: XCTestCase {
    override func tearDown() {
        DNSPropagationURLProtocol.handler = nil
        super.tearDown()
    }

    func testFindsExactTXTValueWithoutSendingValueToResolver() async throws {
        let proof = "private-challenge-proof"
        let session = makeSession { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "resolver.example.invalid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/dns-json")
            XCTAssertFalse(request.url?.absoluteString.contains(proof) == true)
            XCTAssertNil(request.httpBody)
            return try Self.response(
                request,
                body: """
                {"Status":0,"Answer":[
                  {"type":16,"data":"\\\"unrelated\\\""},
                  {"type":16,"data":"\\\"private-challenge-\\\" \\\"proof\\\""}
                ]}
                """
            )
        }
        defer { session.invalidateAndCancel() }
        let checker = DoHTXTPropagationChecker(
            session: session,
            resolverURL: URL(string: "https://resolver.example.invalid/dns-query")!
        )

        let status = try await checker.checkTXTRecord(
            name: "_acme-challenge.relay.example.com",
            value: proof
        )

        XCTAssertEqual(status, .visible)
    }

    func testNXDOMAINIsPendingRatherThanAnError() async throws {
        let session = makeSession { request in
            try Self.response(request, body: "{\"Status\":3}")
        }
        defer { session.invalidateAndCancel() }
        let checker = makeChecker(session: session)

        let status = try await checker.checkTXTRecord(
            name: "_acme-challenge.relay.example.com",
            value: "expected"
        )

        XCTAssertEqual(status, .pending)
    }

    func testSERVFAILNoAnswerAndWrongAnswerArePending() async throws {
        for body in [
            "{\"Status\":2}",
            "{\"Status\":0}",
            "{\"Status\":0,\"Answer\":[{\"type\":16,\"data\":\"\\\"wrong\\\"\"}]}",
        ] {
            let session = makeSession { request in
                try Self.response(request, body: body)
            }
            let checker = makeChecker(session: session)

            let status = try await checker.checkTXTRecord(
                name: "_acme-challenge.relay.example.com",
                value: "expected"
            )

            XCTAssertEqual(status, .pending)
            session.invalidateAndCancel()
        }
    }

    func testOversizedAndMalformedResponsesRemainPending() async throws {
        for body in [String(repeating: "x", count: 65), "not-json"] {
            let session = makeSession { request in
                try Self.response(request, body: body)
            }
            let checker = DoHTXTPropagationChecker(
                session: session,
                resolverURL: URL(string: "https://resolver.example.invalid/dns-query")!,
                maximumResponseBytes: 64
            )

            let status = try await checker.checkTXTRecord(
                name: "_acme-challenge.relay.example.com",
                value: "expected"
            )

            XCTAssertEqual(status, .pending)
            session.invalidateAndCancel()
        }
    }

    private func makeChecker(session: URLSession) -> DoHTXTPropagationChecker {
        DoHTXTPropagationChecker(
            session: session,
            resolverURL: URL(string: "https://resolver.example.invalid/dns-query")!
        )
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        DNSPropagationURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DNSPropagationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let data = Data(body.utf8)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/dns-json",
                    "Content-Length": String(data.count),
                ]
            )
        )
        return (response, data)
    }
}

private final class DNSPropagationURLProtocol: URLProtocol, @unchecked Sendable {
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

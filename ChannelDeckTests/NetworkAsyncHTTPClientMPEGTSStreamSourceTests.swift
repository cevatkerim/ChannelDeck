import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkAsyncHTTPClientMPEGTSStreamSourceTests: XCTestCase {
    func testStreamsEveryChunkToConsumerUsingPinnedAddress() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "http://provider.example/live/channel.ts?credential=hidden"))
        let chunks = [Data([0x47, 1, 2]), Data([0x47, 3]), Data([0x47, 4, 5, 6])]
        let transport = MPEGTSStreamingTransportStub(plans: [
            sourceURL: [.init(head: .init(statusCode: 200, contentType: "video/mp2t"), chunks: chunks)]
        ])
        let resolver = MPEGTSAddressResolverStub(addresses: [
            "provider.example": "203.0.113.40"
        ])
        let source = AsyncHTTPClientMPEGTSStreamSource(
            transport: transport,
            addressResolver: resolver
        )
        let consumer = MPEGTSRecordingConsumer()

        try await source.stream(from: sourceURL, into: consumer)

        let consumedChunks = await consumer.values()
        XCTAssertEqual(consumedChunks, chunks)
        let requests = await transport.requests()
        XCTAssertEqual(
            requests,
            [MPEGTSHTTPStreamRequest(url: sourceURL, connectionAddress: "203.0.113.40")]
        )
    }

    func testFollowsRedirectOnlyAfterResolvingAndPinningNewHost() async throws {
        let initialURL = try XCTUnwrap(URL(string: "https://origin.example/live/channel.ts"))
        let redirectedURL = try XCTUnwrap(URL(string: "http://edge.example:8080/raw/feed"))
        let transport = MPEGTSStreamingTransportStub(plans: [
            initialURL: [
                .init(
                    head: .init(statusCode: 302, location: redirectedURL.absoluteString),
                    chunks: [Data("redirect-body-must-not-be-consumed".utf8)]
                )
            ],
            redirectedURL: [
                .init(head: .init(statusCode: 200), chunks: [Data([0x47, 9, 8, 7])])
            ]
        ])
        let resolver = MPEGTSAddressResolverStub(addresses: [
            "origin.example": "203.0.113.41",
            "edge.example": "203.0.113.42"
        ])
        let source = AsyncHTTPClientMPEGTSStreamSource(
            transport: transport,
            addressResolver: resolver
        )
        let consumer = MPEGTSRecordingConsumer()

        try await source.stream(from: initialURL, into: consumer)

        let consumedChunks = await consumer.values()
        let resolvedURLs = await resolver.resolvedURLs()
        XCTAssertEqual(consumedChunks, [Data([0x47, 9, 8, 7])])
        XCTAssertEqual(resolvedURLs, [initialURL, redirectedURL])
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.connectionAddress), ["203.0.113.41", "203.0.113.42"])
    }

    func testRejectsRedirectWhenNewHostFailsAddressPolicyBeforeTransport() async throws {
        let initialURL = try XCTUnwrap(URL(string: "https://origin.example/channel.ts"))
        let privateURL = try XCTUnwrap(URL(string: "http://private.example/channel.ts"))
        let transport = MPEGTSStreamingTransportStub(plans: [
            initialURL: [
                .init(head: .init(statusCode: 307, location: privateURL.absoluteString))
            ]
        ])
        let resolver = MPEGTSAddressResolverStub(
            addresses: ["origin.example": "203.0.113.43"],
            rejectedHosts: ["private.example"]
        )
        let source = AsyncHTTPClientMPEGTSStreamSource(
            transport: transport,
            addressResolver: resolver
        )

        await XCTAssertThrowsMPEGTSRelayError(.upstreamFailure) {
            try await source.stream(from: initialURL, into: MPEGTSRecordingConsumer())
        }
        let requestCount = await transport.requestCount()
        let resolvedURLs = await resolver.resolvedURLs()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(resolvedURLs, [initialURL, privateURL])
    }

    func testRejectsRedirectCycleAndRedirectLimit() async throws {
        let first = try XCTUnwrap(URL(string: "https://one.example/channel.ts"))
        let second = try XCTUnwrap(URL(string: "https://two.example/channel.ts"))
        let resolver = MPEGTSAddressResolverStub(addresses: [
            "one.example": "203.0.113.44",
            "two.example": "203.0.113.45"
        ])

        let cycleTransport = MPEGTSStreamingTransportStub(plans: [
            first: [.init(head: .init(statusCode: 302, location: second.absoluteString))],
            second: [.init(head: .init(statusCode: 302, location: first.absoluteString))]
        ])
        let cycleSource = AsyncHTTPClientMPEGTSStreamSource(
            transport: cycleTransport,
            addressResolver: resolver
        )
        await XCTAssertThrowsMPEGTSRelayError(.upstreamFailure) {
            try await cycleSource.stream(from: first, into: MPEGTSRecordingConsumer())
        }

        let limitedTransport = MPEGTSStreamingTransportStub(plans: [
            first: [.init(head: .init(statusCode: 302, location: second.absoluteString))]
        ])
        let limitedSource = AsyncHTTPClientMPEGTSStreamSource(
            transport: limitedTransport,
            addressResolver: resolver,
            maximumRedirects: 0
        )
        await XCTAssertThrowsMPEGTSRelayError(.upstreamFailure) {
            try await limitedSource.stream(from: first, into: MPEGTSRecordingConsumer())
        }
        let limitedRequestCount = await limitedTransport.requestCount()
        XCTAssertEqual(limitedRequestCount, 1)
    }

    func testRejectsInvalidURLsAndRedactsTransportFailures() async throws {
        let transport = MPEGTSStreamingTransportStub(plans: [:])
        let resolver = MPEGTSAddressResolverStub(addresses: [:])
        let source = AsyncHTTPClientMPEGTSStreamSource(
            transport: transport,
            addressResolver: resolver
        )

        await XCTAssertThrowsMPEGTSRelayError(.upstreamFailure) {
            try await source.stream(
                from: try XCTUnwrap(URL(string: "https://user:secret@provider.example/channel.ts")),
                into: MPEGTSRecordingConsumer()
            )
        }
        let invalidURLRequestCount = await transport.requestCount()
        XCTAssertEqual(invalidURLRequestCount, 0)

        let secretURL = try XCTUnwrap(URL(string: "https://provider.example/private-token/channel.ts"))
        let failingTransport = MPEGTSStreamingTransportStub(
            plans: [:],
            failure: MPEGTSSecretTransportError(url: secretURL.absoluteString)
        )
        let failingSource = AsyncHTTPClientMPEGTSStreamSource(
            transport: failingTransport,
            addressResolver: MPEGTSAddressResolverStub(
                addresses: ["provider.example": "203.0.113.46"]
            )
        )
        do {
            try await failingSource.stream(from: secretURL, into: MPEGTSRecordingConsumer())
            XCTFail("Expected a redacted failure")
        } catch let error as HLSRelayError {
            XCTAssertEqual(error, .upstreamFailure)
            XCTAssertFalse((error.errorDescription ?? "").contains("private-token"))
            XCTAssertFalse(String(describing: error).contains("private-token"))
        }
    }

    func testRejectsNonSuccessWithoutSendingErrorBodyToConsumer() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "http://provider.example/channel.ts"))
        let transport = MPEGTSStreamingTransportStub(plans: [
            sourceURL: [
                .init(
                    head: .init(statusCode: 403),
                    chunks: [Data("provider diagnostic".utf8)]
                )
            ]
        ])
        let source = AsyncHTTPClientMPEGTSStreamSource(
            transport: transport,
            addressResolver: MPEGTSAddressResolverStub(
                addresses: ["provider.example": "203.0.113.47"]
            )
        )
        let consumer = MPEGTSRecordingConsumer()

        await XCTAssertThrowsMPEGTSRelayError(.upstreamRejected(403)) {
            try await source.stream(from: sourceURL, into: consumer)
        }
        let consumedChunks = await consumer.values()
        XCTAssertTrue(consumedChunks.isEmpty)
    }

    func testCancellationPropagatesWhileTransportIsStreaming() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "http://provider.example/channel.ts"))
        let transport = MPEGTSBlockingStreamingTransport()
        let source = AsyncHTTPClientMPEGTSStreamSource(
            transport: transport,
            addressResolver: MPEGTSAddressResolverStub(
                addresses: ["provider.example": "203.0.113.48"]
            )
        )
        let task = Task {
            try await source.stream(from: sourceURL, into: MPEGTSRecordingConsumer())
        }

        await transport.waitUntilStarted()
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not collapsed to a generic relay error.
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}

private struct MPEGTSSecretTransportError: Error, CustomStringConvertible, Sendable {
    let url: String
    var description: String { "transport failed for \(url)" }
}

private struct MPEGTSStreamingPlan: Sendable {
    let head: MPEGTSHTTPStreamResponseHead
    let chunks: [Data]

    init(head: MPEGTSHTTPStreamResponseHead, chunks: [Data] = []) {
        self.head = head
        self.chunks = chunks
    }
}

private actor MPEGTSStreamingTransportStub: MPEGTSHTTPStreamingTransporting {
    private var plans: [URL: [MPEGTSStreamingPlan]]
    private let failure: (any Error & Sendable)?
    private var capturedRequests: [MPEGTSHTTPStreamRequest] = []

    init(
        plans: [URL: [MPEGTSStreamingPlan]],
        failure: (any Error & Sendable)? = nil
    ) {
        self.plans = plans
        self.failure = failure
    }

    func execute(
        _ request: MPEGTSHTTPStreamRequest,
        consumer: any MPEGTSByteConsuming
    ) async throws -> MPEGTSHTTPStreamResponseHead {
        capturedRequests.append(request)
        if let failure { throw failure }
        guard var queued = plans[request.url], !queued.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let plan = queued.removeFirst()
        plans[request.url] = queued
        if (200 ... 299).contains(plan.head.statusCode) {
            for chunk in plan.chunks {
                try await consumer.consume(chunk)
            }
        }
        return plan.head
    }

    func requests() -> [MPEGTSHTTPStreamRequest] { capturedRequests }
    func requestCount() -> Int { capturedRequests.count }
}

private actor MPEGTSAddressResolverStub: HLSRelayUpstreamAddressResolving {
    private let addresses: [String: String]
    private let rejectedHosts: Set<String>
    private var capturedURLs: [URL] = []

    init(addresses: [String: String], rejectedHosts: Set<String> = []) {
        self.addresses = addresses
        self.rejectedHosts = rejectedHosts
    }

    func allowedConnectionAddress(for url: URL) throws -> String {
        capturedURLs.append(url)
        guard let host = url.host,
              !rejectedHosts.contains(host),
              let address = addresses[host] else {
            throw HLSRelayError.upstreamFailure
        }
        return address
    }

    func resolvedURLs() -> [URL] { capturedURLs }
}

private actor MPEGTSRecordingConsumer: MPEGTSByteConsuming {
    private var chunks: [Data] = []

    func consume(_ bytes: Data) {
        chunks.append(bytes)
    }

    func values() -> [Data] { chunks }
}

private actor MPEGTSBlockingStreamingTransport: MPEGTSHTTPStreamingTransporting {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func execute(
        _ request: MPEGTSHTTPStreamRequest,
        consumer: any MPEGTSByteConsuming
    ) async throws -> MPEGTSHTTPStreamResponseHead {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await Task.sleep(for: .seconds(60))
        return .init(statusCode: 200)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }
}

private func XCTAssertThrowsMPEGTSRelayError(
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
        XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
    }
}

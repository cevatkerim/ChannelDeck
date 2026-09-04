import AsyncHTTPClient
import Foundation

/// Pulls a continuous MPEG-TS response from a provider and writes each bounded
/// chunk into a caller-owned consumer. Awaiting every consume call provides
/// backpressure all the way to AsyncHTTPClient's response-body sequence.
protocol MPEGTSUpstreamStreaming: Sendable {
    func stream(
        from sourceURL: URL,
        into consumer: any MPEGTSByteConsuming
    ) async throws
}

struct MPEGTSHTTPStreamRequest: Equatable, Sendable {
    let url: URL
    /// A policy-approved numeric address. The transport connects to this
    /// address while retaining the URL host for the Host header and TLS SNI.
    let connectionAddress: String
}

struct MPEGTSHTTPStreamResponseHead: Equatable, Sendable {
    let statusCode: Int
    let location: String?
    let contentType: String?

    init(statusCode: Int, location: String? = nil, contentType: String? = nil) {
        self.statusCode = statusCode
        self.location = location
        self.contentType = contentType
    }
}

/// The transport sends body bytes to the consumer only for 2xx responses.
/// Redirect and error bodies are drained with a small fixed limit so they can
/// never become an unbounded buffer or leak into FFmpeg's input.
protocol MPEGTSHTTPStreamingTransporting: Sendable {
    func execute(
        _ request: MPEGTSHTTPStreamRequest,
        consumer: any MPEGTSByteConsuming
    ) async throws -> MPEGTSHTTPStreamResponseHead
}

private enum MPEGTSHTTPStreamingTransportError: Error {
    case invalidResponse
    case responseTooLarge
}

/// Process-lifetime AsyncHTTPClient transport for continuous provider streams.
/// It uses connect and idle-read timeouts instead of an overall request
/// deadline, which would incorrectly terminate an intentionally endless feed.
actor AsyncHTTPClientMPEGTSStreamingTransport: MPEGTSHTTPStreamingTransporting {
    static let shared = AsyncHTTPClientMPEGTSStreamingTransport(client: SharedClient.client)

    private enum SharedClient {
        static let client = AsyncHTTPClient.HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: AsyncHTTPClientMPEGTSStreamingTransport.configuration()
        )
    }

    private static let maximumPinnedClients = 32
    private static let maximumDiscardedBodyBytes = 64 * 1_024
    private static let maximumChunkBytes = 64 * 1_024

    private let client: AsyncHTTPClient.HTTPClient
    private var pinnedClients: [String: AsyncHTTPClient.HTTPClient] = [:]

    init(client: AsyncHTTPClient.HTTPClient) {
        self.client = client
    }

    func execute(
        _ request: MPEGTSHTTPStreamRequest,
        consumer: any MPEGTSByteConsuming
    ) async throws -> MPEGTSHTTPStreamResponseHead {
        guard let host = request.url.host, !host.isEmpty else {
            throw MPEGTSHTTPStreamingTransportError.invalidResponse
        }
        let requestClient = try pinnedClient(
            host: host,
            connectionAddress: request.connectionAddress
        )
        var outbound = HTTPClientRequest(url: request.url.absoluteString)
        outbound.method = .GET

        // A finite request deadline is unsuitable for live MPEG-TS. The client
        // configuration still applies a bounded connect timeout and terminates
        // a stalled feed after 30 seconds without response bytes.
        let response = try await requestClient.execute(outbound, deadline: .distantFuture)
        let statusCode = Int(response.status.code)
        guard (100 ... 599).contains(statusCode) else {
            throw MPEGTSHTTPStreamingTransportError.invalidResponse
        }

        let head = MPEGTSHTTPStreamResponseHead(
            statusCode: statusCode,
            location: Self.safeHeader(
                response.headers.first(name: "Location"),
                maximumBytes: 4_096
            ),
            contentType: Self.safeHeader(response.headers.first(name: "Content-Type"))
        )

        if (200 ... 299).contains(statusCode) {
            for try await var part in response.body {
                try Task.checkCancellation()
                while part.readableBytes > 0 {
                    let length = min(part.readableBytes, Self.maximumChunkBytes)
                    guard let slice = part.readSlice(length: length) else {
                        throw MPEGTSHTTPStreamingTransportError.invalidResponse
                    }
                    try await consumer.consume(Data(slice.readableBytesView))
                }
            }
        } else {
            var discardedBytes = 0
            for try await part in response.body {
                try Task.checkCancellation()
                guard part.readableBytes <= Self.maximumDiscardedBodyBytes - discardedBytes else {
                    throw MPEGTSHTTPStreamingTransportError.responseTooLarge
                }
                discardedBytes += part.readableBytes
            }
        }
        return head
    }

    private func pinnedClient(
        host: String,
        connectionAddress: String
    ) throws -> AsyncHTTPClient.HTTPClient {
        if host == connectionAddress { return client }

        let key = "\(host)|\(connectionAddress)"
        if let existing = pinnedClients[key] { return existing }
        guard pinnedClients.count < Self.maximumPinnedClients else {
            throw MPEGTSHTTPStreamingTransportError.invalidResponse
        }

        var configuration = Self.configuration()
        configuration.dnsOverride = [host: connectionAddress]
        let created = AsyncHTTPClient.HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configuration
        )
        pinnedClients[key] = created
        return created
    }

    private static func configuration() -> AsyncHTTPClient.HTTPClient.Configuration {
        AsyncHTTPClient.HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(15), read: .seconds(30)),
            decompression: .disabled
        )
    }

    private static func safeHeader(_ value: String?, maximumBytes: Int = 1_024) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumBytes,
              !trimmed.contains("\r"),
              !trimmed.contains("\n") else {
            return nil
        }
        return trimmed
    }
}

/// Policy layer shared with the buffered HLS proxy: every initial URL and
/// redirect hop is validated, resolved, checked for special-use addresses, and
/// pinned to the approved numeric result before any provider bytes are read.
struct AsyncHTTPClientMPEGTSStreamSource: MPEGTSUpstreamStreaming {
    private let transport: any MPEGTSHTTPStreamingTransporting
    private let addressResolver: any HLSRelayUpstreamAddressResolving
    private let maximumRedirects: Int

    init(
        transport: any MPEGTSHTTPStreamingTransporting = AsyncHTTPClientMPEGTSStreamingTransport.shared,
        addressResolver: any HLSRelayUpstreamAddressResolving = SystemHLSRelayUpstreamAddressResolver(),
        maximumRedirects: Int = 5
    ) {
        precondition((0 ... 10).contains(maximumRedirects))
        self.transport = transport
        self.addressResolver = addressResolver
        self.maximumRedirects = maximumRedirects
    }

    func stream(
        from sourceURL: URL,
        into consumer: any MPEGTSByteConsuming
    ) async throws {
        do {
            var currentURL = try validatedURL(sourceURL)
            var visited = Set([canonicalRedirectKey(currentURL)])
            var followedRedirects = 0

            while true {
                try Task.checkCancellation()
                let connectionAddress = try await addressResolver.allowedConnectionAddress(for: currentURL)
                let response = try await transport.execute(
                    MPEGTSHTTPStreamRequest(
                        url: currentURL,
                        connectionAddress: connectionAddress
                    ),
                    consumer: consumer
                )
                try Task.checkCancellation()

                if Self.isRedirect(response.statusCode) {
                    guard followedRedirects < maximumRedirects,
                          let location = response.location else {
                        throw HLSRelayError.upstreamFailure
                    }
                    let nextURL = try redirectURL(location, relativeTo: currentURL)
                    guard visited.insert(canonicalRedirectKey(nextURL)).inserted else {
                        throw HLSRelayError.upstreamFailure
                    }
                    followedRedirects += 1
                    currentURL = nextURL
                    continue
                }

                guard (200 ... 299).contains(response.statusCode) else {
                    throw HLSRelayError.upstreamRejected(response.statusCode)
                }
                return
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSRelayError {
            throw error
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            // AsyncHTTPClient diagnostics can contain the full provider URL.
            // Collapse them to a fixed error before crossing this boundary.
            throw HLSRelayError.upstreamFailure
        }
    }

    private func redirectURL(_ location: String, relativeTo baseURL: URL) throws -> URL {
        guard let safeLocation = safeHeader(location, maximumBytes: 4_096),
              let resolved = URL(string: safeLocation, relativeTo: baseURL)?.absoluteURL else {
            throw HLSRelayError.upstreamFailure
        }
        return try validatedURL(resolved)
    }

    private func validatedURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HLSRelayError.upstreamFailure
        }
        components.fragment = nil
        guard let normalized = components.url, normalized.host == host else {
            throw HLSRelayError.upstreamFailure
        }
        return normalized
    }

    private func canonicalRedirectKey(_ url: URL) -> String {
        url.absoluteString
    }

    private func safeHeader(_ value: String?, maximumBytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumBytes,
              !trimmed.contains("\r"),
              !trimmed.contains("\n") else {
            return nil
        }
        return trimmed
    }

    private static func isRedirect(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }
}

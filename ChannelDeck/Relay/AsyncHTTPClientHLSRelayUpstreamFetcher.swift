import AsyncHTTPClient
import Darwin
import Foundation

/// A narrow transport seam that keeps redirect and header policy testable
/// without allowing URLSession/ATS policy to affect provider media requests.
protocol HLSRelayHTTPTransporting: Sendable {
    func execute(
        _ request: HLSRelayHTTPTransportRequest,
        timeout: TimeInterval,
        maximumBodyBytes: Int
    ) async throws -> HLSRelayHTTPTransportResponse
}

struct HLSRelayHTTPTransportRequest: Equatable, Sendable {
    let url: URL
    let method: HLSRelayUpstreamMethod
    let headers: [String: String]
    /// A policy-approved numeric address. The transport pins the connection to
    /// this address while retaining the original host for Host and TLS SNI.
    let connectionAddress: String
}

struct HLSRelayHTTPTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
    let location: String?
    let contentType: String?
    let contentLength: Int64?
    let contentRange: String?
    let acceptRanges: String?
    let etag: String?
    let lastModified: String?
    let cacheControl: String?

    init(
        statusCode: Int,
        body: Data = Data(),
        location: String? = nil,
        contentType: String? = nil,
        contentLength: Int64? = nil,
        contentRange: String? = nil,
        acceptRanges: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        cacheControl: String? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.location = location
        self.contentType = contentType
        self.contentLength = contentLength
        self.contentRange = contentRange
        self.acceptRanges = acceptRanges
        self.etag = etag
        self.lastModified = lastModified
        self.cacheControl = cacheControl
    }
}

private enum HLSRelayHTTPTransportError: Error {
    case responseTooLarge
    case invalidResponse
}

/// AsyncHTTPClient uses SwiftNIO rather than the URL loading system, so an
/// HTTPS provider may safely redirect a media request to an HTTP numeric-IP
/// edge without requiring an app-wide ATS exception.
actor AsyncHTTPClientHLSRelayTransport: HLSRelayHTTPTransporting {
    static let shared = AsyncHTTPClientHLSRelayTransport(client: SharedClient.client)

    private enum SharedClient {
        /// Process-lifetime client: redirects are deliberately disabled here
        /// because the policy-enforcing fetcher below follows them manually.
        static let client: AsyncHTTPClient.HTTPClient = {
            let configuration = AsyncHTTPClient.HTTPClient.Configuration(
                redirectConfiguration: .disallow,
                decompression: .disabled
            )
            return AsyncHTTPClient.HTTPClient(
                eventLoopGroupProvider: .singleton,
                configuration: configuration
            )
        }()
    }

    private let client: AsyncHTTPClient.HTTPClient
    private var pinnedClients: [String: AsyncHTTPClient.HTTPClient] = [:]

    init(client: AsyncHTTPClient.HTTPClient) {
        self.client = client
    }

    func execute(
        _ request: HLSRelayHTTPTransportRequest,
        timeout: TimeInterval,
        maximumBodyBytes: Int
    ) async throws -> HLSRelayHTTPTransportResponse {
        guard let host = request.url.host, !host.isEmpty else {
            throw HLSRelayHTTPTransportError.invalidResponse
        }
        let requestClient: AsyncHTTPClient.HTTPClient
        if host == request.connectionAddress {
            requestClient = client
        } else {
            let key = "\(host)|\(request.connectionAddress)"
            if let existing = pinnedClients[key] {
                requestClient = existing
            } else {
                guard pinnedClients.count < 32 else {
                    throw HLSRelayHTTPTransportError.invalidResponse
                }
                var configuration = AsyncHTTPClient.HTTPClient.Configuration(
                    redirectConfiguration: .disallow,
                    decompression: .disabled
                )
                configuration.dnsOverride = [host: request.connectionAddress]
                let created = AsyncHTTPClient.HTTPClient(
                    eventLoopGroupProvider: .singleton,
                    configuration: configuration
                )
                pinnedClients[key] = created
                requestClient = created
            }
        }

        var outbound = HTTPClientRequest(url: request.url.absoluteString)
        outbound.method = request.method == .head ? .HEAD : .GET
        for (name, value) in request.headers {
            outbound.headers.add(name: name, value: value)
        }

        let timeoutMilliseconds = Int64((timeout * 1_000).rounded(.up))
        let response = try await requestClient.execute(
            outbound,
            timeout: .milliseconds(timeoutMilliseconds)
        )
        let statusCode = Int(response.status.code)
        guard (100 ... 599).contains(statusCode) else {
            throw HLSRelayHTTPTransportError.invalidResponse
        }

        let contentLength = Self.contentLength(response.headers.first(name: "Content-Length"))
        if request.method == .get,
           !Self.isRedirect(statusCode),
           let contentLength,
           contentLength > Int64(maximumBodyBytes) {
            throw HLSRelayHTTPTransportError.responseTooLarge
        }

        // Redirect bodies are irrelevant. Draining a small bounded amount lets
        // the connection be reused while preventing a malicious 3xx response
        // from consuming unbounded memory or bandwidth.
        let bodyLimit = Self.isRedirect(statusCode)
            ? min(maximumBodyBytes, 64 * 1_024)
            : maximumBodyBytes
        var body = Data()
        if request.method == .get {
            for try await part in response.body {
                guard part.readableBytes <= bodyLimit - body.count else {
                    throw HLSRelayHTTPTransportError.responseTooLarge
                }
                body.append(contentsOf: part.readableBytesView)
            }
        }

        return HLSRelayHTTPTransportResponse(
            statusCode: statusCode,
            body: Self.isRedirect(statusCode) ? Data() : body,
            location: Self.safeHeader(response.headers.first(name: "Location"), maximumBytes: 4_096),
            contentType: Self.safeHeader(response.headers.first(name: "Content-Type")),
            contentLength: contentLength,
            contentRange: Self.safeHeader(response.headers.first(name: "Content-Range")),
            acceptRanges: Self.safeHeader(response.headers.first(name: "Accept-Ranges")),
            etag: Self.safeHeader(response.headers.first(name: "ETag")),
            lastModified: Self.safeHeader(response.headers.first(name: "Last-Modified")),
            cacheControl: Self.safeHeader(response.headers.first(name: "Cache-Control"))
        )
    }

    private static func isRedirect(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    private static func contentLength(_ value: String?) -> Int64? {
        guard let value,
              let length = Int64(value.trimmingCharacters(in: .whitespaces)),
              length >= 0 else { return nil }
        return length
    }

    private static func safeHeader(_ value: String?, maximumBytes: Int = 1_024) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumBytes,
              !trimmed.contains("\r"),
              !trimmed.contains("\n") else { return nil }
        return trimmed
    }
}

protocol HLSRelayUpstreamAddressResolving: Sendable {
    func allowedConnectionAddress(for url: URL) async throws -> String
}

/// Resolves once, rejects every special-use result, and returns one numeric
/// address for the transport to pin. Rejecting a mixed public/private answer
/// also prevents a hostname from smuggling an alternate LAN destination.
struct SystemHLSRelayUpstreamAddressResolver: HLSRelayUpstreamAddressResolving {
    func allowedConnectionAddress(for url: URL) async throws -> String {
        guard let host = url.host, !host.isEmpty else {
            throw HLSRelayError.upstreamFailure
        }
        return try await Task.detached(priority: .userInitiated) {
            let addresses = try Self.resolve(host: host)
            guard !addresses.isEmpty,
                  addresses.allSatisfy(Self.isPublicIPAddress),
                  let selected = addresses.first else {
                throw HLSRelayError.upstreamFailure
            }
            return selected
        }.value
    }

    private static func resolve(host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw HLSRelayError.upstreamFailure
        }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            defer { current = info.pointee.ai_next }
            guard let address = info.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let value = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            if !addresses.contains(value) { addresses.append(value) }
        }
        return addresses
    }

    private static func isPublicIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            return isPublicIPv4(UInt32(bigEndian: ipv4.s_addr))
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { rawBuffer in
                let bytes = Array(rawBuffer)
                guard bytes.count == 16 else { return false }
                if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                    let mapped = UInt32(bytes[12]) << 24
                        | UInt32(bytes[13]) << 16
                        | UInt32(bytes[14]) << 8
                        | UInt32(bytes[15])
                    return isPublicIPv4(mapped)
                }
                if bytes.allSatisfy({ $0 == 0 })
                    || (bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1) {
                    return false
                }
                if bytes[0] & 0xfe == 0xfc { return false } // fc00::/7 unique local
                if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false } // fe80::/10 link-local
                if bytes[0] == 0xff { return false } // multicast
                if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return false }
                return true
            }
        }
        return false
    }

    private static func isPublicIPv4(_ address: UInt32) -> Bool {
        let first = UInt8((address >> 24) & 0xff)
        let second = UInt8((address >> 16) & 0xff)
        let third = UInt8((address >> 8) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64 ... 127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16 ... 31).contains(second) { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 0 && third == 0 { return false }
        if first == 192 && second == 0 && third == 2 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && third == 100 { return false }
        if first == 203 && second == 0 && third == 113 { return false }
        return true
    }
}

/// Policy-enforcing HLS upstream fetcher. It forwards only range/cache
/// validators and follows a small, cycle-free set of HTTP redirects manually.
actor AsyncHTTPClientHLSRelayUpstreamFetcher: HLSRelayUpstreamFetching {
    private let transport: any HLSRelayHTTPTransporting
    private let addressResolver: any HLSRelayUpstreamAddressResolving
    private let timeout: TimeInterval
    private let maximumBodyBytes: Int
    private let maximumRedirects: Int

    init(
        transport: any HLSRelayHTTPTransporting = AsyncHTTPClientHLSRelayTransport.shared,
        addressResolver: any HLSRelayUpstreamAddressResolving = SystemHLSRelayUpstreamAddressResolver(),
        timeout: TimeInterval = 30,
        maximumBodyBytes: Int = 128 * 1_024 * 1_024,
        maximumRedirects: Int = 5
    ) {
        precondition(timeout.isFinite && timeout > 0)
        precondition(maximumBodyBytes > 0)
        precondition((0 ... 10).contains(maximumRedirects))
        self.transport = transport
        self.addressResolver = addressResolver
        self.timeout = timeout
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumRedirects = maximumRedirects
    }

    func fetch(_ request: HLSRelayUpstreamRequest) async throws -> HLSRelayUpstreamResponse {
        do {
            var currentURL = try validatedURL(request.url)
            var visited = Set([canonicalRedirectKey(currentURL)])
            var followedRedirects = 0

            let headers = forwardedHeaders(for: request)
            while true {
                try Task.checkCancellation()
                let connectionAddress = try await addressResolver.allowedConnectionAddress(for: currentURL)
                let response = try await transport.execute(
                    HLSRelayHTTPTransportRequest(
                        url: currentURL,
                        method: request.method,
                        headers: headers,
                        connectionAddress: connectionAddress
                    ),
                    timeout: timeout,
                    maximumBodyBytes: maximumBodyBytes
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

                if request.method == .get {
                    guard response.body.count <= maximumBodyBytes else {
                        throw HLSRelayError.responseTooLarge
                    }
                    if let contentLength = response.contentLength,
                       contentLength > Int64(maximumBodyBytes) {
                        throw HLSRelayError.responseTooLarge
                    }
                }

                return HLSRelayUpstreamResponse(
                    statusCode: response.statusCode,
                    body: request.method == .head ? Data() : response.body,
                    finalURL: currentURL,
                    contentType: safeHeader(response.contentType),
                    contentLength: response.contentLength,
                    contentRange: safeHeader(response.contentRange),
                    acceptRanges: safeHeader(response.acceptRanges),
                    etag: safeHeader(response.etag),
                    lastModified: safeHeader(response.lastModified),
                    cacheControl: safeHeader(response.cacheControl)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch HLSRelayHTTPTransportError.responseTooLarge {
            throw HLSRelayError.responseTooLarge
        } catch let error as HLSRelayError {
            throw error
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            // Never surface transport descriptions: they may include a source
            // URL whose path/query contains provider credentials.
            throw HLSRelayError.upstreamFailure
        }
    }

    private func forwardedHeaders(for request: HLSRelayUpstreamRequest) -> [String: String] {
        var headers: [String: String] = [:]
        if let range = safeHeader(request.range), range.lowercased().hasPrefix("bytes=") {
            headers["Range"] = range
        }
        if let etag = safeHeader(request.ifNoneMatch) {
            headers["If-None-Match"] = etag
        }
        if let modified = safeHeader(request.ifModifiedSince) {
            headers["If-Modified-Since"] = modified
        }
        return headers
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
        guard let normalized = components.url,
              normalized.host == host else {
            throw HLSRelayError.upstreamFailure
        }
        return normalized
    }

    private func canonicalRedirectKey(_ url: URL) -> String {
        url.absoluteString
    }

    private func safeHeader(_ value: String?, maximumBytes: Int = 1_024) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumBytes,
              !trimmed.contains("\r"),
              !trimmed.contains("\n") else { return nil }
        return trimmed
    }

    private static func isRedirect(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }
}

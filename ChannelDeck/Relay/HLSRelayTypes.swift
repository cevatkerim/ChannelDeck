import Foundation

enum HLSRelayUpstreamMethod: String, Equatable, Sendable {
    case get = "GET"
    case head = "HEAD"
}

/// The relay deliberately forwards only headers required by HLS byte serving
/// and cache revalidation. Cookie, authorization, host, and forwarding headers
/// from a LAN client never reach the upstream service.
struct HLSRelayUpstreamRequest: Equatable, Sendable {
    let url: URL
    let method: HLSRelayUpstreamMethod
    let range: String?
    let ifNoneMatch: String?
    let ifModifiedSince: String?

    init(
        url: URL,
        method: HLSRelayUpstreamMethod = .get,
        range: String? = nil,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil
    ) {
        self.url = url
        self.method = method
        self.range = range
        self.ifNoneMatch = ifNoneMatch
        self.ifModifiedSince = ifModifiedSince
    }
}

struct HLSRelayUpstreamResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
    let finalURL: URL
    let contentType: String?
    let contentLength: Int64?
    let contentRange: String?
    let acceptRanges: String?
    let etag: String?
    let lastModified: String?
    let cacheControl: String?

    init(
        statusCode: Int,
        body: Data,
        finalURL: URL,
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
        self.finalURL = finalURL
        self.contentType = contentType
        self.contentLength = contentLength
        self.contentRange = contentRange
        self.acceptRanges = acceptRanges
        self.etag = etag
        self.lastModified = lastModified
        self.cacheControl = cacheControl
    }
}

protocol HLSRelayUpstreamFetching: Sendable {
    func fetch(_ request: HLSRelayUpstreamRequest) async throws -> HLSRelayUpstreamResponse
}

struct HLSRelayRequest: Equatable, Sendable {
    let method: HLSRelayUpstreamMethod
    let path: String
    let range: String?
    let ifNoneMatch: String?
    let ifModifiedSince: String?
    /// Derived from Accept-Encoding at the HTTP boundary. The original header
    /// is intentionally not retained beyond request parsing.
    let acceptsGzip: Bool

    init(
        method: HLSRelayUpstreamMethod,
        path: String,
        range: String?,
        ifNoneMatch: String?,
        ifModifiedSince: String?,
        acceptsGzip: Bool = false
    ) {
        self.method = method
        self.path = path
        self.range = range
        self.ifNoneMatch = ifNoneMatch
        self.ifModifiedSince = ifModifiedSince
        self.acceptsGzip = acceptsGzip
    }
}

struct HLSRelayResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct HLSRelaySessionDescriptor: Equatable, Sendable {
    /// The only URL that leaves the relay boundary. It contains an unguessable
    /// session token but no upstream host, path, query, or credentials.
    let playlistURL: URL
}

enum HLSRelayError: Error, Equatable, LocalizedError, Sendable {
    case invalidRelayOrigin
    case invalidSource
    case unsupportedContinuousTransportStream
    case sourceIsNotHLS
    case invalidPlaylistEncoding
    case invalidPlaylistURI
    case invalidRequest
    case sessionNotFound
    case resourceNotFound
    case invalidTranscodedOutputDirectory
    case localArtifactUnavailable
    case preparationTimedOut
    case upstreamFailure
    case upstreamRejected(Int)
    case responseTooLarge
    case randomGenerationFailed
    case listenerFailed

    var errorDescription: String? {
        switch self {
        case .invalidRelayOrigin:
            "The secure relay address is invalid."
        case .invalidSource:
            "The selected stream address is invalid."
        case .unsupportedContinuousTransportStream:
            "This continuous MPEG transport stream could not be prepared for AirPlay."
        case .sourceIsNotHLS:
            "The selected stream is not an HLS playlist."
        case .invalidPlaylistEncoding, .invalidPlaylistURI:
            "The HLS playlist is malformed."
        case .invalidRequest:
            "The relay received an invalid request."
        case .sessionNotFound, .resourceNotFound:
            "The AirPlay relay session is no longer available."
        case .invalidTranscodedOutputDirectory:
            "The transcoded media output directory is invalid."
        case .localArtifactUnavailable:
            "The transcoded media artifact is unavailable."
        case .preparationTimedOut:
            "Preparing the secure AirPlay stream took too long."
        case .upstreamFailure:
            "The relay could not reach the channel provider."
        case let .upstreamRejected(status):
            "The channel provider returned HTTP status \(status)."
        case .responseTooLarge:
            "The relayed media response exceeded its safety limit."
        case .randomGenerationFailed:
            "The relay could not create a secure session."
        case .listenerFailed:
            "The secure AirPlay relay could not be started."
        }
    }
}

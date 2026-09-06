import Foundation
import Security
import Darwin

/// Stateful, transport-independent HLS reverse proxy. The Network listener and
/// unit tests both feed requests through this actor.
actor HLSRelayCore {
    private struct Resource {
        let upstreamURL: URL
        var kind: HLSRelayResourceKind
    }

    private struct Session {
        let token: String
        let relayOrigin: URL
        var expiresAt: Date
        var resources: [String: Resource]
        var resourceIDsByURL: [URL: String]
        var initialRootResponse: HLSRelayUpstreamResponse?
        var transcodedOutput: TranscodedOutputDirectory?
    }

    private enum Route {
        case upstream(token: String, resourceID: String)
        case transcoded(token: String, fileName: String, isPlaylist: Bool)
    }

    private enum LocalByteRangeSelection {
        case full
        case satisfiable(lowerBound: Int64, upperBound: Int64)
        case unsatisfiable
    }

    private let upstream: any HLSRelayUpstreamFetching
    private let playlistRewriter = HLSPlaylistRewriter()
    private let sessionLifetime: TimeInterval
    private let maximumPlaylistBytes: Int
    private let maximumLocalArtifactBytes: Int
    private let now: @Sendable () -> Date
    private let sessionTokenGenerator: @Sendable () throws -> String
    private var sessions: [String: Session] = [:]

    init(
        upstream: any HLSRelayUpstreamFetching,
        sessionLifetime: TimeInterval = 30 * 60,
        maximumPlaylistBytes: Int = 5 * 1_024 * 1_024,
        maximumLocalArtifactBytes: Int = 128 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = Date.init,
        sessionTokenGenerator: @escaping @Sendable () throws -> String = {
            try HLSRelayRandomToken.generate(byteCount: 32)
        }
    ) {
        precondition(maximumPlaylistBytes > 0)
        precondition(maximumLocalArtifactBytes > 0)
        self.upstream = upstream
        self.sessionLifetime = sessionLifetime
        self.maximumPlaylistBytes = maximumPlaylistBytes
        self.maximumLocalArtifactBytes = maximumLocalArtifactBytes
        self.now = now
        self.sessionTokenGenerator = sessionTokenGenerator
    }

    /// Performs an HLS preflight before exposing a LAN URL. Creating a new
    /// session invalidates any prior token because ChannelDeck owns one player.
    func createSession(sourceURL: URL, relayOrigin: URL) async throws -> HLSRelaySessionDescriptor {
        guard let sourceScheme = sourceURL.scheme?.lowercased(),
              sourceScheme == "http" || sourceScheme == "https",
              sourceURL.host?.isEmpty == false else {
            throw HLSRelayError.invalidSource
        }
        if sourceURL.pathExtension.lowercased() == "ts" {
            throw HLSRelayError.unsupportedContinuousTransportStream
        }
        try validateRelayOrigin(relayOrigin)

        let response = try await fetch(
            HLSRelayUpstreamRequest(url: sourceURL)
        )
        // A provider may finish a cancelled preflight late. Never let that
        // response invalidate the session for the newly selected channel.
        try Task.checkCancellation()
        guard (200 ... 299).contains(response.statusCode) else {
            throw HLSRelayError.upstreamRejected(response.statusCode)
        }
        guard response.body.count <= maximumPlaylistBytes else {
            throw HLSRelayError.responseTooLarge
        }
        if isTransportStreamContentType(response.contentType) {
            throw HLSRelayError.unsupportedContinuousTransportStream
        }
        guard playlistRewriter.isHLSPlaylist(response.body) else {
            throw HLSRelayError.sourceIsNotHLS
        }

        let token = try uniqueSessionToken()
        let rootResourceID = "root"
        sessions.removeAll(keepingCapacity: true)
        sessions[token] = Session(
            token: token,
            relayOrigin: relayOrigin,
            expiresAt: now().addingTimeInterval(sessionLifetime),
            resources: [
                rootResourceID: Resource(upstreamURL: sourceURL, kind: .playlist)
            ],
            resourceIDsByURL: [sourceURL: rootResourceID],
            initialRootResponse: response,
            transcodedOutput: nil
        )

        return HLSRelaySessionDescriptor(
            playlistURL: relayURL(
                origin: relayOrigin,
                token: token,
                resourceID: rootResourceID,
                kind: .playlist,
                isRoot: true
            )
        )
    }

    /// Reserves an opaque relay session for a transcoder-fed source without
    /// fetching or retaining the provider URL. Until generated output is
    /// registered, none of this session's routes can serve media.
    func createTranscodingSession(relayOrigin: URL) throws -> HLSRelaySessionDescriptor {
        try validateRelayOrigin(relayOrigin)
        let token = try uniqueSessionToken()
        sessions.removeAll(keepingCapacity: true)
        sessions[token] = Session(
            token: token,
            relayOrigin: relayOrigin,
            expiresAt: now().addingTimeInterval(sessionLifetime),
            resources: [:],
            resourceIDsByURL: [:],
            initialRootResponse: nil,
            transcodedOutput: nil
        )
        return HLSRelaySessionDescriptor(
            playlistURL: relayURL(
                origin: relayOrigin,
                token: token,
                resourceID: "root",
                kind: .playlist,
                isRoot: true
            )
        )
    }

    func invalidateAllSessions() {
        sessions.removeAll()
    }

    /// Registers the directory owned by the transcoder for one existing relay
    /// session. The returned URL is receiver-safe and contains no filesystem
    /// path. Re-registering or invalidating a session only forgets the directory;
    /// the relay never removes caller-owned files.
    func registerTranscodedOutputDirectory(
        _ directoryURL: URL,
        for sessionDescriptor: HLSRelaySessionDescriptor
    ) throws -> URL {
        pruneExpiredSessions()
        guard let token = sessions.first(where: { token, session in
            relayURL(
                origin: session.relayOrigin,
                token: token,
                resourceID: "root",
                kind: .playlist,
                isRoot: true
            ) == sessionDescriptor.playlistURL
        })?.key,
        var session = sessions[token] else {
            throw HLSRelayError.sessionNotFound
        }

        let output = try TranscodedOutputDirectory(url: directoryURL)
        session.transcodedOutput = output
        session.expiresAt = now().addingTimeInterval(sessionLifetime)
        sessions[token] = session
        return transcodedPlaylistURL(origin: session.relayOrigin, token: token)
    }

    func handle(_ request: HLSRelayRequest) async throws -> HLSRelayResponse {
        pruneExpiredSessions()
        let route = try parseRoute(request.path)
        switch route {
        case let .transcoded(token, fileName, isPlaylist):
            return try handleTranscoded(
                token: token,
                fileName: fileName,
                isPlaylist: isPlaylist,
                request: request
            )
        case let .upstream(token, resourceID):
            return try await handleUpstream(
                token: token,
                resourceID: resourceID,
                request: request
            )
        }
    }

    private func handleUpstream(
        token: String,
        resourceID: String,
        request: HLSRelayRequest
    ) async throws -> HLSRelayResponse {
        guard var session = sessions[token] else {
            throw HLSRelayError.sessionNotFound
        }
        guard var resource = session.resources[resourceID] else {
            throw HLSRelayError.resourceNotFound
        }
        session.expiresAt = now().addingTimeInterval(sessionLifetime)

        let range = resource.kind == .playlist ? nil : try sanitizedRange(request.range)
        let upstreamRequest = HLSRelayUpstreamRequest(
            url: resource.upstreamURL,
            method: request.method,
            range: range,
            ifNoneMatch: sanitizedHeader(request.ifNoneMatch),
            ifModifiedSince: sanitizedHeader(request.ifModifiedSince)
        )

        let upstreamResponse: HLSRelayUpstreamResponse
        if resourceID == "root",
           request.method == .get,
           range == nil,
           request.ifNoneMatch == nil,
           request.ifModifiedSince == nil,
           let initial = session.initialRootResponse {
            upstreamResponse = initial
            session.initialRootResponse = nil
            sessions[token] = session
        } else {
            upstreamResponse = try await fetch(upstreamRequest)
        }

        // Fetching suspends this actor while segment requests may complete in
        // parallel. Re-read the session so this response cannot overwrite URI
        // mappings registered by another connection.
        guard var latestSession = sessions[token],
              let latestResource = latestSession.resources[resourceID] else {
            throw HLSRelayError.sessionNotFound
        }
        session = latestSession
        resource = latestResource
        session.expiresAt = now().addingTimeInterval(sessionLifetime)
        guard (100 ... 599).contains(upstreamResponse.statusCode) else {
            throw HLSRelayError.upstreamFailure
        }

        var body = request.method == .head || !(200 ... 299).contains(upstreamResponse.statusCode)
            ? Data()
            : upstreamResponse.body
        let bodyIsPlaylist = resource.kind == .playlist
            || playlistRewriter.isHLSPlaylist(upstreamResponse.body)

        if bodyIsPlaylist, request.method == .get, upstreamResponse.statusCode == 200 {
            guard body.count <= maximumPlaylistBytes else {
                throw HLSRelayError.responseTooLarge
            }
            resource.kind = .playlist
            session.resources[resourceID] = resource
            body = try playlistRewriter.rewrite(
                body,
                relativeTo: upstreamResponse.finalURL
            ) { upstreamURL, kind in
                let resourceID = try self.register(
                    upstreamURL: upstreamURL,
                    kind: kind,
                    in: &session
                )
                return self.relayURL(
                    origin: session.relayOrigin,
                    token: session.token,
                    resourceID: resourceID,
                    kind: kind,
                    isRoot: false
                )
            }
        }

        latestSession = session
        sessions[token] = latestSession
        let headers = responseHeaders(
            upstream: upstreamResponse,
            body: body,
            method: request.method,
            isPlaylist: bodyIsPlaylist,
            resourceURL: resource.upstreamURL
        )
        return HLSRelayResponse(
            statusCode: upstreamResponse.statusCode,
            headers: headers,
            body: body
        )
    }

    private func handleTranscoded(
        token: String,
        fileName: String,
        isPlaylist: Bool,
        request: HLSRelayRequest
    ) throws -> HLSRelayResponse {
        guard var session = sessions[token] else {
            throw HLSRelayError.sessionNotFound
        }
        guard let output = session.transcodedOutput else {
            throw HLSRelayError.resourceNotFound
        }
        session.expiresAt = now().addingTimeInterval(sessionLifetime)
        sessions[token] = session

        let file = try output.openRegularFile(named: fileName)
        defer { Darwin.close(file.descriptor) }
        let fileSize = file.size
        let sizeLimit = isPlaylist ? maximumPlaylistBytes : maximumLocalArtifactBytes
        guard fileSize <= Int64(sizeLimit) else {
            throw HLSRelayError.responseTooLarge
        }

        let selectedRange = try localByteRange(request.range, fileSize: fileSize)
        let statusCode: Int
        let responseOffset: Int64
        let responseLength: Int64
        var headers: [String: String] = [
            "Accept-Ranges": "bytes",
            "Cache-Control": isPlaylist
                ? "no-cache, no-store, must-revalidate"
                : "public, max-age=60",
            "Content-Type": isPlaylist ? "application/vnd.apple.mpegurl" : "video/mp2t",
            "X-Content-Type-Options": "nosniff"
        ]
        if isPlaylist {
            headers["Vary"] = "Accept-Encoding"
        }

        switch selectedRange {
        case let .satisfiable(lowerBound, upperBound):
            statusCode = 206
            responseOffset = lowerBound
            responseLength = upperBound - lowerBound + 1
            headers["Content-Range"] = "bytes \(lowerBound)-\(upperBound)/\(fileSize)"
        case .unsatisfiable:
            headers["Content-Length"] = "0"
            headers["Content-Range"] = "bytes */\(fileSize)"
            return HLSRelayResponse(statusCode: 416, headers: headers, body: Data())
        case .full:
            statusCode = 200
            responseOffset = 0
            responseLength = fileSize
        }

        let fullPlaylistRepresentation: Data?
        if isPlaylist, request.range == nil, statusCode == 200 {
            let source = try readExactly(
                descriptor: file.descriptor,
                offset: responseOffset,
                length: responseLength
            )
            if fileName == "media-0.m3u8" {
                guard let playlist = String(data: source, encoding: .utf8) else {
                    throw HLSRelayError.localArtifactUnavailable
                }
                do {
                    fullPlaylistRepresentation = Data(
                        try HLSMediaPlaylistNormalizer().normalize(playlist).utf8
                    )
                } catch {
                    throw HLSRelayError.localArtifactUnavailable
                }
            } else {
                fullPlaylistRepresentation = source
            }
            guard let fullPlaylistRepresentation,
                  fullPlaylistRepresentation.count <= maximumPlaylistBytes else {
                throw HLSRelayError.responseTooLarge
            }
        } else {
            fullPlaylistRepresentation = nil
        }

        let shouldCompress = fullPlaylistRepresentation != nil && request.acceptsGzip
        let body: Data
        if shouldCompress {
            // HEAD describes the representation a corresponding GET would
            // receive, so compression still runs to calculate its exact size.
            guard let uncompressed = fullPlaylistRepresentation else {
                preconditionFailure("A gzip playlist must have a full representation")
            }
            let compressed = try GzipCompressor.compress(uncompressed)
            guard compressed.count <= maximumPlaylistBytes else {
                throw HLSRelayError.responseTooLarge
            }
            headers["Content-Encoding"] = "gzip"
            headers["Content-Length"] = String(compressed.count)
            body = request.method == .head ? Data() : compressed
        } else if let fullPlaylistRepresentation {
            headers["Content-Length"] = String(fullPlaylistRepresentation.count)
            body = request.method == .head ? Data() : fullPlaylistRepresentation
        } else {
            headers["Content-Length"] = String(responseLength)
            body = request.method == .head
                ? Data()
                : try readExactly(
                    descriptor: file.descriptor,
                    offset: responseOffset,
                    length: responseLength
                )
        }
        return HLSRelayResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private func register(
        upstreamURL: URL,
        kind: HLSRelayResourceKind,
        in session: inout Session
    ) throws -> String {
        if let existingID = session.resourceIDsByURL[upstreamURL] {
            if kind == .playlist {
                session.resources[existingID]?.kind = .playlist
            }
            return existingID
        }

        var resourceID: String
        repeat {
            resourceID = try HLSRelayRandomToken.generate(byteCount: 16)
        } while session.resources[resourceID] != nil
        session.resources[resourceID] = Resource(upstreamURL: upstreamURL, kind: kind)
        session.resourceIDsByURL[upstreamURL] = resourceID
        return resourceID
    }

    private func fetch(_ request: HLSRelayUpstreamRequest) async throws -> HLSRelayUpstreamResponse {
        do {
            try Task.checkCancellation()
            let response = try await upstream.fetch(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSRelayError {
            throw error
        } catch {
            throw HLSRelayError.upstreamFailure
        }
    }

    private func validateRelayOrigin(_ origin: URL) throws {
        guard origin.scheme?.lowercased() == "https",
              origin.host?.isEmpty == false,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil else {
            throw HLSRelayError.invalidRelayOrigin
        }
    }

    private func uniqueSessionToken() throws -> String {
        for _ in 0 ..< 8 {
            let token = try sessionTokenGenerator()
            guard token.count >= 32,
                  token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  sessions[token] == nil else { continue }
            return token
        }
        throw HLSRelayError.randomGenerationFailed
    }

    private func relayURL(
        origin: URL,
        token: String,
        resourceID: String,
        kind: HLSRelayResourceKind,
        isRoot: Bool
    ) -> URL {
        var url = origin
            .appendingPathComponent("s", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        if isRoot {
            return url.appendingPathComponent("index.m3u8", isDirectory: false)
        }
        url.appendPathComponent("r", isDirectory: true)
        return url.appendingPathComponent(
            resourceID + resourceExtension(kind: kind),
            isDirectory: false
        )
    }

    private func resourceExtension(kind: HLSRelayResourceKind) -> String {
        // FFmpeg's HLS demuxer rejects unknown segment extensions before it
        // sends an HTTP request (`extension_picky` defaults to true and `bin`
        // is not allowlisted). The path remains opaque, while `.ts` lets both
        // FFmpeg and AVFoundation accept the relayed MPEG-TS resources.
        kind == .playlist ? ".m3u8" : ".ts"
    }

    private func transcodedPlaylistURL(origin: URL, token: String) -> URL {
        origin
            .appendingPathComponent("s", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
            .appendingPathComponent("transcoded", isDirectory: true)
            .appendingPathComponent("index.m3u8", isDirectory: false)
    }

    private func parseRoute(_ requestTarget: String) throws -> Route {
        guard let components = URLComponents(string: requestTarget),
              components.scheme == nil,
              components.host == nil,
              components.fragment == nil else {
            throw HLSRelayError.invalidRequest
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "s" else {
            throw HLSRelayError.invalidRequest
        }
        let token = String(parts[1])
        if parts.count == 3, parts[2] == "index.m3u8" {
            return .upstream(token: token, resourceID: "root")
        }
        if parts.count == 4, parts[2] == "transcoded" {
            let fileName = String(parts[3])
            let isMediaPlaylist = fileName == "media-0.m3u8"
            let isSegment = fileName.range(
                of: #"^segment-0-[0-9]{9}\.ts$"#,
                options: .regularExpression
            ) != nil
            guard components.query == nil,
                  components.percentEncodedPath == components.path,
                  token.count >= 32,
                  token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  fileName == "index.m3u8" || isMediaPlaylist || isSegment,
                  components.path == "/s/\(token)/transcoded/\(fileName)" else {
                throw HLSRelayError.invalidRequest
            }
            return .transcoded(
                token: token,
                fileName: fileName,
                isPlaylist: fileName == "index.m3u8" || isMediaPlaylist
            )
        }
        guard parts.count == 4, parts[2] == "r" else {
            throw HLSRelayError.invalidRequest
        }
        let fileName = parts[3]
        guard let dot = fileName.firstIndex(of: "."), dot != fileName.startIndex else {
            throw HLSRelayError.invalidRequest
        }
        return .upstream(token: token, resourceID: String(fileName[..<dot]))
    }

    private func localByteRange(
        _ value: String?,
        fileSize: Int64
    ) throws -> LocalByteRangeSelection {
        guard let range = try sanitizedRange(value) else { return .full }
        guard let equals = range.firstIndex(of: "=") else {
            throw HLSRelayError.invalidRequest
        }
        let bounds = range[range.index(after: equals)...]
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { throw HLSRelayError.invalidRequest }

        if bounds[0].isEmpty {
            guard let suffixLength = Int64(bounds[1]),
                  suffixLength > 0,
                  fileSize > 0 else {
                return .unsatisfiable
            }
            return .satisfiable(
                lowerBound: max(0, fileSize - suffixLength),
                upperBound: fileSize - 1
            )
        }

        guard let lowerBound = Int64(bounds[0]),
              lowerBound < fileSize else {
            return .unsatisfiable
        }
        let upperBound: Int64
        if bounds[1].isEmpty {
            upperBound = fileSize - 1
        } else {
            guard let requestedUpperBound = Int64(bounds[1]),
                  requestedUpperBound >= lowerBound else {
                return .unsatisfiable
            }
            upperBound = min(requestedUpperBound, fileSize - 1)
        }
        return .satisfiable(lowerBound: lowerBound, upperBound: upperBound)
    }

    private func readExactly(
        descriptor: Int32,
        offset: Int64,
        length: Int64
    ) throws -> Data {
        guard length >= 0, length <= Int64(Int.max) else {
            throw HLSRelayError.responseTooLarge
        }
        guard length > 0 else { return Data() }

        let count = Int(length)
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw HLSRelayError.localArtifactUnavailable
            }
            var totalRead = 0
            while totalRead < count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    count - totalRead,
                    off_t(offset + Int64(totalRead))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw HLSRelayError.localArtifactUnavailable
                }
                guard result > 0 else {
                    throw HLSRelayError.localArtifactUnavailable
                }
                totalRead += result
            }
        }
        return data
    }

    private func responseHeaders(
        upstream: HLSRelayUpstreamResponse,
        body: Data,
        method: HLSRelayUpstreamMethod,
        isPlaylist: Bool,
        resourceURL: URL
    ) -> [String: String] {
        var headers: [String: String] = [:]
        headers["Content-Type"] = isPlaylist
            ? "application/vnd.apple.mpegurl"
            : safeContentType(upstream.contentType) ?? inferredContentType(for: resourceURL)
        let contentLength = method == .head
            ? max(0, upstream.contentLength ?? 0)
            : Int64(body.count)
        headers["Content-Length"] = String(contentLength)
        headers["Cache-Control"] = isPlaylist
            ? "no-cache, no-store, must-revalidate"
            : sanitizedHeader(upstream.cacheControl) ?? "public, max-age=60"
        headers["X-Content-Type-Options"] = "nosniff"

        if let contentRange = sanitizedHeader(upstream.contentRange) {
            headers["Content-Range"] = contentRange
        }
        if let acceptRanges = sanitizedHeader(upstream.acceptRanges) {
            headers["Accept-Ranges"] = acceptRanges
        }
        if let etag = sanitizedHeader(upstream.etag) {
            headers["ETag"] = etag
        }
        if let lastModified = sanitizedHeader(upstream.lastModified) {
            headers["Last-Modified"] = lastModified
        }
        return headers
    }

    private func safeContentType(_ value: String?) -> String? {
        guard let value = sanitizedHeader(value) else { return nil }
        let mime = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mime,
              mime.range(of: #"^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return mime
    }

    private func inferredContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": "application/vnd.apple.mpegurl"
        case "ts": "video/mp2t"
        case "m4s": "video/iso.segment"
        case "mp4", "m4v": "video/mp4"
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "vtt", "webvtt": "text/vtt"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }

    private func isTransportStreamContentType(_ value: String?) -> Bool {
        let type = value?.lowercased() ?? ""
        return type.contains("video/mp2t") || type.contains("video/mpeg")
    }

    private func sanitizedRange(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 128,
              trimmed.range(
                of: #"^bytes=(?:[0-9]+-[0-9]*|[0-9]*-[0-9]+)$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else {
            throw HLSRelayError.invalidRequest
        }
        return trimmed
    }

    private func sanitizedHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 4_096,
              !trimmed.contains("\r"),
              !trimmed.contains("\n") else {
            return nil
        }
        return trimmed
    }

    private func pruneExpiredSessions() {
        let deadline = now()
        sessions = sessions.filter { $0.value.expiresAt > deadline }
    }
}

/// Pins the registered directory by descriptor and opens children relative to
/// it. `O_NOFOLLOW` prevents both a directory symlink at registration and a
/// segment/playlist symlink at request time, without trusting path resolution.
private final class TranscodedOutputDirectory {
    struct OpenFile {
        let descriptor: Int32
        let size: Int64
    }

    private let descriptor: Int32

    init(url: URL) throws {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.host?.isEmpty != false,
              url.query == nil,
              url.fragment == nil else {
            throw HLSRelayError.invalidTranscodedOutputDirectory
        }

        let opened = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else {
            throw HLSRelayError.invalidTranscodedOutputDirectory
        }

        var metadata = stat()
        guard Darwin.fstat(opened, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(opened)
            throw HLSRelayError.invalidTranscodedOutputDirectory
        }
        descriptor = opened
    }

    deinit {
        Darwin.close(descriptor)
    }

    func openRegularFile(named fileName: String) throws -> OpenFile {
        // Route parsing already constrains this to index.m3u8 or segment-N.ts.
        // Keep this boundary independently defensive because it owns the fd.
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains("\0") else {
            throw HLSRelayError.resourceNotFound
        }

        let opened = fileName.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                throw HLSRelayError.resourceNotFound
            }
            throw HLSRelayError.localArtifactUnavailable
        }

        var metadata = stat()
        guard Darwin.fstat(opened, &metadata) == 0 else {
            Darwin.close(opened)
            throw HLSRelayError.localArtifactUnavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            Darwin.close(opened)
            throw HLSRelayError.resourceNotFound
        }
        return OpenFile(descriptor: opened, size: Int64(metadata.st_size))
    }
}

private enum HLSRelayRandomToken {
    static func generate(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw HLSRelayError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

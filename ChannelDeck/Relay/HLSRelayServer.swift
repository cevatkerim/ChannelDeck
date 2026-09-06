import Foundation
import Network
import Security

enum HLSRelayAcceptEncoding {
    static func acceptsGzip(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }

        var explicitGzip: Bool?
        var wildcard: Bool?
        for item in value.split(separator: ",", omittingEmptySubsequences: false) {
            let components = item.split(
                separator: ";",
                maxSplits: Int.max,
                omittingEmptySubsequences: false
            )
            guard let first = components.first else { continue }
            let coding = first.trimmingCharacters(in: .whitespaces).lowercased()
            guard coding == "gzip" || coding == "*" else { continue }

            let isEnabled = quality(components.dropFirst()) > 0
            if coding == "gzip" {
                explicitGzip = merge(explicitGzip, with: isEnabled)
            } else {
                wildcard = merge(wildcard, with: isEnabled)
            }
        }

        // An explicit gzip exclusion takes precedence over a permissive
        // wildcard, including when duplicated or malformed input is received.
        return explicitGzip ?? wildcard ?? false
    }

    private static func merge(_ current: Bool?, with candidate: Bool) -> Bool {
        current == false ? false : candidate
    }

    private static func quality<C: Collection>(_ parameters: C) -> Double
    where C.Element == Substring {
        var parsedQuality: Double?
        for parameter in parameters {
            let pair = parameter.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "q" else {
                continue
            }
            guard parsedQuality == nil,
                  let quality = parseQuality(
                      String(pair[1]).trimmingCharacters(in: .whitespaces)
                  ) else {
                return 0
            }
            parsedQuality = quality
        }
        return parsedQuality ?? 1
    }

    private static func parseQuality(_ value: String) -> Double? {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              parts[0] == "0" || parts[0] == "1" else {
            return nil
        }
        if parts.count == 2 {
            let fraction = parts[1]
            guard fraction.count <= 3,
                  fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
                  parts[0] == "0" || fraction.allSatisfy({ $0 == "0" }) else {
                return nil
            }
        }
        return Double(value)
    }
}

/// Sendable wrapper around the TLS identity provisioned by the app's
/// certificate manager. The certificate must be trusted by the AirPlay
/// receiver and contain the advertised host in its subject alternative names.
struct HLSRelayTLSIdentity: @unchecked Sendable {
    fileprivate let value: sec_identity_t

    init(_ identity: SecIdentity) throws {
        guard let value = sec_identity_create(identity) else {
            throw HLSRelayError.listenerFailed
        }
        self.value = value
    }

    init(_ identity: sec_identity_t) {
        value = identity
    }
}

/// Ephemeral HTTPS listener whose only routable paths contain a random relay
/// session token. It intentionally implements the small HTTP/1.1 subset used
/// by AVPlayer and AirPlay receivers and closes each response connection.
actor HLSRelayServer {
    private static let maximumConnections = 64
    private let identity: HLSRelayTLSIdentity
    private let advertisedHost: String
    private let core: HLSRelayCore
    private let sessionCoordinator: HLSRelaySessionCoordinator
    private let responseDiagnosticRecorder: any HLSRelayResponseDiagnosticRecording
    private let queue = DispatchQueue(label: "com.kerimincedayi.ChannelDeck.hls-relay")
    private var listener: NWListener?
    private var relayOrigin: URL?
    private var connections: [UUID: HLSRelayHTTPConnection] = [:]

    init(
        identity: HLSRelayTLSIdentity,
        advertisedHost: String,
        upstream: any HLSRelayUpstreamFetching,
        audioTranscoder: (any HLSAudioTranscoding)? = nil,
        mpegTSStreamer: (any MPEGTSUpstreamStreaming)? = nil,
        responseDiagnosticRecorder: any HLSRelayResponseDiagnosticRecording = OSLogHLSRelayResponseDiagnosticRecorder(),
        preparationTimeout: Duration = .seconds(45),
        sessionLifetime: TimeInterval = 30 * 60
    ) {
        precondition(preparationTimeout > .zero)
        self.identity = identity
        self.advertisedHost = advertisedHost
        self.responseDiagnosticRecorder = responseDiagnosticRecorder
        let core = HLSRelayCore(upstream: upstream, sessionLifetime: sessionLifetime)
        self.core = core
        sessionCoordinator = HLSRelaySessionCoordinator(
            core: core,
            audioTranscoder: audioTranscoder,
            mpegTSStreamer: mpegTSStreamer,
            preparationTimeout: preparationTimeout
        )
    }

    /// Binds the TLS listener without creating a playback session. Setup uses
    /// this to verify the identity, port binding, and local-network permission
    /// before reporting that the relay is ready.
    func start() async throws {
        _ = try await startIfNeeded()
    }

    func relayURL(for sourceURL: URL, preferEarlyPlayback: Bool = false) async throws -> HLSRelaySessionDescriptor {
        let origin = try await startIfNeeded()
        return try await sessionCoordinator.prepare(
            sourceURL: sourceURL, relayOrigin: origin, preferEarlyPlayback: preferEarlyPlayback
        )
    }

    func waitForAirPlayReadiness() async throws {
        try await sessionCoordinator.waitForAirPlayReadiness()
    }

    func beginRecording(
        id: UUID,
        packageDirectory: URL,
        quality: BufferRecordingQuality
    ) async throws -> TimeInterval {
        try await sessionCoordinator.beginRecording(
            id: id,
            packageDirectory: packageDirectory,
            quality: quality
        )
    }

    func finishRecording() async throws -> FFmpegLiveRecordingArtifact? {
        try await sessionCoordinator.finishRecording()
    }

    func stop() async {
        await sessionCoordinator.stop()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        relayOrigin = nil
    }

    private func startIfNeeded() async throws -> URL {
        if let relayOrigin { return relayOrigin }
        guard !advertisedHost.isEmpty,
              !advertisedHost.contains("/"),
              !advertisedHost.contains("@") else {
            throw HLSRelayError.invalidRelayOrigin
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            identity.value
        )
        sec_protocol_options_add_tls_application_protocol(
            tlsOptions.securityProtocolOptions,
            "http/1.1"
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: .any)
        } catch {
            throw HLSRelayError.listenerFailed
        }
        listener = newListener

        let gate = HLSRelayStartGate()
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let port = newListener.port else {
                    gate.fail(HLSRelayError.listenerFailed)
                    return
                }
                gate.succeed(port)
            case .failed:
                gate.fail(HLSRelayError.listenerFailed)
            case .cancelled:
                gate.fail(CancellationError())
            default:
                break
            }
        }
        newListener.start(queue: queue)

        let port: NWEndpoint.Port
        do {
            port = try await withTaskCancellationHandler {
                try await gate.wait()
            } onCancel: {
                newListener.cancel()
                gate.fail(CancellationError())
            }
        } catch {
            newListener.cancel()
            if listener === newListener {
                listener = nil
            }
            throw error
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = advertisedHost
        components.port = Int(port.rawValue)
        guard let origin = components.url else {
            newListener.cancel()
            listener = nil
            throw HLSRelayError.invalidRelayOrigin
        }
        relayOrigin = origin
        return origin
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        let handler = HLSRelayHTTPConnection(
            connection: connection,
            core: core,
            queue: queue,
            responseDiagnosticRecorder: responseDiagnosticRecorder
        ) { [weak self] in
            Task { await self?.connectionDidClose(id) }
        }
        connections[id] = handler
        handler.start()
    }

    private func connectionDidClose(_ id: UUID) {
        connections.removeValue(forKey: id)
    }
}

/// Coordinates source classification, private raw-byte ingestion, generated
/// HLS publication, cancellation, and cleanup independently of the TLS listener.
/// Keeping this seam free of Network framework types makes orchestration tests
/// deterministic and prevents a continuous response from entering HLSRelayCore's
/// whole-body fetch path.
actor HLSRelaySessionCoordinator {
    private let core: HLSRelayCore
    private let audioTranscoder: (any HLSAudioTranscoding)?
    private let mpegTSStreamer: (any MPEGTSUpstreamStreaming)?
    private let preparationTimeout: Duration
    private var preparationID = UUID()

    init(
        core: HLSRelayCore,
        audioTranscoder: (any HLSAudioTranscoding)?,
        mpegTSStreamer: (any MPEGTSUpstreamStreaming)?,
        preparationTimeout: Duration = .seconds(45)
    ) {
        precondition(preparationTimeout > .zero)
        self.core = core
        self.audioTranscoder = audioTranscoder
        self.mpegTSStreamer = mpegTSStreamer
        self.preparationTimeout = preparationTimeout
    }

    func prepare(
        sourceURL: URL, relayOrigin: URL, preferEarlyPlayback: Bool = false
    ) async throws -> HLSRelaySessionDescriptor {
        let id = UUID()
        preparationID = id
        if let audioTranscoder {
            await audioTranscoder.stop()
        }
        try Task.checkCancellation()
        guard preparationID == id else { throw CancellationError() }
        await core.invalidateAllSessions()

        do {
            return try await withThrowingTaskGroup(of: HLSRelaySessionDescriptor.self) { group in
                group.addTask { [self] in
                    try await prepareWithoutTimeout(
                        sourceURL: sourceURL, relayOrigin: relayOrigin, preferEarlyPlayback: preferEarlyPlayback
                    )
                }
                group.addTask { [preparationTimeout] in
                    try await Task.sleep(for: preparationTimeout)
                    try Task.checkCancellation()
                    throw HLSRelayError.preparationTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
        } catch {
            // A cancelled channel must never tear down its replacement.
            guard preparationID == id else { throw CancellationError() }
            if let audioTranscoder {
                await audioTranscoder.stop()
            }
            if preparationID == id { await core.invalidateAllSessions() }
            throw error
        }
    }

    func stop() async {
        preparationID = UUID()
        if let audioTranscoder {
            await audioTranscoder.stop()
        }
        await core.invalidateAllSessions()
    }

    func waitForAirPlayReadiness() async throws {
        try await audioTranscoder?.waitForAirPlayReadiness()
    }

    func beginRecording(
        id: UUID,
        packageDirectory: URL,
        quality: BufferRecordingQuality
    ) async throws -> TimeInterval {
        guard let audioTranscoder else {
            throw FFmpegLiveRecordingError.noActiveStream
        }
        return try await audioTranscoder.beginRecording(
            id: id,
            packageDirectory: packageDirectory,
            quality: quality
        )
    }

    func finishRecording() async throws -> FFmpegLiveRecordingArtifact? {
        guard let audioTranscoder else { return nil }
        return try await audioTranscoder.finishRecording()
    }

    private func prepareWithoutTimeout(
        sourceURL: URL,
        relayOrigin: URL,
        preferEarlyPlayback: Bool
    ) async throws -> HLSRelaySessionDescriptor {
        if Self.shouldStreamAsMPEGTS(sourceURL) {
            guard let audioTranscoder, let mpegTSStreamer else {
                throw HLSRelayError.unsupportedContinuousTransportStream
            }
            let sourceSession = try await core.createTranscodingSession(relayOrigin: relayOrigin)
            try Task.checkCancellation()
            let feed: MPEGTSFeeding = { consumer in
                try await mpegTSStreamer.stream(from: sourceURL, into: consumer)
            }
            let transcode = try await preferEarlyPlayback
                ? audioTranscoder.startMPEGTSForLocalPlayback(feeding: feed)
                : audioTranscoder.startMPEGTS(feeding: feed)
            return try await publish(transcode, for: sourceSession)
        }

        let sourceSession = try await core.createSession(
            sourceURL: sourceURL,
            relayOrigin: relayOrigin
        )
        try Task.checkCancellation()
        guard let audioTranscoder else { return sourceSession }
        let transcode = try await preferEarlyPlayback
            ? audioTranscoder.startForLocalPlayback(relayURL: sourceSession.playlistURL)
            : audioTranscoder.start(relayURL: sourceSession.playlistURL)
        return try await publish(transcode, for: sourceSession)
    }

    /// IPTV providers commonly expose continuous MPEG-TS feeds through opaque,
    /// extensionless endpoints. Only explicit playlist extensions should take
    /// the HLS proxy path; an extensionless URL otherwise gets misread as a
    /// manifest and FFmpeg repeatedly retries a stream that can never parse.
    private static func shouldStreamAsMPEGTS(_ sourceURL: URL) -> Bool {
        let pathExtension = sourceURL.pathExtension.lowercased()
        return pathExtension.isEmpty || pathExtension == "ts"
    }

    private func publish(
        _ transcode: FFmpegHLSAudioTranscodeSession,
        for sourceSession: HLSRelaySessionDescriptor
    ) async throws -> HLSRelaySessionDescriptor {
        try Task.checkCancellation()
        let publicPlaylistURL = try await core.registerTranscodedOutputDirectory(
            transcode.playlistURL.deletingLastPathComponent(),
            for: sourceSession
        )
        return HLSRelaySessionDescriptor(playlistURL: publicPlaylistURL)
    }
}

private final class HLSRelayStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<NWEndpoint.Port, any Error>?
    private var continuation: CheckedContinuation<NWEndpoint.Port, any Error>?

    func wait() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed(_ port: NWEndpoint.Port) {
        finish(.success(port))
    }

    func fail(_ error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<NWEndpoint.Port, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class HLSRelayHTTPConnection: @unchecked Sendable {
    private enum ParseError: Error {
        case invalid
        case methodNotAllowed
    }

    private static let maximumHeaderBytes = 32 * 1_024

    private let connection: NWConnection
    private let core: HLSRelayCore
    private let queue: DispatchQueue
    private let responseDiagnosticRecorder: any HLSRelayResponseDiagnosticRecording
    private let onClose: @Sendable () -> Void
    private var received = Data()
    private var didStartReceiving = false
    private var didClose = false
    private var headerTimeout: DispatchWorkItem?

    init(
        connection: NWConnection,
        core: HLSRelayCore,
        queue: DispatchQueue,
        responseDiagnosticRecorder: any HLSRelayResponseDiagnosticRecording,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.core = core
        self.queue = queue
        self.responseDiagnosticRecorder = responseDiagnosticRecorder
        self.onClose = onClose
    }

    func start() {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.didClose else { return }
            self.sendError(status: 408, reason: "Request Timeout")
        }
        headerTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.didStartReceiving else { return }
                self.didStartReceiving = true
                self.receiveHeader()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        queue.async { [weak self] in
            self?.close()
        }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.received.append(data)
            }
            if self.received.count > Self.maximumHeaderBytes {
                self.sendError(status: 431, reason: "Request Header Fields Too Large")
                return
            }
            if let headerEnd = self.received.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                let header = self.received[..<headerEnd]
                self.process(Data(header))
                return
            }
            if error != nil || isComplete {
                self.sendError(status: 400, reason: "Bad Request")
                return
            }
            self.receiveHeader()
        }
    }

    private func process(_ headerData: Data) {
        headerTimeout?.cancel()
        headerTimeout = nil
        let request: HLSRelayRequest
        do {
            request = try parse(headerData)
        } catch ParseError.methodNotAllowed {
            sendError(status: 405, reason: "Method Not Allowed", headers: ["Allow": "GET, HEAD"])
            return
        } catch {
            sendError(status: 400, reason: "Bad Request")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.core.handle(request)
                self.queue.async { [weak self] in
                    self?.send(response, for: request)
                }
            } catch is CancellationError {
                self.queue.async { [weak self] in self?.close() }
            } catch let error as HLSRelayError {
                self.queue.async { [weak self] in self?.send(error: error, for: request) }
            } catch {
                self.queue.async { [weak self] in
                    self?.recordDiagnostic(
                        request: request,
                        statusCode: 500,
                        responseBodyBytes: 0
                    )
                    self?.sendError(status: 500, reason: "Internal Server Error")
                }
            }
        }
    }

    private func parse(_ data: Data) throws -> HLSRelayRequest {
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            throw ParseError.invalid
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ParseError.invalid }
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 3,
              components[1].hasPrefix("/"),
              components[1].utf8.count <= 4_096,
              components[2] == "HTTP/1.1" || components[2] == "HTTP/1.0" else {
            throw ParseError.invalid
        }

        let method: HLSRelayUpstreamMethod
        switch components[0] {
        case "GET": method = .get
        case "HEAD": method = .head
        default: throw ParseError.methodNotAllowed
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else {
                throw ParseError.invalid
            }
            let name = line[..<colon].lowercased()
            guard name.range(of: #"^[a-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                  headers[name] == nil else {
                throw ParseError.invalid
            }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 4_096 else { throw ParseError.invalid }
            headers[name] = value
        }

        return HLSRelayRequest(
            method: method,
            path: String(components[1]),
            range: headers["range"],
            ifNoneMatch: headers["if-none-match"],
            ifModifiedSince: headers["if-modified-since"],
            acceptsGzip: HLSRelayAcceptEncoding.acceptsGzip(headers["accept-encoding"])
        )
    }

    private func send(_ response: HLSRelayResponse, for request: HLSRelayRequest) {
        recordDiagnostic(
            request: request,
            statusCode: response.statusCode,
            responseBodyBytes: response.body.count
        )
        send(
            status: response.statusCode,
            reason: reasonPhrase(for: response.statusCode),
            headers: response.headers,
            body: response.body
        )
    }

    private func send(error: HLSRelayError, for request: HLSRelayRequest) {
        let status: Int
        let reason: String
        switch error {
        case .invalidRequest:
            (status, reason) = (400, "Bad Request")
        case .sessionNotFound, .resourceNotFound:
            (status, reason) = (404, "Not Found")
        case .responseTooLarge, .upstreamFailure, .upstreamRejected:
            (status, reason) = (502, "Bad Gateway")
        default:
            (status, reason) = (500, "Internal Server Error")
        }
        recordDiagnostic(request: request, statusCode: status, responseBodyBytes: 0)
        sendError(status: status, reason: reason)
    }

    private func recordDiagnostic(
        request: HLSRelayRequest,
        statusCode: Int,
        responseBodyBytes: Int
    ) {
        guard let diagnostic = HLSRelayResponseDiagnostic.make(
            request: request,
            statusCode: statusCode,
            responseBodyBytes: responseBodyBytes
        ) else { return }
        responseDiagnosticRecorder.record(diagnostic)
    }

    private func sendError(
        status: Int,
        reason: String,
        headers: [String: String] = [:]
    ) {
        send(status: status, reason: reason, headers: headers, body: Data())
    }

    private func send(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data
    ) {
        guard !didClose else { return }
        var allHeaders = headers
        if allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = String(body.count)
        }
        allHeaders["Connection"] = "close"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(
            content: payload,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.close()
            }
        )
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 410: "Gone"
        case 416: "Range Not Satisfiable"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Status"
        }
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        headerTimeout?.cancel()
        headerTimeout = nil
        connection.cancel()
        onClose()
    }
}

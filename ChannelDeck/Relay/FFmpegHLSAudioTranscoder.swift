import Darwin
import AVFoundation
import Foundation

enum HLSMediaPlaylistNormalizationError: Error, Equatable, Sendable {
    case invalidPlaylist
}

/// Converts FFmpeg's rolling Media Playlist into a conservative form for
/// receiver playback. The transformation is deliberately pure so the relay can
/// apply it to every playlist update without retaining a credential-bearing URL
/// or mutable parser state.
struct HLSMediaPlaylistNormalizer: Sendable {
    let targetDuration: Int

    init(targetDuration: Int = 12) {
        precondition(targetDuration > 0)
        self.targetDuration = targetDuration
    }

    func normalize(_ playlist: String) throws -> String {
        var source = playlist
        if source.hasPrefix("\u{FEFF}") {
            source.removeFirst()
        }
        source = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let inputLines = source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard inputLines.first == "#EXTM3U" else {
            throw HLSMediaPlaylistNormalizationError.invalidPlaylist
        }

        var targetDurationCount = 0
        var programDateTimeCount = 0
        var filtered: [String] = []
        filtered.reserveCapacity(inputLines.count)

        for line in inputLines {
            if line.hasPrefix("#EXT-X-ALLOW-CACHE:") {
                continue
            }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDurationCount += 1
                filtered.append("#EXT-X-TARGETDURATION:\(targetDuration)")
                continue
            }
            if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                programDateTimeCount += 1
                filtered.append(try canonicalProgramDateTime(line))
                continue
            }
            filtered.append(line)
        }

        guard targetDurationCount == 1, programDateTimeCount >= 1 else {
            throw HLSMediaPlaylistNormalizationError.invalidPlaylist
        }

        var output: [String] = []
        var pendingLines: [String] = []
        var segmentCount = 0

        for line in filtered {
            if line.hasPrefix("#") {
                pendingLines.append(line)
                continue
            }
            guard !line.isEmpty else { continue }
            guard let extentIndex = pendingLines.lastIndex(where: { $0.hasPrefix("#EXTINF:") }),
                  pendingLines.filter({ $0.hasPrefix("#EXTINF:") }).count == 1 else {
                throw HLSMediaPlaylistNormalizationError.invalidPlaylist
            }
            let extent = pendingLines[extentIndex]
            guard let duration = Self.extentDuration(extent),
                  duration.rounded() <= Double(targetDuration) else {
                throw HLSMediaPlaylistNormalizationError.invalidPlaylist
            }

            let dateIndices = pendingLines.indices.filter {
                pendingLines[$0].hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
            }
            guard dateIndices.count <= 1 else {
                throw HLSMediaPlaylistNormalizationError.invalidPlaylist
            }

            var reordered = pendingLines
            if let dateIndex = dateIndices.first {
                let date = reordered.remove(at: dateIndex)
                guard let adjustedExtentIndex = reordered.lastIndex(where: {
                    $0.hasPrefix("#EXTINF:")
                }) else {
                    throw HLSMediaPlaylistNormalizationError.invalidPlaylist
                }
                reordered.insert(date, at: adjustedExtentIndex)
            }

            output.append(contentsOf: reordered)
            output.append(line)
            pendingLines.removeAll(keepingCapacity: true)
            segmentCount += 1
        }

        output.append(contentsOf: pendingLines)
        guard segmentCount >= 1 else {
            throw HLSMediaPlaylistNormalizationError.invalidPlaylist
        }
        return output.joined(separator: "\n") + "\n"
    }

    private func canonicalProgramDateTime(_ line: String) throws -> String {
        let prefix = "#EXT-X-PROGRAM-DATE-TIME:"
        var value = String(line.dropFirst(prefix.count))
        if value.range(
            of: #"[+-][0-9]{4}$"#,
            options: .regularExpression
        ) != nil {
            let colon = value.index(value.endIndex, offsetBy: -2)
            value.insert(":", at: colon)
        }
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{3,})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
            options: .regularExpression
        ) != nil else {
            throw HLSMediaPlaylistNormalizationError.invalidPlaylist
        }
        return prefix + value
    }

    private static func extentDuration(_ line: String) -> Double? {
        let value = line
            .dropFirst("#EXTINF:".count)
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let duration = Double(value), duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }
}

protocol FFmpegExecutableLocating: Sendable {
    func executableURL() -> URL?
}

enum FFmpegExecutableSource: Equatable, Sendable {
    case bundled
    case homebrew
    case custom

    var displayName: String {
        switch self {
        case .bundled: "Bundled"
        case .homebrew: "Homebrew"
        case .custom: "Custom"
        }
    }
}

struct FFmpegExecutableAvailability: Equatable, Sendable {
    let executableURL: URL?
    let source: FFmpegExecutableSource?

    var isAvailable: Bool { executableURL != nil }

    var statusTitle: String {
        guard let source else { return "FFmpeg not found" }
        return "Available · \(source.displayName)"
    }

    var guidance: String {
        switch source {
        case .bundled:
            "ChannelDeck is using the FFmpeg helper included in this app."
        case .homebrew:
            "ChannelDeck is using a Homebrew FFmpeg installation for development. A distributable build must include its own signed helper."
        case .custom:
            "ChannelDeck is using the configured FFmpeg executable."
        case nil:
            "Install FFmpeg with Homebrew for development, or use a ChannelDeck build that includes a signed FFmpeg helper."
        }
    }
}

/// Finds an application-bundled executable before falling back to the two
/// conventional Homebrew installation locations. No PATH lookup is used, so a
/// process cannot influence which executable ChannelDeck launches.
struct DefaultFFmpegExecutableLocator: FFmpegExecutableLocating {
    private struct Candidate: Sendable {
        let url: URL
        let source: FFmpegExecutableSource
    }

    private let candidates: [Candidate]

    init(
        bundle: Bundle = .main,
        systemPaths: [String] = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
    ) {
        var bundled: [URL] = []
        if let auxiliaryPath = bundle.path(forAuxiliaryExecutable: "ffmpeg") {
            bundled.append(URL(fileURLWithPath: auxiliaryPath))
        }
        if let executableDirectory = bundle.executableURL?.deletingLastPathComponent() {
            bundled.append(executableDirectory.appendingPathComponent("ffmpeg", isDirectory: false))
        }

        let system = systemPaths.map { URL(fileURLWithPath: $0, isDirectory: false) }
        let sourcedCandidates = bundled.map { Candidate(url: $0, source: .bundled) }
            + system.map { Candidate(url: $0, source: .homebrew) }
        candidates = Self.removingDuplicates(from: sourcedCandidates)
    }

    init(candidates: [URL]) {
        self.candidates = Self.removingDuplicates(
            from: candidates.map { Candidate(url: $0, source: .custom) }
        )
    }

    func executableURL() -> URL? {
        availability().executableURL
    }

    func availability() -> FFmpegExecutableAvailability {
        guard let candidate = candidates.first(where: { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: candidate.url.path)
        }) else {
            return FFmpegExecutableAvailability(executableURL: nil, source: nil)
        }
        return FFmpegExecutableAvailability(executableURL: candidate.url, source: candidate.source)
    }

    private static func removingDuplicates(from candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }
}

struct FFmpegHLSAudioTranscodeSession: Equatable, Sendable {
    /// A file-backed HLS manifest consumed only by ChannelDeck's local player.
    /// Source and relay URLs are deliberately not exposed by this descriptor.
    let playlistURL: URL
}

/// Receives opaque MPEG-TS bytes with pipe-backed backpressure. Implementations
/// must not retain source URLs or include media bytes in surfaced errors.
protocol MPEGTSByteConsuming: Sendable {
    func consume(_ bytes: Data) async throws
}

typealias MPEGTSFeeding = @Sendable (any MPEGTSByteConsuming) async throws -> Void

protocol VideoFrameRateInspecting: Sendable {
    func frameRate(forLocalSegment segmentURL: URL) async -> Double?
}

struct AVAssetVideoFrameRateInspector: VideoFrameRateInspecting {
    func frameRate(forLocalSegment segmentURL: URL) async -> Double? {
        let asset = AVURLAsset(url: segmentURL)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return nil
            }
            let nominalFrameRate = try await track.load(.nominalFrameRate)
            if nominalFrameRate.isFinite, nominalFrameRate > 0 {
                return Double(nominalFrameRate)
            }
            let minimumFrameDuration = try await track.load(.minFrameDuration)
            let seconds = minimumFrameDuration.seconds
            guard seconds.isFinite, seconds > 0 else { return nil }
            return 1 / seconds
        } catch {
            return nil
        }
    }
}

protocol HLSAudioTranscoding: Sendable {
    func start(relayURL: URL) async throws -> FFmpegHLSAudioTranscodeSession
    func startMPEGTS(feeding feed: @escaping MPEGTSFeeding) async throws
        -> FFmpegHLSAudioTranscodeSession
    func beginRecording(
        id: UUID,
        packageDirectory: URL,
        quality: BufferRecordingQuality
    ) async throws -> TimeInterval
    func finishRecording() async throws -> FFmpegLiveRecordingArtifact?
    func stop() async
}

struct FFmpegLiveRecordingArtifact: Equatable, Sendable {
    let id: UUID
    let packageDirectory: URL
    let playbackURL: URL
    let duration: TimeInterval
    let segmentCount: Int
    let quality: BufferRecordingQuality
}

enum FFmpegLiveRecordingError: Error, Equatable, LocalizedError, Sendable {
    case noActiveStream
    case alreadyRecording
    case invalidDestination
    case noMediaCaptured
    case couldNotFinalize

    var errorDescription: String? {
        switch self {
        case .noActiveStream:
            "Start a relayed channel before saving its live buffer."
        case .alreadyRecording:
            "ChannelDeck is already saving this live buffer."
        case .invalidDestination:
            "ChannelDeck could not create a private recording package."
        case .noMediaCaptured:
            "The live buffer did not contain a complete media segment to save."
        case .couldNotFinalize:
            "ChannelDeck could not finalize the recording."
        }
    }
}

extension HLSAudioTranscoding {
    func beginRecording(
        id: UUID,
        packageDirectory: URL,
        quality: BufferRecordingQuality
    ) async throws -> TimeInterval {
        throw FFmpegLiveRecordingError.noActiveStream
    }

    func finishRecording() async throws -> FFmpegLiveRecordingArtifact? { nil }
}

enum FFmpegProcessFailureReason: Equatable, Sendable {
    case missingRequiredStreams
    case incompatibleVideoCodec
    case cannotReachRelay
    case certificateRejected
    case relayRejectedRequest
    case incompleteInstallation
    case incompatibleBuild
    case permissionDenied
    case invalidMedia
    case inputStreamFailed
    case unexpectedExit

    var userMessage: String {
        switch self {
        case .missingRequiredStreams:
            "This channel does not contain both a video track and an audio track for conversion."
        case .incompatibleVideoCodec:
            "This channel is not H.264, so its video cannot be copied for AirPlay."
        case .cannotReachRelay:
            "FFmpeg could not connect to ChannelDeck's secure local relay. Check this Mac's DNS and network connection."
        case .certificateRejected:
            "FFmpeg could not verify ChannelDeck's secure relay certificate. Check the relay certificate and generated hostname."
        case .relayRejectedRequest:
            "ChannelDeck's secure local relay rejected FFmpeg's request. Set up the relay again and retry."
        case .incompleteInstallation:
            "FFmpeg could not load a required library. Reinstall FFmpeg or use a build with a complete bundled helper."
        case .incompatibleBuild:
            "This FFmpeg build does not include the HLS, H.264, and AAC features ChannelDeck needs."
        case .permissionDenied:
            "FFmpeg was denied access to its private working directory. Check the app's permissions and retry."
        case .invalidMedia:
            "FFmpeg could not read this channel's media format."
        case .inputStreamFailed:
            "ChannelDeck could not continue reading this channel's live transport stream."
        case .unexpectedExit:
            "FFmpeg stopped before preparing an AirPlay-compatible stream."
        }
    }
}

enum FFmpegHLSAudioTranscoderError: Error, Equatable, LocalizedError, Sendable {
    case ffmpegNotFound
    case invalidRelayURL
    case temporaryDirectoryUnavailable
    case processCouldNotStart
    case processFailed(FFmpegProcessFailureReason)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "FFmpeg was not found. Install it with Homebrew for development, or use a ChannelDeck build with a bundled helper."
        case .invalidRelayURL:
            "The secure local relay address is invalid."
        case .temporaryDirectoryUnavailable:
            "A private transcoding directory could not be created."
        case .processCouldNotStart:
            "FFmpeg was found, but macOS could not launch it. Check its execute permission and architecture, or reinstall it."
        case let .processFailed(reason):
            reason.userMessage
        case .startupTimedOut:
            "Preparing the AirPlay-compatible stream took too long."
        }
    }
}

/// Owns one FFmpeg live-HLS process. The input must be ChannelDeck's opaque
/// HTTPS relay URL; provider URLs must never cross this boundary.
actor FFmpegHLSAudioTranscoder: HLSAudioTranscoding {
    static let defaultStartupTimeout: Duration = .seconds(40)
    static let hlsSegmentDurationSeconds = 4
    static let liveBufferSegmentCount = 75
    static let liveBufferDeleteThreshold = 15

    private enum VideoMode: Sendable, Equatable {
        case streamCopy
        case h264VideoToolbox
    }

    private enum TranscodeAttemptError: Error {
        case videoRequiresTranscode
    }

    private enum MPEGTSInputPipeError: Error, Sendable {
        case closed
        case writeFailed
    }

    private final class MPEGTSInputStatus: @unchecked Sendable {
        enum State: Equatable, Sendable {
            case feeding
            case finished
            case sourceFailed
            case cancelled
            case pipeClosed
        }

        private let lock = NSLock()
        private var state: State = .feeding

        func set(_ newValue: State) {
            lock.lock()
            state = newValue
            lock.unlock()
        }

        func value() -> State {
            lock.lock()
            let result = state
            lock.unlock()
            return result
        }
    }

    private final class PipeMPEGTSByteConsumer: MPEGTSByteConsuming, @unchecked Sendable {
        private let lock = NSLock()
        private let writer: FileHandle
        private var isClosed = false

        init(writer: FileHandle) {
            self.writer = writer
            // A receiver/process failure should become a regular write error,
            // never a SIGPIPE that terminates ChannelDeck itself.
            _ = Darwin.fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        func consume(_ bytes: Data) async throws {
            guard !bytes.isEmpty else { return }
            try Task.checkCancellation()
            try write(bytes)
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            isClosed = true
            try? writer.close()
        }

        private func write(_ bytes: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else {
                throw MPEGTSInputPipeError.closed
            }
            do {
                try writer.write(contentsOf: bytes)
            } catch {
                throw MPEGTSInputPipeError.writeFailed
            }
        }

        deinit {
            close()
        }
    }

    private struct RawInputRuntime: Sendable {
        let consumer: PipeMPEGTSByteConsumer
        let status: MPEGTSInputStatus
        let feederTask: Task<Void, Never>

        init(consumer: PipeMPEGTSByteConsumer, feed: @escaping MPEGTSFeeding) {
            let status = MPEGTSInputStatus()
            self.consumer = consumer
            self.status = status
            feederTask = Task {
                do {
                    try await feed(consumer)
                    status.set(.finished)
                } catch is CancellationError {
                    status.set(.cancelled)
                } catch is MPEGTSInputPipeError {
                    // Usually means FFmpeg closed stdin after reporting a more
                    // specific media/process error on its diagnostic pipe.
                    status.set(.pipeClosed)
                } catch {
                    // Never retain or surface the upstream error: it may contain
                    // a credential-bearing provider URL.
                    status.set(.sourceFailed)
                }
                consumer.close()
            }
        }

        func cancel() {
            feederTask.cancel()
        }
    }

    private enum ProcessInput: Sendable {
        case relay(URL)
        case mpegTS(MPEGTSFeeding)
    }

    private final class DiagnosticBuffer: @unchecked Sendable {
        private static let maximumBytes = 32 * 1_024
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            let remaining = Self.maximumBytes - bytes.count
            guard remaining > 0 else { return }
            bytes.append(data.prefix(remaining))
        }

        func text() -> String {
            lock.lock()
            let snapshot = bytes
            lock.unlock()
            return String(decoding: snapshot, as: UTF8.self)
        }
    }

    private final class OwnedProcess: @unchecked Sendable {
        let process: Process
        let directory: URL
        private let diagnosticPipe: Pipe
        private let diagnosticBuffer: DiagnosticBuffer
        private let rawInput: RawInputRuntime?

        init(
            process: Process,
            directory: URL,
            diagnosticPipe: Pipe,
            diagnosticBuffer: DiagnosticBuffer,
            rawInput: RawInputRuntime?
        ) {
            self.process = process
            self.directory = directory
            self.diagnosticPipe = diagnosticPipe
            self.diagnosticBuffer = diagnosticBuffer
            self.rawInput = rawInput
        }

        var inputStatus: MPEGTSInputStatus.State? { rawInput?.status.value() }

        func cancelInput() {
            rawInput?.cancel()
        }

        func closeInput() {
            rawInput?.consumer.close()
        }

        func diagnosticText() -> String {
            diagnosticBuffer.text()
        }

        func finishDiagnostics() -> String {
            let reader = diagnosticPipe.fileHandleForReading
            reader.readabilityHandler = nil
            if let remainder = try? reader.readToEnd() {
                diagnosticBuffer.append(remainder)
            }
            return diagnosticBuffer.text()
        }

        deinit {
            diagnosticPipe.fileHandleForReading.readabilityHandler = nil
            try? diagnosticPipe.fileHandleForReading.close()
            try? diagnosticPipe.fileHandleForWriting.close()
            rawInput?.cancel()
            if process.isRunning {
                process.terminate()
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            rawInput?.consumer.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct ActiveTranscode: Sendable {
        let id: UUID
        let ownedProcess: OwnedProcess
        let generatedMasterPlaylistURL: URL
        let receiverMasterPlaylistURL: URL
        let mediaPlaylistURL: URL
        let sourceMediaPlaylistURL: URL
    }

    private struct CapturedRecordingSegment: Sendable {
        let fileName: String
        let metadataLines: [String]
        let duration: TimeInterval
    }

    private struct ActiveRecording: Sendable {
        let id: UUID
        let packageDirectory: URL
        let playbackURL: URL
        let quality: BufferRecordingQuality
        var segments: [CapturedRecordingSegment] = []
        var capturedNames: Set<String> = []
        var writeFailed = false
    }

    private let locator: any FFmpegExecutableLocating
    private let startupTimeout: Duration
    private let streamCopyProbeTimeout: Duration
    private let temporaryRoot: URL
    private let frameRateInspector: any VideoFrameRateInspecting
    private let clock = ContinuousClock()
    private var active: ActiveTranscode?
    private var activeRecording: ActiveRecording?
    private var recordingMonitorTask: Task<Void, Never>?

    init(
        locator: any FFmpegExecutableLocating = DefaultFFmpegExecutableLocator(),
        startupTimeout: Duration = FFmpegHLSAudioTranscoder.defaultStartupTimeout,
        streamCopyProbeTimeout: Duration = .seconds(12),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        frameRateInspector: any VideoFrameRateInspecting = AVAssetVideoFrameRateInspector()
    ) {
        precondition(startupTimeout > .zero)
        precondition(streamCopyProbeTimeout > .zero)
        self.locator = locator
        self.startupTimeout = startupTimeout
        self.streamCopyProbeTimeout = streamCopyProbeTimeout
        self.temporaryRoot = temporaryRoot
        self.frameRateInspector = frameRateInspector
    }

    /// Starts a rolling HLS rendition that copies H.264 video and converts the
    /// first audio stream to broadly compatible AAC-LC stereo at 48 kHz.
    func start(relayURL: URL) async throws -> FFmpegHLSAudioTranscodeSession {
        guard Self.isOpaqueRelayURL(relayURL) else {
            throw FFmpegHLSAudioTranscoderError.invalidRelayURL
        }
        return try await startWithAutomaticVideoCompatibility(input: .relay(relayURL))
    }

    /// Starts the same rolling rendition from a raw MPEG-TS byte source. The
    /// feeder sees only a backpressured sink; its source URL is never passed to
    /// FFmpeg or retained by the transcoder.
    func startMPEGTS(feeding feed: @escaping MPEGTSFeeding) async throws
        -> FFmpegHLSAudioTranscodeSession {
        try await startWithAutomaticVideoCompatibility(input: .mpegTS(feed))
    }

    private func startWithAutomaticVideoCompatibility(
        input: ProcessInput
    ) async throws -> FFmpegHLSAudioTranscodeSession {
        do {
            return try await startAttempt(input: input, videoMode: .streamCopy)
        } catch TranscodeAttemptError.videoRequiresTranscode {
            try Task.checkCancellation()
            return try await startAttempt(input: input, videoMode: .h264VideoToolbox)
        } catch let error as FFmpegHLSAudioTranscoderError
            where error == .processFailed(.incompatibleVideoCodec) {
            try Task.checkCancellation()
            return try await startAttempt(input: input, videoMode: .h264VideoToolbox)
        }
    }

    private func startAttempt(
        input: ProcessInput,
        videoMode: VideoMode
    ) async throws -> FFmpegHLSAudioTranscodeSession {
        guard let executableURL = locator.executableURL() else {
            throw FFmpegHLSAudioTranscoderError.ffmpegNotFound
        }

        await stop()
        try Task.checkCancellation()

        let directory = try makeOwnedTemporaryDirectory()
        let generatedMasterPlaylistURL = directory
            .appendingPathComponent("ffmpeg-index.m3u8", isDirectory: false)
        let receiverMasterPlaylistURL = directory
            .appendingPathComponent("index.m3u8", isDirectory: false)
        let mediaPlaylistURL = directory.appendingPathComponent("media-0.m3u8", isDirectory: false)
        let sourceMediaPlaylistURL = directory.appendingPathComponent(
            "source.m3u8",
            isDirectory: false
        )
        let mediaPlaylistTemplate = directory
            .appendingPathComponent("media-%v.m3u8", isDirectory: false)
            .path
        let segmentTemplate = directory
            .appendingPathComponent("segment-%v-%09d.ts", isDirectory: false)
            .path
        let sourceSegmentTemplate = directory
            .appendingPathComponent("source-segment-%09d.ts", isDirectory: false)
            .path

        let process = Process()
        let diagnosticPipe = Pipe()
        let inputPipe: Pipe?
        switch input {
        case .relay:
            inputPipe = nil
        case .mpegTS:
            inputPipe = Pipe()
        }
        let diagnosticBuffer = DiagnosticBuffer()
        diagnosticPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                diagnosticBuffer.append(data)
            }
        }
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnosticPipe
        // Do not forward Cloudflare credentials, proxy settings, or developer
        // shell state to the helper. All paths and network inputs are explicit.
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        process.arguments = Self.arguments(
            input: input,
            videoMode: videoMode,
            sourceSegmentTemplate: sourceSegmentTemplate,
            sourceMediaPlaylist: sourceMediaPlaylistURL.path,
            segmentTemplate: segmentTemplate,
            mediaPlaylistTemplate: mediaPlaylistTemplate
        )

        do {
            try process.run()
            try? inputPipe?.fileHandleForReading.close()
            try? diagnosticPipe.fileHandleForWriting.close()
        } catch {
            diagnosticPipe.fileHandleForReading.readabilityHandler = nil
            try? diagnosticPipe.fileHandleForReading.close()
            try? diagnosticPipe.fileHandleForWriting.close()
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: directory)
            throw FFmpegHLSAudioTranscoderError.processCouldNotStart
        }

        let rawInput: RawInputRuntime?
        switch input {
        case .relay:
            rawInput = nil
        case let .mpegTS(feed):
            guard let inputPipe else {
                preconditionFailure("MPEG-TS input pipe was not created")
            }
            rawInput = RawInputRuntime(
                consumer: PipeMPEGTSByteConsumer(writer: inputPipe.fileHandleForWriting),
                feed: feed
            )
        }

        let id = UUID()
        active = ActiveTranscode(
            id: id,
            ownedProcess: OwnedProcess(
                process: process,
                directory: directory,
                diagnosticPipe: diagnosticPipe,
                diagnosticBuffer: diagnosticBuffer,
                rawInput: rawInput
            ),
            generatedMasterPlaylistURL: generatedMasterPlaylistURL,
            receiverMasterPlaylistURL: receiverMasterPlaylistURL,
            mediaPlaylistURL: mediaPlaylistURL,
            sourceMediaPlaylistURL: sourceMediaPlaylistURL
        )

        do {
            return try await withTaskCancellationHandler {
                try await waitUntilReady(id: id, videoMode: videoMode)
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        } catch {
            await cancel(id: id)
            throw error
        }
    }

    func stop() async {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        if let activeRecording {
            try? FileManager.default.removeItem(at: activeRecording.packageDirectory)
            self.activeRecording = nil
        }
        guard let active else { return }
        self.active = nil
        await terminate(active.ownedProcess)
        try? FileManager.default.removeItem(at: active.ownedProcess.directory)
    }

    /// Starts retaining the selected already-generated HLS window without
    /// opening a second provider connection. Complete MPEG-TS segments are
    /// appended to a native local media file as they arrive, so finalization is
    /// constant-time even after a long recording.
    func beginRecording(
        id: UUID,
        packageDirectory: URL,
        quality: BufferRecordingQuality
    ) async throws -> TimeInterval {
        guard active != nil else {
            throw FFmpegLiveRecordingError.noActiveStream
        }
        guard activeRecording == nil else {
            throw FFmpegLiveRecordingError.alreadyRecording
        }
        guard Self.isValidRecordingDestination(packageDirectory, id: id) else {
            throw FFmpegLiveRecordingError.invalidDestination
        }

        do {
            try FileManager.default.createDirectory(
                at: packageDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw FFmpegLiveRecordingError.invalidDestination
        }

        let playbackURL = packageDirectory.appendingPathComponent(
            RecordingStorage.mediaFileName,
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: playbackURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            try? FileManager.default.removeItem(at: packageDirectory)
            throw FFmpegLiveRecordingError.invalidDestination
        }

        activeRecording = ActiveRecording(
            id: id,
            packageDirectory: packageDirectory,
            playbackURL: playbackURL,
            quality: quality
        )

        // Compatibility output is known to be ready when playback starts, but
        // a copied source-video rendition may be finishing its first GOP. Give
        // it a short bounded opportunity to publish so the UI can immediately
        // report the adopted history instead of appearing to start at zero.
        let initialCaptureDeadline = clock.now.advanced(by: .seconds(5))
        while clock.now < initialCaptureDeadline {
            captureRecordingSegments()
            if let recording = activeRecording,
               recording.writeFailed || !recording.segments.isEmpty {
                break
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: packageDirectory)
                activeRecording = nil
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let activeRecording, !activeRecording.writeFailed else {
            try? FileManager.default.removeItem(at: packageDirectory)
            self.activeRecording = nil
            throw FFmpegLiveRecordingError.couldNotFinalize
        }
        recordingMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { break }
                await self?.captureRecordingSegments()
            }
        }
        return activeRecording.segments.reduce(0) { $0 + $1.duration }
    }

    /// Seals the retained live segments as a self-contained MPEG-TS recording.
    /// The active live transcode continues uninterrupted for local playback and
    /// AirPlay until the caller switches channel.
    func finishRecording() async throws -> FFmpegLiveRecordingArtifact? {
        guard activeRecording != nil else { return nil }
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        captureRecordingSegments()

        guard let recording = activeRecording else { return nil }
        activeRecording = nil
        guard !recording.segments.isEmpty, !recording.writeFailed else {
            try? FileManager.default.removeItem(at: recording.packageDirectory)
            throw recording.segments.isEmpty
                ? FFmpegLiveRecordingError.noMediaCaptured
                : FFmpegLiveRecordingError.couldNotFinalize
        }

        do {
            let handle = try FileHandle(forWritingTo: recording.playbackURL)
            try handle.synchronize()
            try handle.close()
            let attributes = try FileManager.default.attributesOfItem(
                atPath: recording.playbackURL.path
            )
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                throw FFmpegLiveRecordingError.couldNotFinalize
            }
        } catch {
            try? FileManager.default.removeItem(at: recording.packageDirectory)
            throw FFmpegLiveRecordingError.couldNotFinalize
        }

        return FFmpegLiveRecordingArtifact(
            id: recording.id,
            packageDirectory: recording.packageDirectory,
            playbackURL: recording.playbackURL,
            duration: recording.segments.reduce(0) { $0 + $1.duration },
            segmentCount: recording.segments.count,
            quality: recording.quality
        )
    }

    private func captureRecordingSegments() {
        guard let active,
              var recording = activeRecording else { return }

        let mediaPlaylistURL: URL
        let segmentPrefix: String
        switch recording.quality {
        case .sourceVideo:
            mediaPlaylistURL = active.sourceMediaPlaylistURL
            segmentPrefix = "source-segment-"
        case .compatible:
            mediaPlaylistURL = active.mediaPlaylistURL
            segmentPrefix = "segment-0-"
        }
        guard let media = Self.readManifest(at: mediaPlaylistURL) else { return }

        let parsed = Self.completedRecordingSegments(in: media, segmentPrefix: segmentPrefix)
        for segment in parsed.segments where !recording.capturedNames.contains(segment.fileName) {
            let source = active.ownedProcess.directory
                .appendingPathComponent(segment.fileName, isDirectory: false)
            guard Self.isSafeGeneratedSegmentName(
                    segment.fileName,
                    prefix: segmentPrefix
                  ),
                  source.standardizedFileURL.deletingLastPathComponent()
                    == active.ownedProcess.directory.standardizedFileURL,
                  FileManager.default.fileExists(atPath: source.path) else { continue }
            do {
                try Self.appendContents(of: source, to: recording.playbackURL)
                recording.segments.append(segment)
                recording.capturedNames.insert(segment.fileName)
            } catch {
                recording.writeFailed = true
                break
            }
        }
        activeRecording = recording
    }

    private static func appendContents(of source: URL, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        let originalLength = try writer.seekToEnd()

        do {
            while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
                try writer.write(contentsOf: data)
            }
        } catch {
            try? writer.truncate(atOffset: originalLength)
            throw error
        }
    }

    private static func completedRecordingSegments(
        in playlist: String,
        segmentPrefix: String = "segment-0-"
    ) -> (targetDuration: Int, segments: [CapturedRecordingSegment]) {
        let lines = playlist
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var targetDuration = 12
        var pendingProgramDateTime: String?
        var pendingDiscontinuity = false
        var pendingDuration: TimeInterval?
        var segments: [CapturedRecordingSegment] = []

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:"),
               let value = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)),
               (1 ... 120).contains(value) {
                targetDuration = value
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:"), line.count <= 128 {
                pendingProgramDateTime = line
            } else if line.hasPrefix("#EXTINF:") {
                let text = line
                    .dropFirst("#EXTINF:".count)
                    .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
                if let value = Double(text), value.isFinite, value > 0, value <= 120 {
                    pendingDuration = value
                } else {
                    pendingDuration = nil
                }
            } else if !line.isEmpty, !line.hasPrefix("#") {
                defer {
                    pendingProgramDateTime = nil
                    pendingDiscontinuity = false
                    pendingDuration = nil
                }
                guard let duration = pendingDuration,
                      isSafeGeneratedSegmentName(line, prefix: segmentPrefix) else { continue }
                var metadata: [String] = []
                if pendingDiscontinuity { metadata.append("#EXT-X-DISCONTINUITY") }
                if let pendingProgramDateTime { metadata.append(pendingProgramDateTime) }
                metadata.append("#EXTINF:\(String(format: "%.6f", duration)),")
                segments.append(
                    CapturedRecordingSegment(
                        fileName: line,
                        metadataLines: metadata,
                        duration: duration
                    )
                )
            }
        }
        return (max(1, targetDuration), segments)
    }

    private static func isSafeGeneratedSegmentName(
        _ value: String,
        prefix: String = "segment-0-"
    ) -> Bool {
        guard prefix == "segment-0-" || prefix == "source-segment-",
              value.hasPrefix(prefix), value.hasSuffix(".ts") else { return false }
        let sequence = value
            .dropFirst(prefix.count)
            .dropLast(".ts".count)
        return sequence.count == 9
            && sequence.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isValidRecordingDestination(_ url: URL, id: UUID) -> Bool {
        guard url.isFileURL,
              url.pathExtension == "channeldeckrecording",
              url.lastPathComponent.caseInsensitiveCompare(
                "\(id.uuidString).channeldeckrecording"
              ) == .orderedSame,
              url.standardizedFileURL == url,
              !FileManager.default.fileExists(atPath: url.path) else { return false }
        var isDirectory: ObjCBool = false
        let parent = url.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func waitUntilReady(
        id: UUID,
        videoMode: VideoMode
    ) async throws -> FFmpegHLSAudioTranscodeSession {
        let deadline = clock.now.advanced(by: startupTimeout)
        let streamCopyProbeDeadline = clock.now.advanced(by: streamCopyProbeTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            guard let active, active.id == id else {
                throw CancellationError()
            }
            if active.ownedProcess.inputStatus == .sourceFailed {
                throw FFmpegHLSAudioTranscoderError.processFailed(.inputStreamFailed)
            }
            if videoMode == .streamCopy,
               Self.inputRequiresH264Transcode(
                   fromFFmpegDiagnostics: active.ownedProcess.diagnosticText()
               ) {
                throw TranscodeAttemptError.videoRequiresTranscode
            }
            guard active.ownedProcess.process.isRunning else {
                let diagnostics = active.ownedProcess.finishDiagnostics()
                throw FFmpegHLSAudioTranscoderError.processFailed(
                    Self.failureReason(for: diagnostics)
                )
            }
            if Self.manifestsAreReady(
                masterPlaylistURL: active.generatedMasterPlaylistURL,
                mediaPlaylistURL: active.mediaPlaylistURL,
                within: active.ownedProcess.directory,
                minimumSegmentCount: videoMode == .h264VideoToolbox ? 3 : 6
            ) {
                let minimumSegmentCount = videoMode == .h264VideoToolbox ? 3 : 6
                let published = await Self.publishReceiverMaster(
                    generatedMasterPlaylistURL: active.generatedMasterPlaylistURL,
                    receiverMasterPlaylistURL: active.receiverMasterPlaylistURL,
                    mediaPlaylistURL: active.mediaPlaylistURL,
                    within: active.ownedProcess.directory,
                    minimumSegmentCount: minimumSegmentCount,
                    frameRateInspector: frameRateInspector,
                    ffmpegDiagnostics: active.ownedProcess.diagnosticText()
                )
                if published {
                    return FFmpegHLSAudioTranscodeSession(
                        playlistURL: active.receiverMasterPlaylistURL
                    )
                }
            }
            if videoMode == .streamCopy,
               clock.now >= streamCopyProbeDeadline,
               Self.readManifest(at: active.mediaPlaylistURL) == nil {
                // Some IPTV H.264 feeds use UHD or very long source GOPs. A
                // copied HLS rendition cannot publish until its next keyframe,
                // which can exceed the whole AirPlay startup budget. Restart
                // with VideoToolbox so ChannelDeck owns a four-second GOP.
                throw TranscodeAttemptError.videoRequiresTranscode
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let active, active.id == id {
            let reason = Self.failureReason(for: active.ownedProcess.diagnosticText())
            if reason != .unexpectedExit {
                throw FFmpegHLSAudioTranscoderError.processFailed(reason)
            }
        }
        throw FFmpegHLSAudioTranscoderError.startupTimedOut
    }

    /// Converts private FFmpeg output into a fixed diagnostic category. The raw
    /// text may contain relay tokens, hostnames, and local paths and must never
    /// leave this type.
    static func failureReason(for diagnostics: String) -> FFmpegProcessFailureReason {
        let value = diagnostics.lowercased()

        if value.contains("library not loaded")
            || value.contains("image not found")
            || value.contains("dyld:") {
            return .incompleteInstallation
        }
        if value.contains("unknown encoder")
            || value.contains("encoder not found")
            || value.contains("unknown format")
            || value.contains("requested output format")
            || value.contains("unrecognized option")
            || value.contains("bitstream filter not found") {
            return .incompatibleBuild
        }
        if value.contains("matches no streams")
            || value.contains("does not contain any stream") {
            return .missingRequiredStreams
        }
        if value.contains("not supported by the bitstream filter")
            || (value.contains("h264_mp4toannexb") && value.contains("not supported")) {
            return .incompatibleVideoCodec
        }
        if value.contains("certificate verify failed")
            || value.contains("unable to verify")
            || value.contains("certificate validation failed") {
            return .certificateRejected
        }
        if value.contains("server returned 4")
            || value.contains("http error 4")
            || value.contains("http error 5") {
            return .relayRejectedRequest
        }
        if value.contains("connection refused")
            || value.contains("connection timed out")
            || value.contains("network is unreachable")
            || value.contains("could not resolve hostname")
            || value.contains("failed to resolve hostname") {
            return .cannotReachRelay
        }
        if value.contains("permission denied")
            || value.contains("operation not permitted") {
            return .permissionDenied
        }
        if value.contains("invalid data found when processing input")
            || value.contains("could not find codec parameters") {
            return .invalidMedia
        }
        return .unexpectedExit
    }

    private func cancel(id: UUID) async {
        guard let active, active.id == id else { return }
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        if let activeRecording {
            try? FileManager.default.removeItem(at: activeRecording.packageDirectory)
            self.activeRecording = nil
        }
        self.active = nil
        await terminate(active.ownedProcess)
        try? FileManager.default.removeItem(at: active.ownedProcess.directory)
    }

    private func terminate(_ ownedProcess: OwnedProcess) async {
        let process = ownedProcess.process
        ownedProcess.cancelInput()
        if process.isRunning {
            process.terminate()

            let gracefulDeadline = clock.now.advanced(by: .seconds(3))
            while process.isRunning, clock.now < gracefulDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                let killDeadline = clock.now.advanced(by: .seconds(1))
                while process.isRunning, clock.now < killDeadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        // Closing after the child exits also unblocks any in-flight pipe write.
        ownedProcess.closeInput()

        // A codec/long-GOP fallback reuses the feed closure immediately. Give
        // the cancelled reader a bounded opportunity to close its provider
        // connection first; otherwise single-connection IPTV origins can
        // accept the replacement request but leave it permanently silent.
        let inputShutdownDeadline = clock.now.advanced(by: .seconds(2))
        while ownedProcess.inputStatus == .feeding, clock.now < inputShutdownDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeOwnedTemporaryDirectory() throws -> URL {
        let templatePath = temporaryRoot
            .appendingPathComponent("ChannelDeck-ffmpeg.XXXXXX", isDirectory: false)
            .path
        var template = Array(templatePath.utf8CString)
        let createdPath: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress, Darwin.mkdtemp(baseAddress) != nil else {
                return nil
            }
            return String(cString: baseAddress)
        }
        guard let createdPath else {
            throw FFmpegHLSAudioTranscoderError.temporaryDirectoryUnavailable
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
    }

    private static func arguments(
        input: ProcessInput,
        videoMode: VideoMode,
        sourceSegmentTemplate: String,
        sourceMediaPlaylist: String,
        segmentTemplate: String,
        mediaPlaylistTemplate: String
    ) -> [String] {
        let hardwareInputArguments = videoMode == .h264VideoToolbox
            ? ["-hwaccel", "videotoolbox"]
            : []
        let inputArguments: [String]
        switch input {
        case let .relay(relayURL):
            inputArguments = ["-re"] + hardwareInputArguments + ["-i", relayURL.absoluteString]
        case .mpegTS:
            inputArguments = ["-f", "mpegts", "-re"]
                + hardwareInputArguments
                + ["-i", "pipe:0"]
        }

        let videoArguments: [String]
        switch videoMode {
        case .streamCopy:
            videoArguments = [
                "-c:v", "copy",
                "-bsf:v", "h264_mp4toannexb",
            ]
        case .h264VideoToolbox:
            videoArguments = [
                // UHD services commonly use 10-bit HEVC in MPEG-TS. Convert
                // non-H.264 and oversized H.264 inputs with Apple's hardware
                // encoder, and cap both dimensions at 1080p for broad AirPlay
                // compatibility and predictable LAN bandwidth. The encoder
                // otherwise preserves BT.2020/PQ tags from HDR inputs even
                // after converting them to 8-bit H.264. AirPlay receivers can
                // accept the playlist and then reject that contradictory
                // H.264/SDR rendition after its first segment, so publish one
                // internally consistent BT.709 limited-range stream.
                "-vf", "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,format=nv12,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                "-c:v", "h264_videotoolbox",
                "-profile:v", "high",
                "-level:v", "4.2",
                "-color_range", "tv",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                "-b:v", "10000k",
                "-maxrate:v", "12000k",
                "-bufsize:v", "20000k",
                "-allow_sw", "1",
                "-realtime", "1",
                "-force_key_frames", "expr:gte(t,n_forced*4)",
            ]
        }

        let sourceRecordingOutputArguments = [
            // Maintain an original-resolution rolling video rendition from the
            // same input. Save Buffer can then retain UHD/HDR history without
            // opening a second provider connection. AAC audio keeps the saved
            // MPEG-TS file broadly playable by AVFoundation.
            "-map", "0:v:0",
            "-map", "0:a:0",
            "-sn",
            "-dn",
            "-c:v", "copy",
            "-c:a", "aac",
            "-ac", "2",
            "-ar", "48000",
            "-b:a", "192k",
            "-f", "hls",
            "-hls_segment_type", "mpegts",
            "-hls_time", String(hlsSegmentDurationSeconds),
            "-hls_list_size", String(liveBufferSegmentCount),
            "-hls_delete_threshold", String(liveBufferDeleteThreshold),
            "-hls_flags", "delete_segments+independent_segments+temp_file+omit_endlist+program_date_time",
            "-hls_segment_filename", sourceSegmentTemplate,
            sourceMediaPlaylist,
        ]

        let compatibilityOutputArguments = [
            "-map", "0:v:0",
            "-map", "0:a:0",
            "-sn",
            "-dn",
        ] + videoArguments + [
            "-c:a", "aac",
            "-ac", "2",
            "-ar", "48000",
            "-b:a", "160k",
            "-var_stream_map", "v:0,a:0",
            "-f", "hls",
            "-hls_segment_type", "mpegts",
            "-hls_time", String(hlsSegmentDurationSeconds),
            // Seventy-five four-second entries expose five minutes of live
            // history to AVPlayer. A further minute remains on disk so an
            // AirPlay receiver that is finishing an older segment does not
            // race deletion as the playlist window advances.
            "-hls_list_size", String(liveBufferSegmentCount),
            "-hls_delete_threshold", String(liveBufferDeleteThreshold),
            "-hls_flags", "delete_segments+independent_segments+temp_file+omit_endlist+program_date_time",
            // This remains internal: stream-copy inputs often make FFmpeg emit
            // an unusably small bandwidth. ChannelDeck publishes index.m3u8.
            "-master_pl_name", "ffmpeg-index.m3u8",
            "-master_pl_publish_rate", "1",
            "-hls_segment_filename", segmentTemplate,
            mediaPlaylistTemplate,
        ]

        return [
            "-hide_banner",
            // Stream metadata near the beginning of the private diagnostic
            // buffer supplies FFmpeg's exact input rate. AVAsset is only a
            // fallback when that metadata is absent. This text is never
            // logged or surfaced.
            "-loglevel", "info",
            "-nostats",
            "-nostdin",
            "-y",
        ] + inputArguments + sourceRecordingOutputArguments + compatibilityOutputArguments
    }

    /// Returns only the normalized codec identifier from FFmpeg's private
    /// stream description. The diagnostic itself can contain relay tokens and
    /// must never leave this type.
    static func inputVideoCodec(fromFFmpegDiagnostics diagnostics: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"Video:\s*([A-Za-z0-9_]+)"#,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: diagnostics,
            range: NSRange(diagnostics.startIndex..., in: diagnostics)
        ),
        let codecRange = Range(match.range(at: 1), in: diagnostics) else {
            return nil
        }
        return diagnostics[codecRange].lowercased()
    }

    /// Extracts bounded dimensions from FFmpeg's first video stream line. UHD
    /// H.264 still needs conversion: copying it preserves receiver-incompatible
    /// dimensions and leaves segment creation dependent on the provider's long
    /// GOP cadence.
    static func inputVideoResolution(
        fromFFmpegDiagnostics diagnostics: String
    ) -> (width: Int, height: Int)? {
        guard let expression = try? NSRegularExpression(
            pattern: #"Video:[^\r\n]*?,\s*([0-9]{2,5})x([0-9]{2,5})(?:[\s,\[]|$)"#,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: diagnostics,
            range: NSRange(diagnostics.startIndex..., in: diagnostics)
        ),
        match.numberOfRanges == 3,
        let widthRange = Range(match.range(at: 1), in: diagnostics),
        let heightRange = Range(match.range(at: 2), in: diagnostics),
        let width = Int(diagnostics[widthRange]),
        let height = Int(diagnostics[heightRange]),
        (16 ... 16_384).contains(width),
        (16 ... 16_384).contains(height) else {
            return nil
        }
        return (width, height)
    }

    static func inputRequiresH264Transcode(fromFFmpegDiagnostics diagnostics: String) -> Bool {
        guard let codec = inputVideoCodec(fromFFmpegDiagnostics: diagnostics) else {
            return false
        }
        if codec != "h264" { return true }
        guard let resolution = inputVideoResolution(fromFFmpegDiagnostics: diagnostics) else {
            return false
        }
        return resolution.width > 1_920 || resolution.height > 1_080
    }

    private static func isOpaqueRelayURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.port != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 3,
              components[0] == "s",
              components[2] == "index.m3u8" else {
            return false
        }
        let token = components[1]
        return (32 ... 256).contains(token.count)
            && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func manifestsAreReady(
        masterPlaylistURL: URL,
        mediaPlaylistURL: URL,
        within directory: URL,
        minimumSegmentCount: Int
    ) -> Bool {
        precondition(minimumSegmentCount >= 3)
        guard let master = readManifest(at: masterPlaylistURL),
              master.hasPrefix("#EXTM3U") else {
            return false
        }

        let masterLines = master
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let streamInformation = masterLines.filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        let childReferences = masterLines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard streamInformation.count == 1,
              streamInformation[0].contains("CODECS=\""),
              streamInformation[0].contains("RESOLUTION="),
              childReferences == ["media-0.m3u8"],
              mediaPlaylistURL.lastPathComponent == childReferences[0],
              let media = readManifest(at: mediaPlaylistURL),
              media.hasPrefix("#EXTM3U") else {
            return false
        }

        let lines = media
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let extentCount = lines.filter { $0.hasPrefix("#EXTINF:") }.count
        let programDateTimeCount = lines.filter { $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") }.count
        let segmentReferences = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard extentCount >= minimumSegmentCount,
              programDateTimeCount >= extentCount,
              segmentReferences.count == extentCount else {
            return false
        }

        let standardizedDirectory = directory.standardizedFileURL
        return segmentReferences.allSatisfy { value in
            guard let reference = URL(string: value, relativeTo: mediaPlaylistURL)?.absoluteURL,
                  reference.isFileURL else {
                return false
            }
            let standardizedReference = reference.standardizedFileURL
            let filename = standardizedReference.lastPathComponent
            let sequence = filename
                .dropFirst("segment-0-".count)
                .dropLast(".ts".count)
            guard standardizedReference.deletingLastPathComponent() == standardizedDirectory,
                  standardizedReference.pathExtension.lowercased() == "ts",
                  filename.hasPrefix("segment-0-"),
                  filename.hasSuffix(".ts"),
                  sequence.count == 9,
                  sequence.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let segmentAttributes = try? FileManager.default.attributesOfItem(
                      atPath: standardizedReference.path
                  ),
                  let size = segmentAttributes[.size] as? NSNumber,
                  size.intValue > 0 else {
                return false
            }
            return true
        }
    }

    /// FFmpeg's HLS muxer uses only known codec bit rates when constructing its
    /// master. With `-c:v copy`, that often produces an audio-only BANDWIDTH.
    /// Publish a separate, stable master from measured complete segments so a
    /// later FFmpeg refresh can never restore the invalid value.
    private static func publishReceiverMaster(
        generatedMasterPlaylistURL: URL,
        receiverMasterPlaylistURL: URL,
        mediaPlaylistURL: URL,
        within directory: URL,
        minimumSegmentCount: Int,
        frameRateInspector: any VideoFrameRateInspecting,
        ffmpegDiagnostics: String
    ) async -> Bool {
        guard let generatedMaster = readManifest(at: generatedMasterPlaylistURL),
              let measurements = segmentBitrateMeasurements(
                  mediaPlaylistURL: mediaPlaylistURL,
                  within: directory,
                  minimumSegmentCount: minimumSegmentCount
              ),
              let resolution = resolution(in: generatedMaster),
              let codecs = codecs(in: generatedMaster) else {
            return false
        }
        let diagnosticFrameRate = frameRate(fromFFmpegDiagnostics: ffmpegDiagnostics)
        let inspectedFrameRate: Double?
        if diagnosticFrameRate == nil {
            inspectedFrameRate = await frameRateInspector.frameRate(
                forLocalSegment: measurements.firstSegmentURL
            )
        } else {
            inspectedFrameRate = nil
        }
        guard let measuredFrameRate = diagnosticFrameRate ?? inspectedFrameRate,
        measuredFrameRate.isFinite,
        (1 ... 240).contains(measuredFrameRate) else {
            return false
        }
        let frameRate = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            measuredFrameRate
        )

        let resolutionFloor: Double
        if resolution.width >= 3_840 || resolution.height >= 2_160 {
            resolutionFloor = 25_000_000
        } else if resolution.width >= 2_560 || resolution.height >= 1_440 {
            resolutionFloor = 15_000_000
        } else if resolution.width >= 1_920 || resolution.height >= 1_080 {
            resolutionFloor = 8_000_000
        } else if resolution.width >= 1_280 || resolution.height >= 720 {
            resolutionFloor = 5_000_000
        } else {
            resolutionFloor = 2_500_000
        }

        let advertisedBandwidth = Int(ceil(Swift.min(
            100_000_000,
            Swift.max(resolutionFloor, measurements.peakBitsPerSecond * 1.25)
        )))

        // Do not carry arbitrary attributes from the generated file. For this
        // single-variant local relay, using the conservative peak declaration
        // as the average also satisfies Apple's required attribute without
        // understating a long-running variable-bitrate stream.
        let published = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=\(advertisedBandwidth),AVERAGE-BANDWIDTH=\(advertisedBandwidth),RESOLUTION=\(resolution.width)x\(resolution.height),FRAME-RATE=\(frameRate),CODECS="\(codecs)",VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE
        media-0.m3u8

        """
        do {
            try Data(published.utf8).write(to: receiverMasterPlaylistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func segmentBitrateMeasurements(
        mediaPlaylistURL: URL,
        within directory: URL,
        minimumSegmentCount: Int
    ) -> (
        peakBitsPerSecond: Double,
        averageBitsPerSecond: Double,
        firstSegmentURL: URL
    )? {
        precondition(minimumSegmentCount >= 3)
        guard let media = readManifest(at: mediaPlaylistURL) else { return nil }
        let lines = media
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let standardizedDirectory = directory.standardizedFileURL
        var pendingDuration: Double?
        var segmentMeasurements: [(url: URL, bytes: Int64, duration: Double)] = []

        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                let durationText = line
                    .dropFirst("#EXTINF:".count)
                    .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard let duration = Double(durationText), duration.isFinite, duration > 0 else {
                    return nil
                }
                pendingDuration = duration
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let duration = pendingDuration,
                  let reference = URL(string: line, relativeTo: mediaPlaylistURL)?.absoluteURL,
                  reference.isFileURL else {
                return nil
            }
            let standardizedReference = reference.standardizedFileURL
            guard standardizedReference.deletingLastPathComponent() == standardizedDirectory,
                  let attributes = try? FileManager.default.attributesOfItem(
                      atPath: standardizedReference.path
                  ),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0 else {
                return nil
            }
            segmentMeasurements.append((standardizedReference, size.int64Value, duration))
            pendingDuration = nil
        }

        guard segmentMeasurements.count >= minimumSegmentCount else { return nil }
        let peak = segmentMeasurements
            .map { Double($0.bytes) * 8 / $0.duration }
            .max() ?? 0
        let totalBytes = segmentMeasurements.reduce(Int64(0)) { partial, item in
            partial + item.bytes
        }
        let totalDuration = segmentMeasurements.reduce(0.0) { partial, item in
            partial + item.duration
        }
        guard peak.isFinite, peak > 0, totalDuration > 0 else { return nil }
        guard let firstSegmentURL = segmentMeasurements.first?.url else { return nil }
        return (peak, Double(totalBytes) * 8 / totalDuration, firstSegmentURL)
    }

    private static func resolution(in master: String) -> (width: Int, height: Int)? {
        guard let marker = master.range(of: "RESOLUTION=") else { return nil }
        let value = master[marker.upperBound...]
            .prefix { character in
                character.isASCII && (character.isNumber || character == "x")
            }
        let components = value.split(separator: "x", maxSplits: 1)
        guard components.count == 2,
              let width = Int(components[0]), width > 0,
              let height = Int(components[1]), height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func codecs(in master: String) -> String? {
        guard let marker = master.range(of: "CODECS=\"") else { return nil }
        let suffix = master[marker.upperBound...]
        guard let closingQuote = suffix.firstIndex(of: "\"") else { return nil }
        let value = String(suffix[..<closingQuote])
        guard !value.isEmpty,
              value.count <= 128,
              value.allSatisfy({ character in
                  character.isASCII
                      && (character.isLetter
                          || character.isNumber
                          || character == "."
                          || character == ","
                          || character == "-"
                          || character == "_")
              }) else {
            return nil
        }
        return value
    }

    /// Extracts only a numeric rate from FFmpeg's private stream description.
    /// The caller never receives the diagnostic string, which may contain an
    /// opaque relay token or local path.
    static func frameRate(fromFFmpegDiagnostics diagnostics: String) -> Double? {
        let pattern = #"(?i)([0-9]+(?:\.[0-9]+)?)\s+fps(?:\s|,)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: diagnostics,
                  range: NSRange(diagnostics.startIndex..., in: diagnostics)
              ),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: diagnostics),
              let value = Double(diagnostics[valueRange]),
              value.isFinite,
              (1 ... 240).contains(value) else {
            return nil
        }
        return value
    }

    private static func readManifest(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= 1_024 * 1_024,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

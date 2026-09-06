import AVFoundation
import AVKit
import Foundation
import Network
import XCTest
@testable import ChannelDeck

/// This exercises actual video rendering, not just a published playlist or a
/// player whose audio clock advances while its picture remains black.
final class LiveHLSFirstFrameTests: XCTestCase {
    @MainActor
    func testQuickLocalHLSDisplaysAFrameBeforeReceiverReadinessWithoutSeeking() async throws {
        try await runFirstFrameFixture(openGOP: false)
    }

    @MainActor
    func testOpenGOPStartupFallsBackToCleanVideoAndKeepsOriginalRecording() async throws {
        try await runFirstFrameFixture(openGOP: true)
    }

    @MainActor
    private func runFirstFrameFixture(openGOP: Bool) async throws {
        guard let ffmpeg = DefaultFFmpegExecutableLocator().executableURL() else {
            throw XCTSkip("A local FFmpeg installation is required for the first-frame integration test.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("channeldeck-first-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = directory.appendingPathComponent("fixture.ts")
        try await Task.detached {
            try await LiveHLSFirstFrameTests.generateFixture(
                ffmpeg: ffmpeg, destination: fixture, openGOP: openGOP
            )
        }.value
        let sourceStartup = try await Task.detached {
            try H264TransportStreamStartupInspector().inspect(segmentURL: fixture)
        }.value
        XCTAssertEqual(sourceStartup, openGOP ? .nonIDRStart : .cleanIDR,
            "The open-GOP fixture must reproduce joining at a recovery I-frame, not an IDR.")
        let input = FirstFrameMPEGTSInput(bytes: try Data(contentsOf: fixture))
        let transcoder = FFmpegHLSAudioTranscoder(startupTimeout: .seconds(30), temporaryRoot: directory)
        let clock = ContinuousClock()
        let started = clock.now
        var server: FirstFrameHTTPServer?
        var readiness: Task<ContinuousClock.Instant, Error>?
        let controller = PlayerController()
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.player = controller.player
        view.controlsStyle = .none
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer {
            controller.stop()
            view.player = nil
            window.close()
        }

        do {
            let local = try await transcoder.startMPEGTSForLocalPlayback { consumer in
                try await input.feed(consumer)
            }
            let localReady = clock.now
            let outputDirectory = local.playlistURL.deletingLastPathComponent()
            let initialMedia = try String(
                contentsOf: outputDirectory.appendingPathComponent("media-0.m3u8"), encoding: .utf8
            )
            XCTAssertEqual(initialMedia.components(separatedBy: "#EXTINF:").count - 1, 1)
            XCTAssertTrue(try HLSMediaPlaylistNormalizer().normalize(initialMedia)
                .contains("#EXT-X-TARGETDURATION:12"))
            let initialSegmentName = try XCTUnwrap(initialMedia.split(whereSeparator: \.isNewline)
                .first { !$0.hasPrefix("#") && !$0.isEmpty })
            let compatibleSegment = outputDirectory.appendingPathComponent(String(initialSegmentName))
            let compatibleStartup = try await Task.detached {
                try H264TransportStreamStartupInspector().inspect(segmentURL: compatibleSegment)
            }.value
            XCTAssertEqual(compatibleStartup, .cleanIDR,
                "Only an independently decodable first segment may reach the player.")
            let expectedFeedCount = openGOP ? 2 : 1
            let startsBeforeAirPlay = await input.feedCount
            XCTAssertEqual(startsBeforeAirPlay, expectedFeedCount,
                "Open-GOP input must take the real automatic copy-to-VideoToolbox retry path.")

            let http = try FirstFrameHTTPServer(directory: outputDirectory)
            server = http
            let url = try await http.start()
            let receiverReadiness = Task {
                try await transcoder.waitForAirPlayReadiness()
                return clock.now
            }
            readiness = receiverReadiness
            controller.play(
                url: url, channelName: "Synthetic first-frame fixture",
                allowsExternalPlayback: false, preferQuickStart: true
            )
            let item = try XCTUnwrap(controller.player.currentItem)
            let deadline = clock.now.advanced(by: .seconds(30))
            while !view.isReadyForDisplay, clock.now < deadline {
                if item.status == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let firstFrame = view.isReadyForDisplay ? clock.now : nil
            if firstFrame != nil {
                controller.reportVideoDisplayReady(true, for: item)
            }
            if openGOP {
                let recordingID = UUID()
                let recordingDirectory = directory.appendingPathComponent(
                    "\(recordingID.uuidString.lowercased()).channeldeckrecording", isDirectory: true
                )
                let adoptedDuration = try await transcoder.beginRecording(
                    id: recordingID, packageDirectory: recordingDirectory, quality: .sourceVideo
                )
                XCTAssertGreaterThan(adoptedDuration, 0)
            }
            let receiverReady = try await receiverReadiness.value
            XCTAssertNotNil(firstFrame, "Clean local HLS must produce a displayed video frame without seeking.")
            if let firstFrame {
                print("Synthetic HLS (open GOP: \(openGOP)): local manifest \(started.duration(to: localReady)), first displayed frame \(started.duration(to: firstFrame)), receiver ready \(started.duration(to: receiverReady))")
                XCTAssertLessThan(firstFrame, receiverReady,
                    "Quick local playback must show a picture before the receiver buffer has matured.")
            }
            XCTAssertTrue(controller.player.currentItem === item)
            controller.setExternalPlaybackAllowed(true)
            XCTAssertTrue(controller.player.currentItem === item,
                "Making AirPlay available must retain the already-rendering player item.")
            let feedCount = await input.feedCount
            XCTAssertEqual(feedCount, expectedFeedCount,
                "Preparing AirPlay must not open an additional source connection after local publication.")
            if openGOP {
                let finished = try await transcoder.finishRecording()
                let recording = try XCTUnwrap(finished)
                XCTAssertEqual(recording.quality, .sourceVideo)
                let recordedURL = recording.playbackURL
                let recordingStartup = try await Task.detached {
                    try H264TransportStreamStartupInspector().inspect(segmentURL: recordedURL)
                }.value
                XCTAssertEqual(recordingStartup, .nonIDRStart,
                    "Original recording must preserve the original video, not replace it with compatibility output.")
                let originalSlice = try Self.firstVideoSlice(in: Data(contentsOf: fixture))
                let recordedSlice = try Self.firstVideoSlice(in: Data(contentsOf: recordedURL))
                XCTAssertEqual(originalSlice, recordedSlice,
                    "Original recording must retain the source's compressed picture bytes exactly.")
            }
            controller.stop()
            await http.stop()
            await transcoder.stop()
        } catch {
            readiness?.cancel()
            controller.stop()
            await server?.stop()
            await transcoder.stop()
            throw error
        }
    }

    private static func generateFixture(ffmpeg: URL, destination: URL, openGOP: Bool) async throws {
        let process = Process()
        process.executableURL = ffmpeg
        let common = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
            "-t", "44", "-c:v", "libx264",
        ]
        let closedGOP = [
            "-preset", "ultrafast",
            "-g", "100", "-keyint_min", "100", "-sc_threshold", "0",
            "-flags", "+cgop", "-c:a", "aac", "-f", "mpegts", destination.path,
        ]
        let root = destination.deletingLastPathComponent()
        let generatedPlaylist = root.appendingPathComponent("generated.m3u8")
        let openGOPArguments = [
            "-preset", "veryfast",
            "-x264-params", "open-gop=1:keyint=100:min-keyint=100:scenecut=0:repeat-headers=1",
            "-bf", "3", "-c:a", "aac", "-f", "hls", "-hls_time", "4", "-hls_list_size", "0",
            "-hls_segment_filename", root.appendingPathComponent("generated-%03d.ts").path,
            generatedPlaylist.path,
        ]
        process.arguments = common + (openGOP ? openGOPArguments : closedGOP)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while process.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw FirstFrameFixtureError.mediaGenerationFailed
        }
        if openGOP {
            // The first encoded GOP is always closed. Begin at the next HLS
            // segment to reproduce joining an open-GOP provider mid-broadcast.
            // FFmpeg places PAT/PMT and repeated SPS/PPS in those TS segments.
            let playlist = try String(contentsOf: generatedPlaylist, encoding: .utf8)
            let segmentNames = playlist.split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            guard segmentNames.count >= 8 else { throw FirstFrameFixtureError.mediaGenerationFailed }
            var source = Data()
            for segment in segmentNames.dropFirst() {
                guard segment.range(of: #"^generated-[0-9]{3}\.ts$"#, options: .regularExpression) != nil else {
                    throw FirstFrameFixtureError.mediaGenerationFailed
                }
                source.append(try Data(contentsOf: root.appendingPathComponent(String(segment))))
            }
            try source.write(to: destination, options: .atomic)
        }
    }

    /// Extract the first compressed slice from our known FFmpeg-generated AVC
    /// PID. This fixture-only comparison ignores remuxed timestamps/AAC and
    /// proves the original recording's video was copied, not re-encoded.
    private static func firstVideoSlice(in transport: Data) throws -> Data {
        let bytes = Array(transport.prefix(2 * 1_024 * 1_024))
        var elementary: [UInt8] = []
        guard bytes.count >= 188 else { throw FirstFrameFixtureError.mediaGenerationFailed }
        for offset in stride(from: 0, through: bytes.count - 188, by: 188) {
            guard bytes[offset] == 0x47 else { throw FirstFrameFixtureError.mediaGenerationFailed }
            let pid = Int(bytes[offset + 1] & 31) << 8 | Int(bytes[offset + 2])
            guard pid == 256 else { continue } // FFmpeg's default first video PID.
            let control = (bytes[offset + 3] >> 4) & 3
            guard control & 1 != 0 else { continue }
            var payload = offset + 4
            if control & 2 != 0 { payload += 1 + Int(bytes[payload]) }
            guard payload < offset + 188 else { continue }
            if bytes[offset + 1] & 0x40 != 0 {
                guard payload + 9 <= offset + 188 else { throw FirstFrameFixtureError.mediaGenerationFailed }
                payload += 9 + Int(bytes[payload + 8])
            }
            guard payload <= offset + 188 else { throw FirstFrameFixtureError.mediaGenerationFailed }
            elementary.append(contentsOf: bytes[payload ..< offset + 188])
        }
        var nalStart: Int?
        var offset = 0
        while offset + 4 < elementary.count {
            let prefixLength: Int
            if elementary[offset ..< offset + 4].elementsEqual([0, 0, 0, 1]) { prefixLength = 4 }
            else if elementary[offset ..< offset + 3].elementsEqual([0, 0, 1]) { prefixLength = 3 }
            else { offset += 1; continue }
            if let nalStart { return Data(elementary[nalStart ..< offset]) }
            let header = offset + prefixLength
            if (1 ... 5).contains(elementary[header] & 31) { nalStart = header }
            offset = header + 1
        }
        throw FirstFrameFixtureError.mediaGenerationFailed
    }
}

private actor FirstFrameMPEGTSInput {
    let bytes: Data
    private(set) var feedCount = 0

    init(bytes: Data) { self.bytes = bytes }

    func feed(_ consumer: any MPEGTSByteConsuming) async throws {
        feedCount += 1
        for offset in stride(from: 0, to: bytes.count, by: 188 * 128) {
            try Task.checkCancellation()
            try await consumer.consume(bytes.subdata(in: offset ..< min(offset + 188 * 128, bytes.count)))
        }
    }
}

private enum FirstFrameFixtureError: Error {
    case mediaGenerationFailed
    case listenerUnavailable
}

/// Test-only server: an ephemeral loopback port, a fixed generated-file
/// allowlist, and bounded request/response bodies. It never accesses a provider.
private actor FirstFrameHTTPServer {
    private let directory: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChannelDeckTests.FirstFrameHTTPServer")
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]

    init(directory: URL) throws {
        self.directory = directory
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: queue)
        }
    }

    func stop() {
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/index.m3u8") else {
                startContinuation?.resume(throwing: FirstFrameFixtureError.listenerUnavailable)
                startContinuation = nil
                return
            }
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case let .failed(error), let .waiting(error):
            startContinuation?.resume(throwing: error)
            startContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task {
                await self?.received(connection, id: id, accumulated: accumulated,
                    data: data, complete: complete, failed: error != nil)
            }
        }
    }

    private func received(
        _ connection: NWConnection, id: UUID, accumulated: Data,
        data: Data?, complete: Bool, failed: Bool
    ) {
        var request = accumulated
        if let data { request.append(data) }
        guard request.count <= 16_384, !failed else { close(id); return }
        guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
            if complete { close(id) } else { receive(connection, id: id, accumulated: request) }
            return
        }
        let response = response(to: request)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func response(to request: Data) -> Data {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let fields = lines.first?.split(separator: " ") ?? []
        guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else {
            return encodedResponse(status: "400 Bad Request", body: Data())
        }
        let name = String(fields[1].dropFirst())
        guard fields[1].hasPrefix("/"),
              name == "index.m3u8" || name == "media-0.m3u8"
                || name.range(of: #"^segment-0-[0-9]{9}\.ts$"#, options: .regularExpression) != nil else {
            return encodedResponse(status: "404 Not Found", body: Data())
        }
        let url = directory.appendingPathComponent(name)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 8 * 1_024 * 1_024,
              var data = try? Data(contentsOf: url) else {
            return encodedResponse(status: "404 Not Found", body: Data())
        }
        if name == "media-0.m3u8" {
            guard let normalized = try? HLSMediaPlaylistNormalizer()
                .normalize(String(decoding: data, as: UTF8.self)) else {
                return encodedResponse(status: "503 Service Unavailable", body: Data())
            }
            data = Data(normalized.utf8)
        }
        let contentType = name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"
        let headers = ["Content-Type: \(contentType)", "Cache-Control: no-store"]
        return encodedResponse(status: "200 OK", headers: headers, body: data, head: fields[0] == "HEAD")
    }

    private func encodedResponse(
        status: String, headers: [String] = [], body: Data, head: Bool = false
    ) -> Data {
        let header = (["HTTP/1.1 \(status)", "Connection: close", "Content-Length: \(body.count)"] + headers)
            .joined(separator: "\r\n") + "\r\n\r\n"
        return Data(header.utf8) + (head ? Data() : body)
    }
}

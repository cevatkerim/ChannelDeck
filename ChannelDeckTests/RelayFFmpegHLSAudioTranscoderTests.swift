import Foundation
import XCTest
@testable import ChannelDeck

final class RelayFFmpegHLSAudioTranscoderTests: XCTestCase {
    func testNonIDRCopiedVideoIsEncodedBeforeLocalPublication() async throws {
        let root = try makeTemporaryDirectory(named: "non-idr-start")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        let hardwareOutput = Self.successfulOutputScript.replacingOccurrences(
            of: "'transport-stream-%s'", with: "'clean-idr-%s'"
        )
        let script = "#!/bin/sh\narguments=\" $* \"\ncase \"$arguments\" in\n*\" -c:v h264_videotoolbox \"*)\n"
            + hardwareOutput + "\n;;\n*)\n" + Self.successfulOutputScript + "\n;;\nesac\n"
        try writeExecutable(script, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable), startupTimeout: .seconds(3),
            temporaryRoot: root, frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: ModeAwareStartupInspector()
        )
        let session = try await transcoder.startForLocalPlayback(relayURL: Self.relayURL)
        let directory = session.playlistURL.deletingLastPathComponent()
        let first = directory.appendingPathComponent("segment-0-000000000.ts")
        XCTAssertEqual(try ModeAwareStartupInspector().inspect(segmentURL: first), .cleanIDR)
        let original = try String(contentsOf: directory.appendingPathComponent("source-segment-000000000.ts"), encoding: .utf8)
        XCTAssertEqual(original, "source-transport-stream-0", "Decoder compatibility must not alter original recording output")
        try await transcoder.waitForAirPlayReadiness()
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        await transcoder.stop()
    }

    func testUnusableHardwareStartFailsWithoutPublishingBlackPlayback() async throws {
        let root = try makeTemporaryDirectory(named: "invalid-encoded-start")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable("#!/bin/sh\narguments=\" $* \"\n" + Self.successfulOutputScript, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable), startupTimeout: .seconds(3),
            temporaryRoot: root, frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .missingParameterSets)
        )
        await XCTAssertThrowsTranscoderError(.processFailed(.incompatibleVideoCodec)) {
            _ = try await transcoder.startForLocalPlayback(relayURL: Self.relayURL)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("ChannelDeck-ffmpeg.") })
        await transcoder.stop()
    }

    func testRealFFmpegStartsLocalPlaybackBeforeReceiverBufferWithoutSecondInput() async throws {
        guard let ffmpeg = DefaultFFmpegExecutableLocator().executableURL() else {
            throw XCTSkip("A local FFmpeg installation is required for the synthetic media integration test.")
        }
        let root = try makeTemporaryDirectory(named: "synthetic-live-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.ts")
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
            "-t", "32", "-c:v", "libx264", "-preset", "ultrafast",
            "-g", "100", "-keyint_min", "100", "-sc_threshold", "0",
            "-c:a", "aac", "-f", "mpegts", fixture.path,
        ]
        generator.standardInput = FileHandle.nullDevice
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run()
        defer { if generator.isRunning { generator.terminate() } }
        let clock = ContinuousClock()
        let generationDeadline = clock.now.advanced(by: .seconds(15))
        while generator.isRunning, clock.now < generationDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !generator.isRunning, generator.terminationStatus == 0 else {
            XCTFail("Could not generate local synthetic video")
            return
        }
        let input = SyntheticMPEGTSInput(bytes: try Data(contentsOf: fixture))
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: ffmpeg), temporaryRoot: root
        )
        let start = clock.now
        do {
            let local = try await transcoder.startMPEGTSForLocalPlayback { consumer in
                try await input.feed(consumer)
            }
            let localElapsed = start.duration(to: clock.now)
            let mediaURL = local.playlistURL.deletingLastPathComponent().appendingPathComponent("media-0.m3u8")
            let earlyMedia = try String(contentsOf: mediaURL, encoding: .utf8)
            XCTAssertLessThan(earlyMedia.components(separatedBy: "#EXTINF:").count - 1, 6)
            XCTAssertNoThrow(try HLSMediaPlaylistNormalizer().normalize(earlyMedia))
            try await transcoder.waitForAirPlayReadiness()
            let readyMedia = try String(contentsOf: mediaURL, encoding: .utf8)
            XCTAssertGreaterThanOrEqual(readyMedia.components(separatedBy: "#EXTINF:").count - 1, 6)
            let feedCount = await input.feedCount
            XCTAssertEqual(feedCount, 1)
            print("Synthetic local playback ready after \(localElapsed); AirPlay after \(start.duration(to: clock.now))")
            await transcoder.stop()
        } catch {
            await transcoder.stop()
            throw error
        }
    }

    func testLocalPlaybackPublishesOneSegmentThenMaturesSameRecordingSession() async throws {
        let root = try makeTemporaryDirectory(named: "early-playback")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.oneSegmentFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable), startupTimeout: .seconds(3),
            temporaryRoot: root, frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )
        let session = try await transcoder.startForLocalPlayback(relayURL: Self.relayURL)
        let directory = session.playlistURL.deletingLastPathComponent()
        let mediaURL = directory.appendingPathComponent("media-0.m3u8")
        var media = try String(contentsOf: mediaURL, encoding: .utf8)
        XCTAssertEqual(media.components(separatedBy: "#EXTINF:").count - 1, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))

        let recordingID = UUID()
        let package = root.appendingPathComponent("\(recordingID.uuidString.lowercased()).channeldeckrecording")
        let captured = try await transcoder.beginRecording(id: recordingID, packageDirectory: package, quality: .compatible)
        XCTAssertEqual(captured, 4)

        let readiness = Task { try await transcoder.waitForAirPlayReadiness() }
        for index in 1 ... 5 {
            let name = String(format: "segment-0-%09d.ts", index)
            try Data("transport-stream-\(index)".utf8).write(to: directory.appendingPathComponent(name))
            media += "#EXT-X-PROGRAM-DATE-TIME:2026-09-04T00:00:20Z\n#EXTINF:4.0,\n\(name)\n"
        }
        try Data(media.utf8).write(to: mediaURL, options: .atomic)
        try await readiness.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        let recording = try await transcoder.finishRecording()
        XCTAssertEqual(recording?.id, recordingID)
        XCTAssertEqual(recording?.duration, 24)
        XCTAssertEqual(recording?.segmentCount, 6)
        await transcoder.stop()
    }

    func testAirPlayTimeoutDoesNotDeleteEarlyLocalPlaybackOrRecording() async throws {
        let root = try makeTemporaryDirectory(named: "early-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.oneSegmentFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            // This tests receiver timeout retention, not the speed of launching
            // a shell fixture on a busy test machine.
            locator: FixedFFmpegLocator(url: executable), startupTimeout: .seconds(2),
            temporaryRoot: root, frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )
        let session = try await transcoder.startForLocalPlayback(relayURL: Self.relayURL)
        let id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString.lowercased()).channeldeckrecording")
        _ = try await transcoder.beginRecording(id: id, packageDirectory: package, quality: .sourceVideo)
        await XCTAssertThrowsTranscoderError(.startupTimedOut) {
            try await transcoder.waitForAirPlayReadiness()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        let recording = try await transcoder.finishRecording()
        XCTAssertEqual(recording?.id, id)
        XCTAssertEqual(recording?.duration, 4)
        await transcoder.stop()
    }

    func testCancellingBackgroundReadinessLeavesLocalFilesAlive() async throws {
        let root = try makeTemporaryDirectory(named: "early-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.oneSegmentFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable), startupTimeout: .seconds(3),
            temporaryRoot: root, frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )
        let session = try await transcoder.startForLocalPlayback(relayURL: Self.relayURL)
        let readiness = Task { try await transcoder.waitForAirPlayReadiness() }
        readiness.cancel()
        do {
            try await readiness.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(type(of: error))") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        await transcoder.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.playlistURL.path))
    }

    func testOversizedCopiedSegmentRestartsBeforePublishingUnplayableLocalManifest() async throws {
        let root = try makeTemporaryDirectory(named: "oversized-segment")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        let script = "#!/bin/sh\narguments=\" $* \"\ncase \"$arguments\" in\n*\" -c:v h264_videotoolbox \"*)\n"
            + Self.successfulOutputScript + "\n;;\n*)\n"
            + Self.successfulOutputScript.replacingOccurrences(of: "#EXTINF:4.0,", with: "#EXTINF:16.0,")
            + "\n;;\nesac\n"
        try writeExecutable(script, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable), startupTimeout: .seconds(3),
            temporaryRoot: root, frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )
        let session = try await transcoder.startForLocalPlayback(relayURL: Self.relayURL)
        let media = try String(contentsOf: session.playlistURL.deletingLastPathComponent().appendingPathComponent("media-0.m3u8"), encoding: .utf8)
        XCTAssertFalse(media.contains("#EXTINF:16.0,"))
        XCTAssertNoThrow(try HLSMediaPlaylistNormalizer().normalize(media))
        await transcoder.stop()
    }

    private static let oneSegmentFakeFFmpeg = "#!/bin/sh\narguments=\" $* \"\nsegment_limit=1\n" + successfulOutputScript

    func testDefaultStartupTimeoutAllowsSixPacedSegmentsWithinCoordinatorDeadline() {
        XCTAssertEqual(FFmpegHLSAudioTranscoder.defaultStartupTimeout, .seconds(40))
        XCTAssertLessThan(FFmpegHLSAudioTranscoder.defaultStartupTimeout, .seconds(45))
    }

    func testRollingBufferRetainsFiveMinutesPlusOneMinuteDeletionGrace() {
        XCTAssertEqual(
            FFmpegHLSAudioTranscoder.hlsSegmentDurationSeconds
                * FFmpegHLSAudioTranscoder.liveBufferSegmentCount,
            5 * 60
        )
        XCTAssertEqual(
            FFmpegHLSAudioTranscoder.hlsSegmentDurationSeconds
                * FFmpegHLSAudioTranscoder.liveBufferDeleteThreshold,
            60
        )
    }

    func testLocatorUsesTheFirstExecutableCandidate() throws {
        let root = try makeTemporaryDirectory(named: "locator")
        defer { try? FileManager.default.removeItem(at: root) }
        let nonExecutable = root.appendingPathComponent("bundled-ffmpeg")
        let bundled = root.appendingPathComponent("Contents-MacOS-ffmpeg")
        let fallback = root.appendingPathComponent("homebrew-ffmpeg")
        try Data().write(to: nonExecutable)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: bundled)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: fallback)

        let locator = DefaultFFmpegExecutableLocator(
            candidates: [nonExecutable, bundled, fallback]
        )

        XCTAssertEqual(locator.executableURL(), bundled)
        XCTAssertEqual(locator.availability().source, .custom)
        XCTAssertEqual(locator.availability().statusTitle, "Available · Custom")
    }

    func testMissingAvailabilityHasActionableSafeGuidance() {
        let availability = DefaultFFmpegExecutableLocator(candidates: []).availability()

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.statusTitle, "FFmpeg not found")
        XCTAssertTrue(availability.guidance.contains("Install FFmpeg"))
        XCTAssertFalse(availability.guidance.contains("/Users/"))
    }

    func testRejectsProviderURLBeforeLaunchingAProcess() async {
        let transcoder = FFmpegHLSAudioTranscoder(locator: FixedFFmpegLocator(url: nil))

        await XCTAssertThrowsTranscoderError(.invalidRelayURL) {
            _ = try await transcoder.start(
                relayURL: URL(string: "https://provider.example/live/channel.m3u8")!
            )
        }
    }

    func testWaitsForAppleCompatibleMasterAndSixSegmentsThenRemovesOwnedDirectory() async throws {
        let root = try makeTemporaryDirectory(named: "success")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.successfulFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 59.94),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )

        let session = try await transcoder.start(relayURL: Self.relayURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        XCTAssertEqual(session.playlistURL.lastPathComponent, "index.m3u8")
        let outputDirectory = session.playlistURL.deletingLastPathComponent()
        let master = try String(contentsOf: session.playlistURL, encoding: .utf8)
        let media = try String(
            contentsOf: outputDirectory.appendingPathComponent("media-0.m3u8"),
            encoding: .utf8
        )
        XCTAssertTrue(master.contains("BANDWIDTH=8000000"))
        XCTAssertTrue(master.contains("AVERAGE-BANDWIDTH=8000000"))
        XCTAssertTrue(master.contains("RESOLUTION=1920x1080"))
        XCTAssertTrue(master.contains("FRAME-RATE=25.000"))
        XCTAssertFalse(master.contains("FRAME-RATE=59.940"))
        XCTAssertTrue(master.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        XCTAssertTrue(master.contains("VIDEO-RANGE=SDR"))
        XCTAssertTrue(master.contains("CLOSED-CAPTIONS=NONE"))
        XCTAssertTrue(master.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(master.contains("media-0.m3u8"))
        XCTAssertEqual(media.components(separatedBy: "#EXT-X-PROGRAM-DATE-TIME:").count - 1, 6)
        let segments = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("segment-0-") }
        XCTAssertEqual(segments.count, 6)

        let generatedMaster = outputDirectory.appendingPathComponent("ffmpeg-index.m3u8")
        try Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia-0.m3u8\n".utf8)
            .write(to: generatedMaster, options: .atomic)
        XCTAssertEqual(
            try String(contentsOf: session.playlistURL, encoding: .utf8),
            master,
            "FFmpeg's internal refresh must not overwrite the public master"
        )

        await transcoder.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testRecordingRetainsCurrentWindowAndNewSegmentsAsNativeMediaFile() async throws {
        let root = try makeTemporaryDirectory(named: "recording")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.successfulFakeFFmpeg, to: executable)
        let recordingRoot = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: false)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )
        let session = try await transcoder.start(relayURL: Self.relayURL)
        let liveDirectory = session.playlistURL.deletingLastPathComponent()
        let recordingID = UUID()
        let package = recordingRoot.appendingPathComponent(
            "\(recordingID.uuidString.lowercased()).channeldeckrecording",
            isDirectory: true
        )

        do {
            _ = try await transcoder.beginRecording(
                id: recordingID,
                packageDirectory: recordingRoot.appendingPathComponent("../outside"),
                quality: .compatible
            )
            XCTFail("Expected unsafe recording destination to be rejected")
        } catch let error as FFmpegLiveRecordingError {
            XCTAssertEqual(error, .invalidDestination)
        }

        let initialDuration = try await transcoder.beginRecording(
            id: recordingID,
            packageDirectory: package,
            quality: .compatible
        )
        XCTAssertEqual(initialDuration, 24, accuracy: 0.001)
        let nextSegmentName = "segment-0-000000006.ts"
        try Data("transport-stream-6".utf8).write(
            to: liveDirectory.appendingPathComponent(nextSegmentName)
        )
        let liveMediaURL = liveDirectory.appendingPathComponent("media-0.m3u8")
        var updatedLiveMedia = try String(contentsOf: liveMediaURL, encoding: .utf8)
        updatedLiveMedia += "#EXT-X-PROGRAM-DATE-TIME:2026-09-04T00:00:06Z\n#EXTINF:4.0,\n\(nextSegmentName)\n"
        try Data(updatedLiveMedia.utf8).write(to: liveMediaURL, options: .atomic)
        try await Task.sleep(for: .seconds(1))
        let finishedRecording = try await transcoder.finishRecording()
        let artifact = try XCTUnwrap(finishedRecording)

        XCTAssertEqual(artifact.id, recordingID)
        XCTAssertEqual(artifact.duration, 28, accuracy: 0.001)
        XCTAssertEqual(artifact.segmentCount, 7)
        XCTAssertEqual(artifact.playbackURL.lastPathComponent, RecordingStorage.mediaFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.playbackURL.path))
        XCTAssertEqual(
            try String(contentsOf: artifact.playbackURL, encoding: .utf8),
            (0 ... 6).map { "transport-stream-\($0)" }.joined()
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: package,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ts" }.count,
            1
        )

        await transcoder.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: artifact.playbackURL.path),
            "Finalized recordings must outlive the rolling transcode directory"
        )
    }

    func testSourceQualityRecordingRetainsOriginalResolutionWindow() async throws {
        let root = try makeTemporaryDirectory(named: "source-recording")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.successfulFakeFFmpeg, to: executable)
        let recordingRoot = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: false)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )
        _ = try await transcoder.start(relayURL: Self.relayURL)
        let recordingID = UUID()
        let package = recordingRoot.appendingPathComponent(
            "\(recordingID.uuidString.lowercased()).channeldeckrecording",
            isDirectory: true
        )

        let initialDuration = try await transcoder.beginRecording(
            id: recordingID,
            packageDirectory: package,
            quality: .sourceVideo
        )
        let finishedRecording = try await transcoder.finishRecording()
        let artifact = try XCTUnwrap(finishedRecording)

        XCTAssertEqual(initialDuration, 24, accuracy: 0.001)
        XCTAssertEqual(artifact.quality, .sourceVideo)
        XCTAssertEqual(artifact.duration, 24, accuracy: 0.001)
        XCTAssertEqual(
            try String(contentsOf: artifact.playbackURL, encoding: .utf8),
            (0 ... 5).map { "source-transport-stream-\($0)" }.joined()
        )
    }

    func testRecordingRejectsMissingStreamAndUnsafeDestination() async throws {
        let root = try makeTemporaryDirectory(named: "recording-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: nil),
            temporaryRoot: root
        )
        let id = UUID()

        do {
            _ = try await transcoder.beginRecording(
                id: id,
                packageDirectory: root.appendingPathComponent("../outside"),
                quality: .sourceVideo
            )
            XCTFail("Expected a missing-stream error")
        } catch let error as FFmpegLiveRecordingError {
            XCTAssertEqual(error, .noActiveStream)
        }
    }

    func testHEVCInputAutomaticallyRestartsWithVideoToolboxH264Output() async throws {
        let root = try makeTemporaryDirectory(named: "hevc-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.automaticHEVCFallbackFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 50),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )

        let session = try await transcoder.start(relayURL: Self.relayURL)
        let master = try String(contentsOf: session.playlistURL, encoding: .utf8)

        XCTAssertTrue(master.contains("RESOLUTION=1920x1080"))
        XCTAssertTrue(master.contains("FRAME-RATE=25.000"))
        XCTAssertTrue(master.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        let segments = try FileManager.default.contentsOfDirectory(
            at: session.playlistURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("segment-0-") }
        XCTAssertEqual(segments.count, 3)
        await transcoder.stop()
    }

    func testH264LongGOPAutomaticallyRestartsWhenCopyProducesNoSegment() async throws {
        let root = try makeTemporaryDirectory(named: "h264-long-gop-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.automaticH264LongGOPFallbackFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            streamCopyProbeTimeout: .milliseconds(150),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )

        let session = try await transcoder.start(relayURL: Self.relayURL)
        let master = try String(contentsOf: session.playlistURL, encoding: .utf8)

        XCTAssertTrue(master.contains("RESOLUTION=1920x1080"))
        XCTAssertTrue(master.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        let segments = try FileManager.default.contentsOfDirectory(
            at: session.playlistURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("segment-0-") }
        XCTAssertEqual(segments.count, 3)
        await transcoder.stop()
    }

    func testVideoOnlyInputAutomaticallyRestartsWithSilentAAC() async throws {
        let root = try makeTemporaryDirectory(named: "video-only-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.automaticSilentAudioFallbackFakeFFmpeg, to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )

        let session = try await transcoder.start(relayURL: Self.relayURL)
        let master = try String(contentsOf: session.playlistURL, encoding: .utf8)

        XCTAssertTrue(master.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        await transcoder.stop()
    }

    func testMissingSourceAudioClassifierDoesNotMistakeMissingVideo() {
        XCTAssertTrue(
            FFmpegHLSAudioTranscoder.sourceAudioStreamIsMissing(
                fromFFmpegDiagnostics: "Stream map '0:a:0' matches no streams."
            )
        )
        XCTAssertFalse(
            FFmpegHLSAudioTranscoder.sourceAudioStreamIsMissing(
                fromFFmpegDiagnostics: "Stream map '0:v:0' matches no streams."
            )
        )
        XCTAssertFalse(
            FFmpegHLSAudioTranscoder.sourceAudioStreamIsMissing(
                fromFFmpegDiagnostics: "Stream map 0:a:0 matches no streams. Stream map 0:v:0 matches no streams."
            )
        )
    }

    func testInputVideoClassificationRequiresFallbackForHEVCAndOversizedH264() {
        let hevc = "Stream #0:0: Video: hevc (Main 10), yuv420p10le, 3840x2160, 50 fps"
        let h264 = "Stream #0:0: Video: h264 (High), yuv420p, 1920x1080, 25 fps"
        let h264UHD = "Stream #0:0: Video: h264 (High), yuv420p, 3840x2160, 50 fps"

        XCTAssertEqual(
            FFmpegHLSAudioTranscoder.inputVideoCodec(fromFFmpegDiagnostics: hevc),
            "hevc"
        )
        XCTAssertEqual(
            FFmpegHLSAudioTranscoder.inputVideoResolution(fromFFmpegDiagnostics: h264UHD)?.width,
            3_840
        )
        XCTAssertEqual(
            FFmpegHLSAudioTranscoder.inputVideoResolution(fromFFmpegDiagnostics: h264UHD)?.height,
            2_160
        )
        XCTAssertTrue(
            FFmpegHLSAudioTranscoder.inputRequiresH264Transcode(
                fromFFmpegDiagnostics: hevc
            )
        )
        XCTAssertTrue(
            FFmpegHLSAudioTranscoder.inputRequiresH264Transcode(
                fromFFmpegDiagnostics: h264UHD
            )
        )
        XCTAssertFalse(
            FFmpegHLSAudioTranscoder.inputRequiresH264Transcode(
                fromFFmpegDiagnostics: h264
            )
        )
    }

    func testRawMPEGTSUsesStandardInputAndCancelsItsFeeder() async throws {
        let root = try makeTemporaryDirectory(named: "raw-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable(Self.successfulRawFakeFFmpeg, to: executable)
        let cancellationProbe = FeederCancellationProbe()
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(3),
            temporaryRoot: root,
            frameRateInspector: FixedVideoFrameRateInspector(frameRate: 25),
            startupInspector: FixedStartupInspector(result: .cleanIDR)
        )

        let session = try await transcoder.startMPEGTS { consumer in
            try await withTaskCancellationHandler {
                try await consumer.consume(Data("opaque-".utf8))
                try await consumer.consume(Data("transport-stream\n".utf8))
                while true {
                    try await Task.sleep(for: .seconds(30))
                }
            } onCancel: {
                cancellationProbe.markCancelled()
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.playlistURL.path))
        XCTAssertEqual(session.playlistURL.lastPathComponent, "index.m3u8")
        let outputDirectory = session.playlistURL.deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent("media-0.m3u8").path
            )
        )
        await transcoder.stop()

        XCTAssertTrue(cancellationProbe.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testRawMPEGTSMapsUpstreamFailureWithoutSurfacingItsError() async throws {
        let root = try makeTemporaryDirectory(named: "raw-source-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable("#!/bin/sh\nwhile :; do sleep 1; done\n", to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(2),
            temporaryRoot: root
        )

        do {
            _ = try await transcoder.startMPEGTS { _ in
                throw SensitiveUpstreamError()
            }
            XCTFail("Expected the upstream failure to stop startup")
        } catch let error as FFmpegHLSAudioTranscoderError {
            XCTAssertEqual(error, .processFailed(.inputStreamFailed))
            XCTAssertFalse(error.localizedDescription.contains("provider.example"))
            XCTAssertFalse(error.localizedDescription.contains("credential"))
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testTimeoutTerminatesProcessAndRemovesOwnedDirectory() async throws {
        let root = try makeTemporaryDirectory(named: "timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        try writeExecutable("#!/bin/sh\nwhile :; do sleep 1; done\n", to: executable)
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .milliseconds(250),
            temporaryRoot: root
        )

        await XCTAssertThrowsTranscoderError(.startupTimedOut) {
            _ = try await transcoder.start(relayURL: Self.relayURL)
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(remaining.map(\.lastPathComponent), ["ffmpeg"])
    }

    func testEarlyExitMapsPrivateDiagnosticsToSafeActionableError() async throws {
        let root = try makeTemporaryDirectory(named: "failure-diagnostics")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ffmpeg")
        let privateRelayToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' \"Stream map 0:a:0 matches no streams at https://relay.invalid/s/\(privateRelayToken)/index.m3u8\" >&2\nexit 1\n",
            to: executable
        )
        let transcoder = FFmpegHLSAudioTranscoder(
            locator: FixedFFmpegLocator(url: executable),
            startupTimeout: .seconds(2),
            temporaryRoot: root
        )

        do {
            _ = try await transcoder.start(relayURL: Self.relayURL)
            XCTFail("Expected a classified process failure")
        } catch let error as FFmpegHLSAudioTranscoderError {
            XCTAssertEqual(error, .processFailed(.missingRequiredStreams))
            XCTAssertTrue(error.localizedDescription.contains("video track and an audio track"))
            XCTAssertFalse(error.localizedDescription.contains(privateRelayToken))
            XCTAssertFalse(error.localizedDescription.contains("relay.invalid"))
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testDiagnosticClassifierDoesNotReturnRawSensitiveText() {
        let token = "secret-relay-token"
        let cases: [(String, FFmpegProcessFailureReason)] = [
            ("dyld: Library not loaded: /private/\(token)/libavcodec.dylib", .incompleteInstallation),
            ("Unknown encoder 'aac' for https://example.invalid/\(token)", .incompatibleBuild),
            ("certificate verify failed for https://example.invalid/\(token)", .certificateRejected),
            ("Connection refused at https://example.invalid/\(token)", .cannotReachRelay),
            ("Codec is not supported by the bitstream filter h264_mp4toannexb", .incompatibleVideoCodec),
        ]

        for (diagnostics, expected) in cases {
            let reason = FFmpegHLSAudioTranscoder.failureReason(for: diagnostics)
            XCTAssertEqual(reason, expected)
            XCTAssertFalse(reason.userMessage.contains(token))
            XCTAssertFalse(reason.userMessage.contains("example.invalid"))
        }
    }

    func testFrameRateParserReturnsOnlyValidatedNumericMetadata() {
        let diagnostics = """
        Input #0 from https://relay.invalid/s/secret-token/index.m3u8
        Stream #0:0: Video: h264, yuv420p, 1920x1080, 25 fps, 25 tbr
        """

        XCTAssertEqual(
            FFmpegHLSAudioTranscoder.frameRate(fromFFmpegDiagnostics: diagnostics),
            25
        )
        XCTAssertNil(
            FFmpegHLSAudioTranscoder.frameRate(
                fromFFmpegDiagnostics: "Stream: Video, 1920x1080, 1000 fps, secret-token"
            )
        )
    }

    func testMediaPlaylistNormalizerCanonicalizesReceiverFacingPlaylist() throws {
        let source = """
        \u{FEFF}#EXTM3U\r
        #EXT-X-VERSION:6\r
        #EXT-X-ALLOW-CACHE:NO\r
        #EXT-X-TARGETDURATION:4\r
        #EXT-X-MEDIA-SEQUENCE:42\r
        #EXT-X-INDEPENDENT-SEGMENTS\r
        #EXTINF:3.840000,\r
        #EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:03:46.074+0200\r
        segment-0-000000042.ts\r
        #EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:03:49.914Z\r
        #EXTINF:3.840000,\r
        segment-0-000000043.ts\r
        """

        let normalized = try HLSMediaPlaylistNormalizer().normalize(source)

        XCTAssertEqual(
            normalized,
            """
            #EXTM3U
            #EXT-X-VERSION:6
            #EXT-X-TARGETDURATION:12
            #EXT-X-MEDIA-SEQUENCE:42
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:03:46.074+02:00
            #EXTINF:3.840000,
            segment-0-000000042.ts
            #EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:03:49.914Z
            #EXTINF:3.840000,
            segment-0-000000043.ts

            """
        )
        XCTAssertFalse(normalized.contains("EXT-X-ALLOW-CACHE"))

        let laterUpdate = source
            .replacingOccurrences(of: "#EXT-X-TARGETDURATION:4", with: "#EXT-X-TARGETDURATION:10")
            .replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:42", with: "#EXT-X-MEDIA-SEQUENCE:43")
            .replacingOccurrences(of: "#EXTINF:3.840000,", with: "#EXTINF:9.600000,")
        let normalizedLaterUpdate = try HLSMediaPlaylistNormalizer().normalize(laterUpdate)
        XCTAssertTrue(normalizedLaterUpdate.contains("#EXT-X-TARGETDURATION:12"))
        XCTAssertFalse(normalizedLaterUpdate.contains("#EXT-X-TARGETDURATION:10"))
        XCTAssertEqual(
            normalizedLaterUpdate.components(separatedBy: "#EXTINF:9.600000,").count - 1,
            2
        )
    }

    func testMediaPlaylistNormalizerRejectsUnsafeOrIncompleteInput() {
        let cases = [
            "#EXTM3U\n#EXTINF:4,\nsegment.ts\n",
            "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-PROGRAM-DATE-TIME:not-a-date\n#EXTINF:4,\nsegment.ts\n",
            "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:00:00.000Z\n#EXTINF:12.6,\nsegment.ts\n",
        ]

        for playlist in cases {
            XCTAssertThrowsError(try HLSMediaPlaylistNormalizer().normalize(playlist)) { error in
                XCTAssertEqual(
                    error as? HLSMediaPlaylistNormalizationError,
                    .invalidPlaylist
                )
            }
        }
    }

    private func XCTAssertThrowsTranscoderError(
        _ expected: FFmpegHLSAudioTranscoderError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as FFmpegHLSAudioTranscoderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private static let relayURL = URL(
        string: "https://iptv-test.example:49152/s/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/index.m3u8"
    )!

    private static let successfulFakeFFmpeg = #"""
    #!/bin/sh
    arguments=" $* "
    case "$arguments" in *" -re -i https://"*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -map 0:v:0 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -map 0:a:0 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -c:v copy "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -bsf:v h264_mp4toannexb "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -c:a aac "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -ac 2 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -ar 48000 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -b:a 160k "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -hls_time 4 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -hls_list_size 75 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -hls_delete_threshold 15 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *"source-segment-%09d.ts"*) ;; *) exit 64 ;; esac
    case "$arguments" in *"source.m3u8"*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -hls_allow_cache "*) exit 64 ;; esac
    """# + "\n" + successfulOutputScript

    private static let successfulRawFakeFFmpeg = #"""
    #!/bin/sh
    arguments=" $* "
    case "$arguments" in *" -f mpegts -re -i pipe:0 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *"http://"*|*"https://"*) exit 64 ;; esac
    case "$arguments" in *" -hls_allow_cache "*) exit 64 ;; esac

    IFS= read -r payload
    [ "$payload" = "opaque-transport-stream" ] || exit 64
    """# + "\n" + successfulOutputScript

    private static let automaticHEVCFallbackFakeFFmpeg = #"""
    #!/bin/sh
    arguments=" $* "
    case "$arguments" in
        *" -c:v h264_videotoolbox "*)
            case "$arguments" in *" -hwaccel videotoolbox "*) ;; *) exit 64 ;; esac
            case "$arguments" in *" -vf scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,format=nv12,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709 "*) ;; *) exit 64 ;; esac
            case "$arguments" in *" -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 "*) ;; *) exit 64 ;; esac
            case "$arguments" in *" -force_key_frames expr:gte(t,n_forced*4) "*) ;; *) exit 64 ;; esac
            segment_limit=3
            ;;
        *" -c:v copy "*)
            printf 'Stream #0:0: Video: hevc (Main 10), yuv420p10le, 3840x2160, 50 fps, 50 tbr\n' >&2
            trap 'exit 0' TERM INT
            while :; do sleep 1; done
            ;;
        *)
            exit 64
            ;;
    esac
    """# + "\n" + successfulOutputScript

    private static let automaticH264LongGOPFallbackFakeFFmpeg = #"""
    #!/bin/sh
    arguments=" $* "
    case "$arguments" in
        *" -c:v h264_videotoolbox "*)
            case "$arguments" in *" -hwaccel videotoolbox "*) ;; *) exit 64 ;; esac
            case "$arguments" in *" -vf scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,format=nv12,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709 "*) ;; *) exit 64 ;; esac
            case "$arguments" in *" -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 "*) ;; *) exit 64 ;; esac
            case "$arguments" in *" -force_key_frames expr:gte(t,n_forced*4) "*) ;; *) exit 64 ;; esac
            segment_limit=3
            ;;
        *" -c:v copy "*)
            printf 'Stream #0:0: Video: h264 (High), yuv420p, 1920x1080, 25 fps, 25 tbr\n' >&2
            trap 'exit 0' TERM INT
            while :; do sleep 1; done
            ;;
        *)
            exit 64
            ;;
    esac
    """# + "\n" + successfulOutputScript

    private static let automaticSilentAudioFallbackFakeFFmpeg = #"""
    #!/bin/sh
    arguments=" $* "
    case "$arguments" in
        *" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 "*)
            case "$arguments" in *" -map 1:a:0 "*) ;; *) exit 64 ;; esac
            ;;
        *)
            printf "Stream map '0:a:0' matches no streams.\n" >&2
            exit 1
            ;;
    esac
    """# + "\n" + successfulOutputScript

    private static let successfulOutputScript = #"""
    segment_limit=${segment_limit:-6}
    case "$arguments" in *" -loglevel info "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -nostats "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -var_stream_map v:0,a:0 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -master_pl_name ffmpeg-index.m3u8 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -master_pl_publish_rate 1 "*) ;; *) exit 64 ;; esac
    case "$arguments" in *" -hls_flags delete_segments+independent_segments+temp_file+omit_endlist+program_date_time "*) ;; *) exit 64 ;; esac

    printf 'Stream #0:0: Video: h264, yuv420p, 1920x1080, 25 fps, 25 tbr\n' >&2

    segment_template=""
    media_template=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -hls_segment_filename)
                shift
                segment_template="$1"
                ;;
        esac
        media_template="$1"
        shift
    done

    case "$segment_template" in
        */segment-%v-%09d.ts) ;;
        *) exit 64 ;;
    esac
    case "$media_template" in
        */media-%v.m3u8) ;;
        *) exit 64 ;;
    esac

    segment_template=$(printf '%s' "$segment_template" | sed 's/%v/0/g')
    media_playlist=$(printf '%s' "$media_template" | sed 's/%v/0/g')
    master_playlist="$(dirname "$media_playlist")/ffmpeg-index.m3u8"

    index=0
    while [ "$index" -lt "$segment_limit" ]; do
        segment=$(printf "$segment_template" "$index")
        printf 'transport-stream-%s' "$index" > "${segment}.tmp"
        mv "${segment}.tmp" "$segment"
        index=$((index + 1))
    done

    {
        printf '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n'
        index=0
        while [ "$index" -lt "$segment_limit" ]; do
            segment=$(printf "$segment_template" "$index")
            printf '#EXTINF:4.0,\n#EXT-X-PROGRAM-DATE-TIME:2026-09-04T00:00:0%sZ\n%s\n' "$index" "$(basename "$segment")"
            index=$((index + 1))
        done
    } > "${media_playlist}.tmp"
    mv "${media_playlist}.tmp" "$media_playlist"

    {
        printf '#EXTM3U\n#EXT-X-VERSION:6\n'
        printf '#EXT-X-STREAM-INF:BANDWIDTH=6000000,AVERAGE-BANDWIDTH=5500000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"\n'
        printf 'media-0.m3u8\n'
    } > "${master_playlist}.tmp"
    mv "${master_playlist}.tmp" "$master_playlist"

    source_segment_template="$(dirname "$media_playlist")/source-segment-%09d.ts"
    source_media_playlist="$(dirname "$media_playlist")/source.m3u8"
    index=0
    while [ "$index" -lt "$segment_limit" ]; do
        source_segment=$(printf "$source_segment_template" "$index")
        printf 'source-transport-stream-%s' "$index" > "${source_segment}.tmp"
        mv "${source_segment}.tmp" "$source_segment"
        index=$((index + 1))
    done
    {
        printf '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n'
        index=0
        while [ "$index" -lt "$segment_limit" ]; do
            source_segment=$(printf "$source_segment_template" "$index")
            printf '#EXTINF:4.0,\n#EXT-X-PROGRAM-DATE-TIME:2026-09-04T00:00:0%sZ\n%s\n' "$index" "$(basename "$source_segment")"
            index=$((index + 1))
        done
    } > "${source_media_playlist}.tmp"
    mv "${source_media_playlist}.tmp" "$source_media_playlist"

    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    """#
}

private actor SyntheticMPEGTSInput {
    let bytes: Data
    private(set) var feedCount = 0

    init(bytes: Data) { self.bytes = bytes }

    func feed(_ consumer: any MPEGTSByteConsuming) async throws {
        feedCount += 1
        for offset in stride(from: 0, to: bytes.count, by: 64 * 1_024) {
            try Task.checkCancellation()
            try await consumer.consume(bytes.subdata(in: offset ..< min(offset + 64 * 1_024, bytes.count)))
        }
    }
}

private struct FixedFFmpegLocator: FFmpegExecutableLocating {
    let url: URL?

    func executableURL() -> URL? { url }
}

private struct FixedVideoFrameRateInspector: VideoFrameRateInspecting {
    let frameRate: Double?

    func frameRate(forLocalSegment segmentURL: URL) async -> Double? {
        frameRate
    }
}

private struct FixedStartupInspector: H264TransportStreamStartupInspecting {
    let result: H264TransportStreamStartupResult

    func inspect(segmentURL: URL) throws -> H264TransportStreamStartupResult { result }
}

private struct ModeAwareStartupInspector: H264TransportStreamStartupInspecting {
    func inspect(segmentURL: URL) throws -> H264TransportStreamStartupResult {
        let bytes = try Data(contentsOf: segmentURL)
        return String(decoding: bytes, as: UTF8.self).hasPrefix("clean-idr-") ? .cleanIDR : .nonIDRStart
    }
}

private final class FeederCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct SensitiveUpstreamError: Error, CustomStringConvertible, Sendable {
    var description: String {
        "https://provider.example/live?credential=must-not-surface"
    }
}

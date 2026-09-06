import XCTest
@testable import ChannelDeckTV

@MainActor
final class TVPlaybackIntegrationTests: XCTestCase {
    func testMiniPlayerPreservesPausedPositionAndCaptureAcrossPresentationChanges() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for mini player tests.") }
        let channel = TVChannel(id: "mini-test", sourceID: UUID(), name: "Mini player test", group: "Test", tvgID: nil, logoURL: nil,
                                streamURL: URL(string: "http://127.0.0.1:8765/live.ts")!, order: 0)
        let player = TVPlaybackController()
        defer { player.stop() }
        player.play(channel, minutes: 10)
        let engine = try XCTUnwrap(player.engine)
        for _ in 0..<100 {
            if player.isReady { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(player.isReady)
        player.pause()
        let paused = engine.snapshot()
        for _ in 0..<3 {
            player.minimize()
            player.dismissFullscreen()
            XCTAssertTrue(player.isMinimized)
            XCTAssertFalse(player.isFullscreenPresented)
            XCTAssertTrue(player.engine === engine, "Dismissing the cover to minimize must retain its renderer and buffer.")
            try await Task.sleep(for: .seconds(1))
            player.expand()
            XCTAssertTrue(player.isFullscreenPresented)
            XCTAssertTrue(player.engine === engine)
        }
        let retained = engine.snapshot()
        XCTAssertTrue(retained.paused)
        XCTAssertEqual(retained.position, paused.position, accuracy: 0.3)
        XCTAssertGreaterThan(retained.end, paused.end, "The rewind window keeps capturing in the mini player.")
        player.resume()
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(engine.snapshot().position, paused.position + 1)
        player.minimize()
        player.play(channel, minutes: 5)
        XCTAssertFalse(player.engine === engine, "Selecting a channel replaces the previous session.")
        XCTAssertEqual(engine.snapshot().bytes, 0)
        XCTAssertTrue(player.isFullscreenPresented)
        player.dismissFullscreen()
        XCTAssertNil(player.engine)
        XCTAssertFalse(player.isMinimized)
        XCTAssertFalse(player.isFullscreenPresented)
    }
    func testContinuousTransportStreamCapturePauseSeekAndStop() async throws {
        try await exercise(path: "live.ts")
    }
    func testHLSSegmentCapturePauseSeekAndStop() async throws {
        try await exercise(path: "hls/live.m3u8")
    }
    func testCodecChangeResetsHistoryAndResumesAudioAndVideo() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for format transition tests.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(URL(string: "http://127.0.0.1:8765/format-change.ts")!, bufferSeconds: 600)
        var sawOriginal = false
        var resetFrames: (UInt64, UInt64)?
        var recovered = false
        for _ in 0..<240 {
            let value = engine.snapshot()
            if value.ready && value.end > 5 { sawOriginal = true }
            if sawOriginal && value.end < 2 && resetFrames == nil { resetFrames = (value.videoFrames, value.audioFrames) }
            if let resetFrames, value.videoFrames > resetFrames.0 + 25, value.audioFrames > resetFrames.1 + 25 {
                recovered = true; break
            }
            if !value.failure.isEmpty { XCTFail(value.failure); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sawOriginal)
        XCTAssertNotNil(resetFrames, "Changing H.264/AAC to MPEG-2/MP2 must discard incompatible history.")
        XCTAssertTrue(recovered, "Both replacement codecs must reach the renderers after the transition.")
        XCTAssertEqual(engine.snapshot().videoCodec, "mpeg2video")
        XCTAssertEqual(engine.snapshot().audioCodec, "mp2")
        XCTAssertEqual(engine.snapshot().videoWidth, 320)
        XCTAssertEqual(engine.snapshot().videoHeight, 180)
    }
    func testInterruptedStreamReconnectsAndResetsHistory() async throws {
        let url = URL(string: "http://127.0.0.1:8765/disconnect.ts")!
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for connection recovery tests.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(url, bufferSeconds: 600)
        var restored = false
        for _ in 0..<200 {
            let value = engine.snapshot()
            if value.message.contains("Connection restored") && value.ready && value.videoFrames > 150 {
                restored = true; break
            }
            if !value.failure.isEmpty { XCTFail(value.failure); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(restored, "A new connection must resume decoding after a transport interruption.")
        XCTAssertGreaterThan(engine.snapshot().audioFrames, 0)
        XCTAssertLessThan(engine.snapshot().end, 10, "The reconnected stream starts a fresh history window.")
    }
    func testInjectedTransportInterruptionReopensAndRestartsDecoders() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for transport interruption tests.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(URL(string: "http://127.0.0.1:8765/live.ts")!, bufferSeconds: 600)
        for _ in 0..<100 {
            if engine.snapshot().position > 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let previous = engine.snapshot()
        XCTAssertGreaterThan(previous.videoFrames, 0)
        engine.interruptTransportForTesting()
        var restored = false
        for _ in 0..<200 {
            let value = engine.snapshot()
            if value.message.contains("Connection restored") && value.videoFrames > previous.videoFrames + 25 && value.audioFrames > previous.audioFrames + 25 {
                restored = true; break
            }
            if !value.failure.isEmpty { XCTFail(value.failure); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(restored)
        XCTAssertLessThan(engine.snapshot().end, previous.end)
    }
    func testExhaustedConnectionRetriesStopCaptureAndClearHistory() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for failed connection cleanup tests.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(URL(string: "http://127.0.0.1:8765/disconnect.ts")!, bufferSeconds: 600)
        var captured = false
        for _ in 0..<450 {
            let value = engine.snapshot()
            captured = captured || value.bytes > 0
            if !value.failure.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let failed = engine.snapshot()
        XCTAssertTrue(captured)
        XCTAssertFalse(failed.failure.isEmpty, "Repeated unsuccessful recovery must leave a retryable error.")
        XCTAssertEqual(failed.bytes, 0)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(engine.snapshot().videoFrames, failed.videoFrames)
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasSuffix(".packets") })
    }
    func testPausedCursorExpiresAndResumesWithinRetainedHistory() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for history expiry tests.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(URL(string: "http://127.0.0.1:8765/fast.ts")!, bufferSeconds: 600)
        engine.setPaused(true)
        for _ in 0..<200 {
            if engine.snapshot().end > 620 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let retained = engine.snapshot()
        XCTAssertGreaterThan(retained.end, 620)
        XCTAssertGreaterThan(retained.start, 20)
        XCTAssertLessThanOrEqual(retained.end - retained.start, 600.1)
        engine.setPaused(false)
        for _ in 0..<50 {
            if engine.snapshot().videoFrames > 5 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(engine.snapshot().videoFrames, 0)
        XCTAssertGreaterThanOrEqual(engine.snapshot().position, retained.start)
        XCTAssertTrue(engine.snapshot().message.contains("history expired"))
        XCTAssertTrue(engine.snapshot().failure.isEmpty)
    }
    private func exercise(path: String) async throws {
        let base = URL(string: "http://127.0.0.1:8765")!
        var request = URLRequest(url: base.appending(path: "playlist.m3u"))
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py to run local live playback integration tests.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(base.appending(path: path), bufferSeconds: 600)
        for _ in 0..<100 {
            if engine.snapshot().ready { break }
            if !engine.snapshot().failure.isEmpty { XCTFail(engine.snapshot().failure); return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(engine.snapshot().ready, "Audio/video must actually reach the render clock.")
        try await Task.sleep(for: .seconds(4))
        engine.setPaused(true)
        let paused = engine.snapshot()
        try await Task.sleep(for: .seconds(4))
        let captured = engine.snapshot()
        XCTAssertGreaterThan(captured.videoFrames, 0, "Decoded video must reach the video renderer.")
        XCTAssertGreaterThan(captured.audioFrames, 0, "Decoded audio must reach the audio renderer.")
        XCTAssertEqual(captured.videoCodec, "h264")
        XCTAssertEqual(captured.audioCodec, "aac")
        XCTAssertEqual(captured.videoWidth, 640)
        XCTAssertEqual(captured.videoHeight, 360)
        XCTAssertGreaterThan(captured.end, paused.end, "Ingestion must continue while rendering is paused.")
        XCTAssertEqual(captured.position, paused.position, accuracy: 0.3)
        XCTAssertGreaterThan(captured.bytes, 0)
        engine.setPaused(false)
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(engine.snapshot().position, captured.position + 1, "Resume must restart the render clock without a seek.")
        XCTAssertGreaterThan(engine.snapshot().videoFrames, captured.videoFrames)
        for target in [max(captured.start, captured.end - 4), captured.start, captured.end - 1] {
            let frames = engine.snapshot().videoFrames
            engine.seek(to: target)
            try await Task.sleep(for: .seconds(2))
            let sought = engine.snapshot()
            XCTAssertTrue(sought.failure.isEmpty)
            XCTAssertGreaterThan(sought.videoFrames, frames, "Each seek must restart rendering.")
            XCTAssertGreaterThanOrEqual(sought.position, target)
            XCTAssertLessThan(sought.position, target + 3, "The render clock must follow the requested position.")
        }
        engine.goLive()
        try await Task.sleep(for: .seconds(2))
        XCTAssertLessThan(engine.snapshot().end - engine.snapshot().position, 4)
        engine.stop()
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(files.contains { $0.hasSuffix(".packets") }, "Stop clears temporary media immediately.")
    }
}

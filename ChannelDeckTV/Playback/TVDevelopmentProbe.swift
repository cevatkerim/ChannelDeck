#if DEBUG
import Foundation

/// Local development only: transfer this file with devicectl into Library/Caches.
/// It is consumed once, removed immediately, and never bundled with the app.
enum TVDevelopmentProbe {
    struct Setup: Decodable {
        let name: String
        let playlist: String
        let channelName: String?
        let probeSeconds: Int?
        let interruptAtSeconds: Int?
    }
    static func takeSetup() -> Setup? {
        let file = URL.cachesDirectory.appending(path: "ChannelDeckTV-development.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let bytes = try? Data(contentsOf: file), bytes.count < 16384 else { return nil }
        return try? JSONDecoder().decode(Setup.self, from: bytes)
    }
    @MainActor static func run(player: TVPlaybackController, library: TVLibrary, seconds: Int, interruptAtSeconds: Int? = nil) async {
        guard seconds > 0, let initialEngine = player.engine else { return }
        let file = URL.cachesDirectory.appending(path: "ChannelDeckTV-probe.json")
        var records: [[String: Any]] = []
        let start = Date.now
        var automaticActions = true
        for elapsed in 0...min(seconds, 7200) {
            guard !Task.isCancelled else { return }
            if player.engine !== initialEngine { automaticActions = false }
            guard let engine = player.engine else {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                continue
            }
            if automaticActions {
                if elapsed == interruptAtSeconds { engine.interruptTransportForTesting() }
                if elapsed == 30 { engine.setPaused(true) }
                if elapsed == 40 { engine.setPaused(false) }
                if elapsed == 70 { engine.seek(to: max(0, engine.snapshot().end - 20)) }
                if elapsed == 90 { engine.goLive() }
                if elapsed == 620 { engine.seek(to: max(engine.snapshot().start, engine.snapshot().end - 600)) }
                if elapsed == 640 { engine.goLive() }
            }
            if elapsed.isMultiple(of: 10) || elapsed == seconds {
                let value = engine.snapshot()
                records.append(["elapsed": Date.now.timeIntervalSince(start), "position": value.position,
                                "start": value.start, "end": value.end, "bytes": value.bytes,
                                "videoFrames": value.videoFrames, "audioFrames": value.audioFrames,
                                "videoCodec": value.videoCodec, "audioCodec": value.audioCodec,
                                "videoWidth": value.videoWidth, "videoHeight": value.videoHeight,
                                "hardwareVideo": value.hardwareVideo,
                                "paused": value.paused, "ready": value.ready, "failure": value.failure, "message": value.message,
                                "channels": library.channels.count, "guideChannels": library.schedules.values.filter { !$0.isEmpty }.count,
                                "guideProgress": Array(library.guideProgress.values), "sourceErrors": Array(library.sourceErrors.values)])
                if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: file, options: .atomic)
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
}
#endif

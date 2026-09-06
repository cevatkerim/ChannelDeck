import XCTest
import UIKit
@testable import ChannelDeckTV

@MainActor final class TVArtworkTests: XCTestCase {
    private func channel(_ name: String, order: Int = 0) -> TVChannel {
        TVChannel(id: name, sourceID: UUID(), name: name, group: "Test", tvgID: nil,
                  logoURL: URL(string: "https://example.invalid/logo.png"), streamURL: URL(string: "https://example.invalid/private-stream")!, order: order)
    }
    func testShelfReservesFavoritesDeduplicatesAndRanksFrequency() throws {
        let channels = (0..<20).map { channel("Channel \($0)", order: $0) }
        var state = TVUserState()
        state.favorites = Set(channels.suffix(6).map(\.preferenceID))
        state.watchCounts = Dictionary(uniqueKeysWithValues: channels.enumerated().map { ($0.element.preferenceID, 30 - $0.offset) })
        let shelf = TVLibrary.shelfChannels(channels: channels, state: state)
        XCTAssertEqual(shelf.count, 12)
        XCTAssertEqual(Set(shelf.map(\.id)).count, 12)
        XCTAssertEqual(shelf.first?.id, channels.first?.id)
        XCTAssertTrue(Set(channels.suffix(6).map(\.id)).isSubset(of: Set(shelf.map(\.id))))
        let legacy = try JSONDecoder().decode(TVUserState.self, from: Data(#"{"sources":[],"favorites":[],"recents":[],"bufferMinutes":10}"#.utf8))
        XCTAssertNil(legacy.watchCounts)
    }
    func testShelfLinksContainOnlyAnOpaqueIdentifier() {
        let key = TVShelfStore.key("https://example.invalid/?password=secret")
        let entry = TVShelfEntry(id: key, name: "Test", favorite: false, artwork: nil)
        XCTAssertEqual(TVShelfStore.channelKey(from: entry.actionURL), key)
        XCTAssertFalse(entry.actionURL.absoluteString.contains("secret"))
        XCTAssertNil(TVShelfStore.channelKey(from: URL(string: "channeldeck://watch/../private")!))
        XCTAssertNil(TVShelfStore.channelKey(from: URL(string: "https://watch/\(key)")!))
    }
    func testFrameAndLogoProduceSharedArtworkAndExpiredFramesUseLogo() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = channel("Test")
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }.pngData()!
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }.jpegData(compressionQuality: 0.8)!
        let pipeline = TVArtworkPipeline(directory: directory, loadLogo: { _ in logo })
        await pipeline.ensureLogo(channel)
        let date = Date.now
        try await pipeline.store(frame, channel: channel, capturedAt: date)
        let key = TVShelfStore.key(channel.id)
        try await pipeline.publish([TVShelfEntry(id: key, name: channel.name, favorite: true, artwork: nil)])
        let entries = TVShelfStore.read(from: directory)
        let metadata = try XCTUnwrap(entries.first?.artwork)
        XCTAssertNotEqual(metadata.image, metadata.fallback)
        XCTAssertEqual(metadata.imageName(at: date.addingTimeInterval(25 * 3600)), metadata.fallback)
        let data = await pipeline.image(for: key)
        let image = try XCTUnwrap(data.flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size, CGSize(width: 640, height: 360))
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 640, height: 360))
        let rgb = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
        var red = 0, blue = 0
        for i in stride(from: 0, to: 640 * 360 * 4, by: 4) {
            if rgb[i] > 180 && rgb[i + 1] < 80 && rgb[i + 2] < 80 { red += 1 }
            if rgb[i + 2] > 180 && rgb[i] < 80 { blue += 1 }
        }
        XCTAssertGreaterThan(red, 1500, "The logo must be composited over the frame.")
        XCTAssertGreaterThan(blue, 210000, "Without a programme title, no caption strip may cover the frame.")
        let bytes = try Data(contentsOf: directory.appending(path: "shelf.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("https://"))
        XCTAssertNil(TVShelfStore.imageURL("../private.jpg", directory: directory))
        let attachment = XCTAttachment(image: image); attachment.name = "Frame with channel logo"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testProgrammeTitleIsOptionalAndBelongsToTheCapturedFrame() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = channel("Programme")
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }.jpegData(compressionQuality: 0.8)!
        let pipeline = TVArtworkPipeline(directory: directory, loadLogo: { _ in Data() })
        let date = Date.now, key = TVShelfStore.key(channel.id)
        try await pipeline.store(frame, channel: channel, capturedAt: date, programmeTitle: "  Evening News\n ")
        let item = await pipeline.artwork(for: key)
        let artwork = try XCTUnwrap(item)
        XCTAssertEqual(artwork.previewTitle(at: date), "Evening News")
        XCTAssertNil(artwork.previewTitle(at: date.addingTimeInterval(25 * 3600)))
        XCTAssertNotEqual(artwork.image, artwork.preview, "Native cards must render accessible text separately from the image.")
        let native = try Data(contentsOf: directory.appending(path: artwork.image))
        let clean = await pipeline.image(for: key)
        XCTAssertNotEqual(native, clean, "Home Screen artwork must include the programme caption.")
        let attachment = XCTAttachment(image: try XCTUnwrap(UIImage(data: native)))
        attachment.name = "Programme title on Top Shelf"; attachment.lifetime = .keepAlways; add(attachment)
        // A later logo download must retain the title belonging to this frame.
        await pipeline.ensureLogo(channel)
        let refreshed = await pipeline.artwork(for: key)
        XCTAssertEqual(refreshed?.programmeTitle, "Evening News")
        XCTAssertEqual(refreshed?.capturedAt, date)
        try await pipeline.store(frame, channel: channel, capturedAt: date, programmeTitle: " \n\t ")
        let blank = await pipeline.artwork(for: key)
        XCTAssertNil(blank?.programmeTitle)
        XCTAssertEqual(blank?.image, blank?.preview, "Missing titles must have no caption or placeholder.")
        let blankData = await pipeline.image(for: key)
        XCTAssertEqual(blankData, clean)
    }
    func testLegacyTimestampArtworkIsRebuiltFromTheRawFrame() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let channel = channel("Legacy"), key = TVShelfStore.key("Legacy")
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }.jpegData(compressionQuality: 0.8)!
        try frame.write(to: directory.appending(path: "frame-\(key).jpg"))
        let legacy = TVShelfArtwork(image: "old-timestamp.jpg", fallback: "old-logo.jpg", capturedAt: .now)
        try JSONEncoder().encode([key: legacy]).write(to: directory.appending(path: "artwork.json"))
        XCTAssertEqual(legacy.imageName(), legacy.fallback, "The extension must not display outdated timestamp composites during migration.")
        let pipeline = TVArtworkPipeline(directory: directory, loadLogo: { _ in Data() })
        try await pipeline.publish([TVShelfEntry(id: key, name: channel.name, favorite: false, artwork: nil)])
        let item = try XCTUnwrap(TVShelfStore.read(from: directory).first?.artwork)
        XCTAssertNotEqual(item.image, legacy.image)
        XCTAssertEqual(item.style, TVShelfArtwork.currentStyle)
        XCTAssertNil(item.programmeTitle)
        XCTAssertNotNil(item.capturedAt)
        let image = await pipeline.image(for: key)
        XCTAssertNotNil(image.flatMap(UIImage.init(data:)), "Migration must preserve the raw frame even without a logo or guide.")
        XCTAssertEqual(item.image, item.preview)
    }
    func testArtworkCachePlateausAndRetainsTheCurrentShelfImage() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let junk = Data(repeating: 0, count: 2 * 1024 * 1024)
        for i in 0..<34 { try junk.write(to: directory.appending(path: "old-\(i).jpg")) }
        let channel = channel("Current")
        let pipeline = TVArtworkPipeline(directory: directory, loadLogo: { _ in Data() })
        try await pipeline.publish([TVShelfEntry(id: TVShelfStore.key(channel.id), name: channel.name, favorite: true, artwork: nil)])
        await pipeline.ensureLogo(channel)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "jpg" }
        let bytes = try files.reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 64 * 1024 * 1024)
        let entry = try XCTUnwrap(TVShelfStore.read(from: directory).first)
        let artwork = try XCTUnwrap(entry.artwork)
        XCTAssertNotNil(TVShelfStore.imageURL(artwork.imageName(), directory: directory))
    }
    func testNativeThumbnailComesFromDecodedVideo() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!); request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start the tvOS fixture server.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.play(URL(string: "http://127.0.0.1:8765/live.ts")!, bufferSeconds: 600)
        for _ in 0..<100 {
            if engine.snapshot().videoFrames > 20 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let jpeg = await engine.captureThumbnail()
        let image = try XCTUnwrap(jpeg.flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size, CGSize(width: 640, height: 360))
        XCTAssertGreaterThan(engine.snapshot().audioFrames, 0)
        let attachment = XCTAttachment(image: image); attachment.name = "Decoded channel preview"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testProviderIngestionLeadDoesNotSuppressLivePreview() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!); request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start the tvOS fixture server.") }
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let artwork = TVArtworkLibrary(directory: directory)
        let player = TVPlaybackController()
        defer { player.stop(); try? FileManager.default.removeItem(at: directory) }
        let channel = TVChannel(id: "ahead", sourceID: UUID(), name: "Ahead", group: "Test", tvgID: nil, logoURL: nil,
                                streamURL: URL(string: "http://127.0.0.1:8765/fast.ts")!, order: 0)
        player.play(channel, minutes: 10, artwork: artwork, programmeTitle: { _ in "Live news" })
        var metadata: TVShelfArtwork?
        for _ in 0..<100 {
            metadata = await artwork.pipeline.artwork(for: TVShelfStore.key(channel.id))
            if metadata?.capturedAt != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(player.liveOffset, 12, "The fixture must deliver media ahead of playback to reproduce the device issue.")
        XCTAssertNotNil(metadata?.capturedAt, "Normal viewing must capture a preview despite provider prefetch.")
        XCTAssertEqual(metadata?.programmeTitle, "Live news")
    }
}

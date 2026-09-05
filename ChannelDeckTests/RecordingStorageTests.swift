import Foundation
import SwiftData
import XCTest
@testable import ChannelDeck

final class RecordingStorageTests: XCTestCase {
    func testCreatesAndResolvesOnlyOwnedRecordingPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckTests-recording-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecordingStorage(rootURL: root)
        let id = UUID()

        let package = try storage.newPackageURL(for: id)
        XCTAssertEqual(package.deletingLastPathComponent(), root.standardizedFileURL)
        XCTAssertEqual(
            try storage.packageURL(named: storage.packageName(for: id)),
            package.standardizedFileURL
        )
        XCTAssertThrowsError(try storage.packageURL(named: "../outside.channeldeckrecording"))
        XCTAssertThrowsError(try storage.packageURL(named: "not-a-uuid.channeldeckrecording"))
        XCTAssertThrowsError(
            try storage.thumbnailURL(
                inPackageNamed: storage.packageName(for: id),
                fileName: "../thumbnail.jpg"
            )
        )
    }

    func testReturnsNativeMediaAndRevealsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckTests-native-recording-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecordingStorage(rootURL: root)
        let id = UUID()
        let package = try storage.newPackageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let media = package.appendingPathComponent(RecordingStorage.mediaFileName)
        try Data("native-media".utf8).write(to: media)
        let packageName = storage.packageName(for: id)

        XCTAssertEqual(try storage.playbackURL(inPackageNamed: packageName), media)
        XCTAssertEqual(try storage.revealURL(inPackageNamed: packageName), media)
    }

    func testMigratesLegacyHLSRecordingInDeclaredSegmentOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckTests-legacy-recording-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecordingStorage(rootURL: root)
        let id = UUID()
        let package = try storage.newPackageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("first".utf8).write(
            to: package.appendingPathComponent("segment-0-000000001.ts")
        )
        try Data("second".utf8).write(
            to: package.appendingPathComponent("segment-0-000000002.ts")
        )
        let playlist = """
        #EXTM3U
        #EXTINF:4,
        segment-0-000000002.ts
        #EXTINF:4,
        segment-0-000000001.ts
        #EXT-X-ENDLIST

        """
        try Data(playlist.utf8).write(
            to: package.appendingPathComponent("media-0.m3u8")
        )

        let playbackURL = try storage.playbackURL(
            inPackageNamed: storage.packageName(for: id)
        )

        XCTAssertEqual(playbackURL.lastPathComponent, RecordingStorage.mediaFileName)
        XCTAssertEqual(try String(contentsOf: playbackURL, encoding: .utf8), "secondfirst")
    }

    func testLegacyMigrationRejectsExternalSegmentReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckTests-unsafe-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RecordingStorage(rootURL: root)
        let id = UUID()
        let package = try storage.newPackageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("#EXTM3U\n../outside.ts\n".utf8).write(
            to: package.appendingPathComponent("media-0.m3u8")
        )

        XCTAssertThrowsError(
            try storage.playbackURL(inPackageNamed: storage.packageName(for: id))
        )
    }

    @MainActor
    func testRecordingMetadataRoundTripsThroughSwiftData() throws {
        let container = try ChannelDeckSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let id = UUID()
        let record = RecordingRecord(
            id: id,
            channelStableID: "channel-id",
            sourceID: UUID(),
            channelName: "Test Channel",
            groupName: "Sports",
            logoURLString: "https://images.example/logo.png",
            programmeTitle: "Test Programme",
            programmeDescription: "Guide description",
            programmeStartDate: Date(timeIntervalSince1970: 100),
            programmeEndDate: Date(timeIntervalSince1970: 200),
            startedAt: Date(timeIntervalSince1970: 110),
            endedAt: Date(timeIntervalSince1970: 170),
            duration: 60,
            packageName: "\(id.uuidString.lowercased()).channeldeckrecording",
            thumbnailFileName: "thumbnail.jpg",
            qualityRawValue: BufferRecordingQuality.sourceVideo.rawValue
        )
        context.insert(record)
        try context.save()

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<RecordingRecord>()).first)
        XCTAssertEqual(stored.id, id)
        XCTAssertEqual(stored.programmeTitle, "Test Programme")
        XCTAssertEqual(stored.duration, 60)
        XCTAssertEqual(stored.thumbnailFileName, "thumbnail.jpg")
        XCTAssertEqual(stored.qualityRawValue, BufferRecordingQuality.sourceVideo.rawValue)
    }
}

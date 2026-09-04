import Foundation
import XCTest
@testable import ChannelDeck

final class SecurityEncryptedPlaylistCacheTests: XCTestCase {
    func testRoundTripKeepsSourceURLsOutOfPlaintextStorage() async throws {
        let keyStore = InMemoryKeychainStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedPlaylistCache(keyStore: keyStore, directoryURL: directory)
        let playlistID = UUID()
        let secretURL = "https://user:very-secret@example.invalid/live/channel"
        let plaintext = Data("#EXTM3U\n#EXTINF:-1,News\n\(secretURL)\n".utf8)

        try await cache.store(plaintext, for: playlistID)

        let loaded = try await cache.load(for: playlistID)
        XCTAssertEqual(loaded, plaintext)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        let onDisk = try Data(contentsOf: file)
        XCTAssertNil(onDisk.range(of: Data(secretURL.utf8)))
        let keyData = await keyStore.storedData(for: playlistID, kind: .playlistCacheKey)
        XCTAssertEqual(keyData?.count, 32)
    }

    func testTamperingIsRejected() async throws {
        let keyStore = InMemoryKeychainStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedPlaylistCache(keyStore: keyStore, directoryURL: directory)
        let playlistID = UUID()

        try await cache.store(Data("#EXTM3U\n".utf8), for: playlistID)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        var encrypted = try Data(contentsOf: file)
        encrypted[encrypted.startIndex] ^= 0xff
        try encrypted.write(to: file, options: .atomic)

        do {
            _ = try await cache.load(for: playlistID)
            XCTFail("Expected authentication to fail")
        } catch {
            XCTAssertEqual(error as? EncryptedPlaylistCacheError, .authenticationFailed)
        }
    }

    func testEnforcesPlaintextSizeLimitBeforeWriting() async throws {
        let keyStore = InMemoryKeychainStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedPlaylistCache(
            keyStore: keyStore,
            directoryURL: directory,
            maximumPlaintextBytes: 3
        )

        do {
            try await cache.store(Data([0, 1, 2, 3]), for: UUID())
            XCTFail("Expected the snapshot to be rejected")
        } catch {
            XCTAssertEqual(error as? EncryptedPlaylistCacheError, .snapshotTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRemovalDeletesSnapshotAndEncryptionKey() async throws {
        let keyStore = InMemoryKeychainStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = EncryptedPlaylistCache(keyStore: keyStore, directoryURL: directory)
        let playlistID = UUID()

        try await cache.store(Data("playlist".utf8), for: playlistID)
        try await cache.remove(for: playlistID)

        let loaded = try await cache.load(for: playlistID)
        let keyData = await keyStore.storedData(for: playlistID, kind: .playlistCacheKey)
        XCTAssertNil(loaded)
        XCTAssertNil(keyData)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckSecurityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor InMemoryKeychainStore: KeychainStoring {
    private var storage: [String: Data] = [:]

    func data(for playlistID: UUID, kind: KeychainSecretKind) -> Data? {
        storage[key(playlistID, kind)]
    }

    func setData(_ data: Data, for playlistID: UUID, kind: KeychainSecretKind) {
        storage[key(playlistID, kind)] = data
    }

    func removeData(for playlistID: UUID, kind: KeychainSecretKind) {
        storage.removeValue(forKey: key(playlistID, kind))
    }

    func removeAll(for playlistID: UUID) {
        for kind in KeychainSecretKind.allCases {
            storage.removeValue(forKey: key(playlistID, kind))
        }
    }

    func storedData(for playlistID: UUID, kind: KeychainSecretKind) -> Data? {
        storage[key(playlistID, kind)]
    }

    private func key(_ playlistID: UUID, _ kind: KeychainSecretKind) -> String {
        "\(playlistID.uuidString).\(kind.rawValue)"
    }
}

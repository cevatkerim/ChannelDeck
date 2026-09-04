import Foundation
import XCTest
@testable import ChannelDeck

final class SecurityKeychainAbstractionTests: XCTestCase {
    func testURLLifecyclePreservesPlaylistAndSecretKindIsolation() async throws {
        let store = KeychainMemoryStore()
        let firstID = UUID()
        let secondID = UUID()
        let playlistURL = try XCTUnwrap(URL(string: "https://user:secret@example.invalid/list.m3u"))
        let epgURL = try XCTUnwrap(URL(string: "https://example.invalid/guide.xml.gz"))

        try await store.setPlaylistURL(playlistURL, for: firstID)
        try await store.setEPGURL(epgURL, for: firstID)
        try await store.setPlaylistURL(epgURL, for: secondID)

        let storedPlaylistURL = try await store.playlistURL(for: firstID)
        let storedEPGURL = try await store.epgURL(for: firstID)
        let otherPlaylistURL = try await store.playlistURL(for: secondID)
        XCTAssertEqual(storedPlaylistURL, playlistURL)
        XCTAssertEqual(storedEPGURL, epgURL)
        XCTAssertEqual(otherPlaylistURL, epgURL)

        try await store.setEPGURL(nil, for: firstID)
        let removedEPGURL = try await store.epgURL(for: firstID)
        XCTAssertNil(removedEPGURL)

        try await store.removeAll(for: firstID)
        let removedPlaylistURL = try await store.playlistURL(for: firstID)
        let preservedPlaylistURL = try await store.playlistURL(for: secondID)
        XCTAssertNil(removedPlaylistURL)
        XCTAssertEqual(preservedPlaylistURL, epgURL)
    }
}

private actor KeychainMemoryStore: KeychainStoring {
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
        storage = storage.filter { !$0.key.hasPrefix(playlistID.uuidString) }
    }

    private func key(_ playlistID: UUID, _ kind: KeychainSecretKind) -> String {
        "\(playlistID.uuidString).\(kind.rawValue)"
    }
}

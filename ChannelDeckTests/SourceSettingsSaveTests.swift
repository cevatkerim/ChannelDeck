import Foundation
import XCTest
@testable import ChannelDeck

@MainActor
final class SourceSettingsSaveTests: XCTestCase {
    func testGuideOnlyEditDoesNotDownloadPlaylistOrChangePlaylistRefreshDate() async throws {
        let source = PlaylistSourceRecord(id: UUID(), displayName: "Existing playlist", sortIndex: 0)
        let oldRefresh = Date(timeIntervalSince1970: 123456)
        source.lastPlaylistRefresh = oldRefresh
        let keychain = SettingsKeychain()
        try await keychain.setPlaylistURL(URL(string: "https://example.invalid/list.m3u")!, for: source.id)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectSettingsNetwork.self]
        let defaults = UserDefaults(suiteName: "SettingsSaveTest-" + UUID().uuidString)!
        let app = AppModel(modelContainer: try ChannelDeckSchema.makeContainer(inMemory: true), keychain: keychain,
                           httpClient: HTTPClient(session: URLSession(configuration: config)), preferenceStore: defaults)
        app.sources = [source]
        await app.beginEditingSource(source)
        app.sourceDraft.guideMode = .automatic
        let saved = await app.commitSourceDraft()
        XCTAssertTrue(saved)
        XCTAssertEqual(app.guidePreferences(for: source.id).mode, .automatic)
        XCTAssertEqual(source.lastPlaylistRefresh, oldRefresh)
        XCTAssertFalse(app.isSavingSource)
        XCTAssertFalse(app.isEditingSource)
    }
}

private actor SettingsKeychain: KeychainStoring {
    var values: [String: Data] = [:]
    func data(for playlistID: UUID, kind: KeychainSecretKind) -> Data? { values[playlistID.uuidString + kind.rawValue] }
    func setData(_ data: Data, for playlistID: UUID, kind: KeychainSecretKind) { values[playlistID.uuidString + kind.rawValue] = data }
    func removeData(for playlistID: UUID, kind: KeychainSecretKind) { values[playlistID.uuidString + kind.rawValue] = nil }
    func removeAll(for playlistID: UUID) { values = values.filter { !$0.key.hasPrefix(playlistID.uuidString) } }
}

private final class RejectSettingsNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Changing guide settings must not re-download the playlist")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

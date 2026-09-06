import CryptoKit
import Foundation

struct TVShelfArtwork: Codable, Sendable {
    static let currentStyle = 2
    let image: String
    let fallback: String
    let capturedAt: Date?
    var preview: String? = nil
    var programmeTitle: String? = nil
    var style: Int? = nil
    func hasRecentFrame(at date: Date = .now) -> Bool {
        style == Self.currentStyle && capturedAt.map { date.timeIntervalSince($0) < 24 * 3600 } == true
    }
    func imageName(at date: Date = .now) -> String {
        hasRecentFrame(at: date) ? image : fallback
    }
    func previewName(at date: Date = .now) -> String {
        hasRecentFrame(at: date) ? (preview ?? image) : fallback
    }
    func previewTitle(at date: Date = .now) -> String? {
        hasRecentFrame(at: date) ? programmeTitle : nil
    }
}

struct TVShelfEntry: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let favorite: Bool
    let artwork: TVShelfArtwork?
    var actionURL: URL { URL(string: "channeldeck://watch/\(id)")! }
}

enum TVShelfStore {
    static let group = "group.com.kerimincedayi.ChannelDeckTV.shared"
    static func key(_ channelID: String) -> String { SHA256.hash(data: Data(channelID.utf8)).map { String(format: "%02x", $0) }.joined() }
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Library/Caches/ChannelDeckShelf", directoryHint: .isDirectory)
    }
    static func channelKey(from url: URL) -> String? {
        guard url.scheme == "channeldeck", url.host == "watch", url.query == nil, url.fragment == nil else { return nil }
        let key = String(url.path.dropFirst())
        guard key.count == 64, key.allSatisfy({ $0.isASCII && ("0123456789abcdef".contains($0)) }) else { return nil }
        return key
    }
    static func read(from directory: URL) -> [TVShelfEntry] {
        guard let data = try? Data(contentsOf: directory.appending(path: "shelf.json")), data.count <= 256 * 1024 else { return [] }
        return (try? JSONDecoder().decode([TVShelfEntry].self, from: data)) ?? []
    }
    static func imageURL(_ name: String, directory: URL) -> URL? {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".jpg") else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

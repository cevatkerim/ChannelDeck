import Foundation

/// A stable, non-secret identifier for a channel within one playlist source.
struct ChannelStableKey: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(sourceID: UUID, tvgID: String?, name: String, group: String?) {
        let components = [
            sourceID.uuidString.lowercased(),
            Self.normalize(tvgID),
            Self.normalize(name),
            Self.normalize(group)
        ]

        // Length prefixes make the representation unambiguous even when a
        // channel name contains the separator used by another implementation.
        rawValue = components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }

        let locale = Locale(identifier: "en_US_POSIX")
        let whitespaceNormalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return whitespaceNormalized
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }
}

struct ParsedPlaylist: Equatable, Sendable {
    let title: String?
    let epgURLs: [URL]
    let channels: [ParsedChannel]
}

/// Reconstructs the in-memory stream lookup from an encrypted playlist cache.
/// No persisted models (or observation callbacks) are needed on the worker task.
enum RuntimeStreamIndex {
    static func build(_ playlist: ParsedPlaylist, sourceID: UUID, channelIDs: Set<String>) throws -> [String: URL] {
        var urls: [String: URL] = [:]
        urls.reserveCapacity(channelIDs.count)
        for (offset, channel) in playlist.channels.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            let url = channel.streamURL
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { continue }
            let key = channel.stableKey(sourceID: sourceID).rawValue
            guard channelIDs.contains(key) else { continue }
            urls[key] = url
        }
        return urls
    }
}

struct ParsedChannel: Equatable, Sendable {
    let tvgID: String?
    let tvgName: String?
    let name: String
    let group: String?
    let logoURL: URL?
    let streamURL: URL
    let order: Int
    let duration: Int?

    func stableKey(sourceID: UUID) -> ChannelStableKey {
        ChannelStableKey(
            sourceID: sourceID,
            tvgID: tvgID,
            name: name,
            group: group
        )
    }
}

struct ParsedProgramme: Codable, Equatable, Sendable {
    let channelID: String
    let title: String
    let subtitle: String?
    let description: String?
    let categories: [String]
    let start: Date
    let end: Date

    func isAiring(at date: Date) -> Bool {
        start <= date && date < end
    }
}

enum ParserError: Error, Equatable, Sendable {
    case invalidTextEncoding
    case missingM3UHeader
    case noPlayableChannels
    case malformedXML
}

extension ParserError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTextEncoding:
            "The playlist is not valid UTF-8 text."
        case .missingM3UHeader:
            "The playlist does not begin with an extended M3U header."
        case .noPlayableChannels:
            "The playlist does not contain any valid channel entries."
        case .malformedXML:
            "The programme guide is not valid XMLTV data."
        }
    }
}

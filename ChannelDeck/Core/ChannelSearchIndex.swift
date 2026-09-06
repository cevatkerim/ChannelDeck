import Foundation

enum SourceURLPolicy {
    static func validatedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func usesUnencryptedTransport(_ value: String) -> Bool {
        validatedURL(from: value)?.scheme?.lowercased() == "http"
    }
}

struct ChannelSearchEntry: Equatable, Sendable {
    let stableID: String
    let normalizedName: String
    let normalizedText: String
    let sourceOrder: Int
    let channelOrder: Int

    init(
        stableID: String,
        channelName: String,
        groupName: String,
        sourceName: String,
        sourceOrder: Int,
        channelOrder: Int
    ) {
        self.stableID = stableID
        normalizedName = ChannelSearchIndex.normalize(channelName)
        normalizedText = ChannelSearchIndex.normalize(
            "\(channelName) \(groupName) \(sourceName)"
        )
        self.sourceOrder = sourceOrder
        self.channelOrder = channelOrder
    }
}

struct ChannelSearchIndex: Equatable, Sendable {
    let entries: [ChannelSearchEntry]

    init(entries: [ChannelSearchEntry] = []) {
        self.entries = entries
    }

    func matchingIDs(for query: String) -> [String] {
        let normalizedQuery = Self.normalize(query)
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }

        return entries
            .filter { entry in
                terms.allSatisfy(entry.normalizedText.contains)
            }
            .sorted { lhs, rhs in
                let leftRank = rank(lhs, query: normalizedQuery)
                let rightRank = rank(rhs, query: normalizedQuery)
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
                if lhs.channelOrder != rhs.channelOrder { return lhs.channelOrder < rhs.channelOrder }
                return lhs.stableID < rhs.stableID
            }
            .map(\.stableID)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func rank(_ entry: ChannelSearchEntry, query: String) -> Int {
        if entry.normalizedName == query { return 0 }
        if entry.normalizedName.hasPrefix(query) { return 1 }
        if entry.normalizedName.contains(query) { return 2 }
        return 3
    }
}

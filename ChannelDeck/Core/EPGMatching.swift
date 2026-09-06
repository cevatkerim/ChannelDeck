import Foundation

enum GuideProviderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist, automatic, openEPG
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playlist: "Playlist / custom URL"
        case .automatic: "Automatic · supplement with Open-EPG"
        case .openEPG: "Open-EPG"
        }
    }
}

struct GuidePreferences: Codable, Equatable, Sendable {
    var mode: GuideProviderMode = .playlist
    /// Stable channel keys, never stream URLs. Empty values explicitly disable matching.
    var overrides: [String: String] = [:]
    var managedChannels: Set<String> = []
}

struct OpenEPGFeed: Decodable, Hashable, Sendable {
    let cou: String
    let url: URL
    let img: String
    var country: String { EPGMatcher.countryCode(img) ?? EPGMatcher.countryCode(cou) ?? img.lowercased() }
    var isAllowed: Bool {
        url.scheme == "https" && url.host == "www.open-epg.com" && url.user == nil
            && url.password == nil && url.query == nil && url.fragment == nil && url.port == nil
            && url.path.hasPrefix("/files/") && url.pathExtension == "xml"
    }
}

struct GuideChannel: Identifiable, Hashable, Sendable {
    let feed: OpenEPGFeed
    let channelID: String
    let name: String
    var id: String { feed.url.absoluteString + "#" + channelID }
}

struct GuideMatchRow: Identifiable, Sendable {
    let id: String
    let name: String
    let country: String?
    let match: GuideChannel?
    let suggestions: [GuideChannel]
    let reason: String
}

enum EPGMatcher {
    private static let locale = Locale(identifier: "en_US_POSIX")
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }
    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            let code = region.identifier.lowercased()
            result[code] = code
            if let name = english.localizedString(forRegionCode: region.identifier) {
                result[fold(name).filter(\.isLetter)] = code
            }
        }
        for (alias, code) in ["turkey":"tr", "turkiye":"tr", "turk":"tr", "uk":"gb",
                              "usa":"us", "unitedkingdom":"gb", "bosnia":"ba", "korea":"kr",
                              "albanien":"al", "belgium":"be", "bosnien":"ba", "danmark":"dk",
                              "ungarn":"hu", "deutschland":"de", "azerbaycan":"az", "czech":"cz",
                              "czechrepublic":"cz", "dominican":"do", "ivorycoast":"ci", "macedonia":"mk",
                              "trinidad":"tt", "uae":"ae", "macau":"mo", "palestine":"ps"] { result[alias] = code }
        return result
    }()
    static func countryCode(_ text: String) -> String? {
        aliases[fold(text).filter(\.isLetter)]
    }
    static func country(for channel: ParsedChannel) -> String? {
        if let id = channel.tvgID, let suffix = id.split(separator: ".").last,
           id.contains("."), suffix.count == 2, let code = countryCode(String(suffix)) { return code }
        let name = channel.name
        if let colon = name.firstIndex(of: ":"), let code = countryCode(String(name[..<colon])) { return code }
        if let start = name.lastIndex(of: "["), let end = name[start...].firstIndex(of: "]"),
           let code = countryCode(String(name[name.index(after: start)..<end])) { return code }
        let group = channel.group ?? ""
        if let code = countryCode(group) { return code }
        if let first = group.split(whereSeparator: { !$0.isLetter }).first { return countryCode(String(first)) }
        return nil
    }
    static func isLive(_ channel: ParsedChannel) -> Bool {
        if let duration = channel.duration, duration > 0 { return false }
        if ["mp4", "mkv", "avi", "mov"].contains(channel.streamURL.pathExtension.lowercased()) { return false }
        if channel.streamURL.path.contains("/movie/") || channel.streamURL.path.contains("/series/") { return false }
        let group = fold(channel.group ?? "")
        let tokens = Set(group.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !tokens.isDisjoint(with: ["vod", "movies", "movie", "films", "film", "series", "serie", "serien", "dizi", "diziler", "sinema", "cinema", "peliculas", "serial", "seriale", "filme", "сериалы", "фильмы"]) { return false }
        // Some providers omit category/URL hints but label every episode explicitly.
        if channel.name.range(of: #"(?i)\bS\d{1,2}\s*E\d{1,3}\b"#, options: .regularExpression) != nil { return false }
        return true
    }
    static func normalized(_ text: String, country: String?) -> String {
        var value = fold(text)
        if let colon = value.firstIndex(of: ":"), countryCode(String(value[..<colon])) != nil {
            value = String(value[value.index(after: colon)...])
        }
        if let dot = value.lastIndex(of: "."), countryCode(String(value[value.index(after: dot)...])) != nil {
            value = String(value[..<dot])
        }
        let tokens = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let quality: Set<String> = ["hd", "sd", "uhd", "fhd", "4k", "8k", "hevc"]
        return tokens.filter { !quality.contains($0) && !(country != nil && countryCode($0) == country) }.joined()
    }
    static func match(_ channel: ParsedChannel, sourceID: UUID, candidates: [GuideChannel], overrides: [String: String], normalizedNames: [String: String] = [:], normalizedIDs: [String: String] = [:]) -> GuideMatchRow {
        let key = channel.stableKey(sourceID: sourceID).rawValue
        let country = country(for: channel)
        func row(_ match: GuideChannel?, _ suggestions: [GuideChannel], _ reason: String) -> GuideMatchRow {
            GuideMatchRow(id: key, name: channel.name, country: country, match: match, suggestions: suggestions, reason: reason)
        }
        if let override = overrides[key] {
            if override.isEmpty { return row(nil, [], "Disabled") }
            let chosen = candidates.first { $0.id == override }
            return row(chosen, [], chosen == nil ? "Saved match unavailable" : "Manual")
        }
        let scoped = candidates.filter { country == nil || $0.feed.country == country }
        let exact = scoped.filter { $0.channelID == channel.tvgID }
        if let first = exact.first, Set(exact.map { $0.feed.country }).count == 1 { return row(first, [], "Exact ID") }
        guard let country else { return row(nil, [], "Country unknown") }
        func guideName(_ guide: GuideChannel) -> String { normalizedNames[guide.id] ?? normalized(guide.name, country: country) }
        // Prefer the visible name over provider IDs: many providers reuse a generic sports ID.
        let name = normalized(channel.name, country: country)
        let names = scoped.filter { guideName($0) == name }
        if let first = names.first, !name.isEmpty {
            let sameFeed = names.filter { $0.feed == first.feed }
            if Set(sameFeed.map(\.channelID)).count > 1 { return row(nil, Array(names.prefix(5)), "Needs review") }
            return row(first, [], "Normalized name")
        }
        let id = normalized(channel.tvgID ?? "", country: country)
        let ids = id.isEmpty ? [] : scoped.filter { (normalizedIDs[$0.id] ?? normalized($0.channelID, country: country)) == id }
        if let first = ids.first, !id.isEmpty,
           digits(name) == digits(guideName(first)),
           similarity(name, guideName(first)) >= 0.92 { return row(first, [], "Normalized ID") }
        let ranked = scoped.map { ($0, guideName($0)) }
            .filter { digits($0.1) == digits(name) && abs($0.1.count - name.count) <= 3 }
            .map { ($0.0, similarity(name, $0.1)) }.filter { $0.1 >= 0.75 }
            .sorted { $0.1 > $1.1 }
        // Fuzzy candidates are suggestions only: local variants and sports suffixes are meaningful.
        return row(nil, Array(ranked.prefix(5).map(\.0)), ranked.isEmpty ? "No match" : "Needs review")
    }
    private static func digits(_ value: String) -> String { value.filter(\.isNumber) }
    private static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

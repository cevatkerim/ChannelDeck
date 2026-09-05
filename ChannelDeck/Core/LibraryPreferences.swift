import Foundation

/// Presentation preferences contain stable catalogue IDs, never provider addresses.
struct LibraryPreferences: Codable, Equatable, Sendable {
    static let defaultsKey = "channelDeck.library.v1"
    var hiddenGroups: [String: Set<String>] = [:]
    var favoriteOrder: [String] = []

    func isGroupVisible(_ group: String, sourceID: UUID) -> Bool {
        !(hiddenGroups[sourceID.uuidString]?.contains(group) ?? false)
    }

    mutating func setGroupVisible(_ visible: Bool, group: String, sourceID: UUID) {
        let key = sourceID.uuidString
        if visible { hiddenGroups[key]?.remove(group) }
        else { hiddenGroups[key, default: []].insert(group) }
        if hiddenGroups[key]?.isEmpty == true { hiddenGroups[key] = nil }
    }

    func orderedFavoriteIDs(_ availableIDs: [String]) -> [String] {
        let available = Set(availableIDs)
        var seen = Set<String>()
        return (favoriteOrder + availableIDs).filter { available.contains($0) && seen.insert($0).inserted }
    }

    mutating func moveFavorites(from offsets: IndexSet, to destination: Int, availableIDs: [String]) {
        let ordered = orderedFavoriteIDs(availableIDs)
        let valid = offsets.filter { ordered.indices.contains($0) }
        let moved = valid.map { ordered[$0] }
        let moving = Set(valid)
        var remaining = ordered.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
        let insertion = min(remaining.count, max(0, destination - valid.filter { $0 < destination }.count))
        remaining.insert(contentsOf: moved, at: insertion)
        favoriteOrder = remaining
    }
}

struct PlaybackPreparation: Equatable {
    enum Kind { case channel, recording }
    let id = UUID()
    let kind: Kind
}

struct PlaybackIssue: Equatable {
    let title: String
    let message: String
    var sourceToRefresh: UUID?
}

/// A two-hour viewport gives programmes useful widths even in a small desktop window.
struct GuideWindow: Hashable, Sendable {
    static let duration: TimeInterval = 2 * 60 * 60
    let start: Date
    var end: Date { start.addingTimeInterval(Self.duration) }

    init(containing date: Date, page: Int = 0) {
        let halfHour = floor(date.timeIntervalSince1970 / 1800) * 1800
        start = Date(timeIntervalSince1970: halfHour + Double(page) * Self.duration)
    }

    func placement(start programmeStart: Date, end programmeEnd: Date) -> (offset: Double, width: Double)? {
        let lower = max(start, programmeStart)
        let upper = min(end, programmeEnd)
        guard upper > lower else { return nil }
        return (lower.timeIntervalSince(start) / Self.duration, upper.timeIntervalSince(lower) / Self.duration)
    }

    func position(of date: Date) -> Double? {
        guard date >= start && date <= end else { return nil }
        return date.timeIntervalSince(start) / Self.duration
    }
}

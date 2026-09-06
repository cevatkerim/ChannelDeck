import Foundation

struct TVChannelGroup: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let name: String
    var id: String { sourceID.uuidString + ":" + name }
    func contains(_ channel: TVChannel) -> Bool { channel.sourceID == sourceID && channel.group == name }
    static func groups(in channels: [TVChannel]) -> [TVChannelGroup] {
        Set(channels.map { TVChannelGroup(sourceID: $0.sourceID, name: $0.group) })
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

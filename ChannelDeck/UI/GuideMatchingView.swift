import SwiftUI

struct GuideMatchingView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var search = ""
    @State private var unmatchedOnly = true
    @State private var selected: GuideMatchRow?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Programme guide matches").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Only live channels are included. Suggestions need your approval; corrections are remembered.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search channels", text: $search)
            Toggle("Show unmatched channels only", isOn: $unmatchedOnly)
            if let result = appModel.guideResults[sourceID] {
                if !result.warnings.isEmpty {
                    Text(result.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                List(result.rows.filter { (!unmatchedOnly || $0.match == nil) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(row.match.map { "\($0.name) · \($0.feed.cou) · \(row.reason)" } ?? row.reason)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose…") { selected = row }
                        Menu {
                            Button("Use automatic matching") { update(nil, row: row) }
                            Button("Don't match this channel") { update("", row: row) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Matching options for \(row.name)")
                    }
                }
            } else { ContentUnavailableView("No matches yet", systemImage: "list.bullet.rectangle", description: Text("Save the playlist with Open-EPG enabled first.")) }
            if appModel.refreshingGuides.contains(sourceID) {
                ProgressView(appModel.guideProgress[sourceID] ?? "Updating guide…").progressViewStyle(.linear)
            }
        }
        .padding(24).frame(width: 680, height: 540)
        .disabled(appModel.refreshingGuides.contains(sourceID))
        .sheet(item: $selected) { row in
            GuideMatchPicker(row: row, candidates: appModel.guideResults[sourceID]?.candidates ?? []) { candidate in
                selected = nil
                update(candidate.id, row: row)
            }
        }
    }
    private func update(_ matchID: String?, row: GuideMatchRow) {
        Task { await appModel.setGuideMatch(matchID, channelID: row.id, sourceID: sourceID) }
    }
}

private struct GuideMatchPicker: View {
    @Environment(\.dismiss) private var dismiss
    let row: GuideMatchRow
    let candidates: [GuideChannel]
    let choose: (GuideChannel) -> Void
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Guide for \(row.name)").font(.headline); Spacer(); Button("Cancel") { dismiss() } }
            TextField("Search downloaded guide channels", text: $search)
            List {
                if search.isEmpty, !row.suggestions.isEmpty {
                    Section("Suggested matches") { ForEach(row.suggestions) { candidate in button(candidate) } }
                }
                Section("Downloaded guides · first 100 results") {
                    ForEach(Array(candidates.filter {
                        search.isEmpty ? ($0.feed.country == row.country) : ($0.name + " " + $0.feed.cou).localizedCaseInsensitiveContains(search)
                    }.prefix(100))) { candidate in button(candidate) }
                }
            }
        }.padding(24).frame(width: 560, height: 440)
    }
    private func button(_ candidate: GuideChannel) -> some View {
        Button { choose(candidate) } label: {
            VStack(alignment: .leading) {
                Text(candidate.name)
                Text(candidate.feed.cou).font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }
}

import SwiftUI

struct TVGuideMatchesView: View {
    @Bindable var library: TVLibrary
    let source: TVSource
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var reviewOnly = true
    @State private var selected: GuideMatchRow?
    @State private var limit = 100
    private var rows: [GuideMatchRow] {
        (library.guideResults[source.id]?.rows ?? []).filter {
            (!reviewOnly || $0.match == nil) && (query.isEmpty || $0.name.localizedStandardContains(query))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                TVHeading(title: "Find the right guide", subtitle: source.name)
                Text("Exact IDs and unambiguous normalized names match automatically. Fuzzy suggestions need your choice.").foregroundStyle(.secondary)
                TextField("Search channel names", text: $query)
                Toggle("Show unmatched channels", isOn: $reviewOnly)
                ForEach(rows.prefix(limit)) { row in
                    Button { selected = row } label: {
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(row.match?.name ?? row.reason).foregroundStyle(.secondary)
                        }
                    }.disabled(library.refreshing.contains(source.id))
                }
                if rows.count > limit { Button("Show more channels") { limit += 100 } }
                if rows.isEmpty { Text("No channels match these filters.").foregroundStyle(.secondary) }
                Button("Done") { dismiss() }
            }.padding(80)
        }
        .sheet(item: $selected) { row in
            TVGuideMatchPicker(row: row, candidates: library.guideResults[source.id]?.candidates ?? []) { id in
                library.setGuideMatch(sourceID: source.id, channelID: row.id, candidateID: id)
                selected = nil
            }
        }
    }
}

private struct TVGuideMatchPicker: View {
    let row: GuideMatchRow
    let candidates: [GuideChannel]
    let choose: (String?) -> Void
    @State private var query = ""
    private var available: [GuideChannel] {
        candidates.filter {
            (row.country == nil || $0.feed.country == row.country) && !row.suggestions.contains($0)
                && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.channelID.localizedStandardContains(query))
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                TVHeading(title: row.name, subtitle: "Open-EPG channel")
                Button("Use automatic matching") { choose(nil) }
                Button("Disable guide matching") { choose("") }
                if !row.suggestions.isEmpty && query.isEmpty {
                    Text("Suggested matches").font(.title2)
                    ForEach(row.suggestions) { candidate in option(candidate) }
                }
                TextField("Search this country’s guide channels", text: $query)
                ForEach(available.prefix(100)) { candidate in option(candidate) }
                if available.count > 100 { Text("Search to narrow down \(available.count) guide channels.").foregroundStyle(.secondary) }
            }.padding(80)
        }
    }
    private func option(_ candidate: GuideChannel) -> some View {
        Button { choose(candidate.id) } label: {
            HStack { Text(candidate.name); Spacer(); Text(candidate.channelID).foregroundStyle(.secondary) }
        }
    }
}

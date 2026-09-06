import SwiftUI

struct TVGuideView: View {
    @Bindable var library: TVLibrary
    let currentChannel: TVChannel?
    let play: (TVChannel) -> Void
    @State private var page = 0
    @State private var query = ""
    @State private var rows: [GuideRow] = []
    @State private var groupID = ""
    @State private var searching = false
    @State private var details: GuideSelection?
    @State private var pendingPlayback: TVChannel?
    private var window: GuideWindow { GuideWindow(containing: .now, page: page) }
    var body: some View {
        // List uses native reusable rows. Keeping the header and each channel
        // as separate rows avoids measuring a several-thousand-channel VStack.
        List {
            header.listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 32, leading: 64, bottom: 24, trailing: 64))
            ForEach(rows) { row in
                guideRow(row).frame(height: 208)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 64, bottom: 12, trailing: 64))
            }
            if rows.isEmpty && !searching {
                ContentUnavailableView("No guide results", systemImage: "calendar", description: Text("Choose another group or search, or add a playlist and guide in Settings."))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .task(id: "\(page)|\(groupID)|\(query)|\(library.revision)") {
            if groupID != "*", !library.groups.contains(where: { $0.id == groupID }),
               let group = library.groups.first(where: { group in currentChannel.map { group.contains($0) } ?? false }) ?? library.groups.first {
                groupID = group.id
                return
            }
            searching = true
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let result = await library.search(query, guide: true, page: page)
            guard !Task.isCancelled else { return }
            let group = library.groups.first { $0.id == groupID }
            let filtered = groupID == "*" ? result : result.filter { group?.contains($0) == true }
            let schedules = library.schedules, window = window
            // Resolve programme ranges away from the main actor even when
            // searching every group. The List creates only onscreen row views.
            let worker = Task.detached {
                filtered.map { channel in
                    GuideRow(channel: channel, programmes: (schedules[channel.id] ?? []).filter { $0.end > window.start && $0.start < window.end })
                }
            }
            let resultRows = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            rows = resultRows
            searching = false
        }
        .sheet(item: $details, onDismiss: {
            if let channel = pendingPlayback { pendingPlayback = nil; play(channel) }
        }) { item in
            VStack(alignment: .leading, spacing: 30) {
                TVHeading(title: item.programme.title, subtitle: item.channel.name)
                Text(item.programme.start, format: .dateTime.weekday().hour().minute())
                ScrollView { Text(item.programme.description ?? "No programme description is available.").font(.body).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Watch channel live", systemImage: "play.fill") { pendingPlayback = item.channel; details = nil }
                    Button("Close") { details = nil }
                }
            }.padding(70)
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            TVHeading(title: "The TV guide", subtitle: "Find your next watch")
            HStack(spacing: 24) {
                Button("Earlier", systemImage: "chevron.left") { page = max(-12, page - 1) }
                Button("Now") { page = 0 }
                Button("Later", systemImage: "chevron.right") { page = min(83, page + 1) }
                Spacer()
                Text(window.start, format: .dateTime.weekday().hour().minute()).foregroundStyle(TVTheme.mint)
                Text("–")
                Text(window.end, style: .time)
            }
            HStack(spacing: 24) {
                Picker("Guide group", selection: $groupID) {
                    if groupID.isEmpty { Text("Choose a group").tag("") }
                    Text("All groups").tag("*")
                    ForEach(library.groups) { group in Text(group.name).tag(group.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("Guide group")
                if searching { ProgressView().accessibilityLabel("Searching guide") }
                Spacer()
                Text("\(rows.count.formatted()) channels").font(.callout).foregroundStyle(.secondary)
            }
            TextField(groupID == "*" ? "Search channels and programmes" : "Search channels and programmes in this group", text: $query).autocorrectionDisabled()
        }
    }
    private func guideRow(_ row: GuideRow) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Button { play(row.channel) } label: {
                VStack(spacing: 12) {
                    TVChannelLogo(url: row.channel.logoURL).frame(height: 45)
                    Text(row.channel.name).font(.callout).lineLimit(2)
                }.frame(width: 220, height: 180)
            }.buttonStyle(.card).accessibilityIdentifier("Guide channel \(row.channel.name)")
            if row.programmes.isEmpty {
                Text("No listings available").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 20) {
                        ForEach(Array(row.programmes.enumerated()), id: \.offset) { _, programme in
                            Button { details = GuideSelection(channel: row.channel, programme: programme) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(programme.start, style: .time).font(.caption).foregroundStyle(TVTheme.mint)
                                    Text(programme.title).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    if programme.isAiring(at: .now) { Text("ON NOW").font(.caption2.weight(.bold)) }
                                }.padding(18).frame(width: 360, height: 180, alignment: .leading)
                                    .tvCardSurface(cornerRadius: 14)
                            }.buttonStyle(.card)
                        }
                    }.padding(8)
                }.frame(height: 208).scrollClipDisabled()
            }
        }
    }
    private struct GuideRow: Identifiable, Sendable {
        let channel: TVChannel
        let programmes: [ParsedProgramme]
        var id: String { channel.id }
    }
    private struct GuideSelection: Identifiable {
        let id = UUID()
        let channel: TVChannel
        let programme: ParsedProgramme
    }
}

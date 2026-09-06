import SwiftUI

struct TVChannelDrawer: View {
    let channels: [TVChannel]
    let groups: [TVChannelGroup]
    let current: TVChannel
    let favoriteIDs: Set<String>
    let play: (TVChannel) -> Void
    let close: () -> Void
    @State private var selectedGroup: TVChannelGroup?
    @State private var favorites = false
    @FocusState private var focusedItem: String?
    private var choosingGroup: Bool { selectedGroup == nil && !favorites }
    private var matches: [TVChannel] {
        channels.filter { favorites ? favoriteIDs.contains($0.preferenceID) : selectedGroup?.contains($0) == true }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Switch channel").font(.title2.bold())
                Spacer()
                Button("Close channels", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            if choosingGroup {
                Text("Choose a group").foregroundStyle(.secondary)
                Button("Favorites", systemImage: "star.fill") { favorites = true }
                    .accessibilityIdentifier("Drawer favorites")
                ScrollViewReader { proxy in
                    List {
                        ForEach(groups) { group in
                            Button { selectedGroup = group } label: {
                                HStack {
                                    Text(group.name).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            }.focused($focusedItem, equals: group.id)
                                .accessibilityIdentifier("Choose group \(group.name)").id(group.id)
                                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        }
                    }.listStyle(.plain)
                    .task {
                        let target = groups.first(where: { $0.contains(current) })?.id ?? groups.first?.id
                        if let target { proxy.scrollTo(target, anchor: .center); await Task.yield(); focusedItem = target }
                    }
                }
            } else {
                Button("Groups", systemImage: "chevron.left") { selectedGroup = nil; favorites = false }
                    .accessibilityIdentifier("Back to groups")
                Text(favorites ? "Favorites" : selectedGroup?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                if matches.isEmpty { Text("No channels here yet.").foregroundStyle(.secondary); Spacer() }
                else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(matches) { channel in
                                Button { play(channel) } label: {
                                    HStack(spacing: 16) {
                                        Image(systemName: channel.id == current.id ? "speaker.wave.2.fill" : "tv").frame(width: 30)
                                        Text(channel.name).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                }.focused($focusedItem, equals: channel.id)
                                    .accessibilityIdentifier("Switch to \(channel.name)").id(channel.id)
                                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            }
                        }.listStyle(.plain)
                        .task {
                            let target = matches.first(where: { $0.id == current.id })?.id ?? matches.first?.id
                            if let target { proxy.scrollTo(target, anchor: .center); await Task.yield(); focusedItem = target }
                        }
                    }
                }
            }
            Text("Select to open · Back to return").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout).buttonStyle(TVActionButtonStyle())
        .padding(36).frame(width: 570)
        .background(TVTheme.forest.opacity(0.97))
        .onExitCommand {
            if choosingGroup { close() } else { selectedGroup = nil; favorites = false }
        }
        .accessibilityIdentifier("Channel drawer")
    }
}

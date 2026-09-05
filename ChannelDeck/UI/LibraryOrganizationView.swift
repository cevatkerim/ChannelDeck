import SwiftUI

struct GroupManagementView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let source: PlaylistSourceRecord
    @State private var query = ""

    private var groups: [String] {
        appModel.groups(for: source.id).filter { query.isEmpty || $0.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("YOUR LINEUP", systemImage: "slider.horizontal.3").deckEyebrow()
                Text("A little more you.")
                    .font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text("Choose the groups you want to browse in \(source.displayName). Favorites and history stay within reach.")
                    .font(.system(size: 12)).foregroundStyle(ChannelDeckStyle.muted).lineSpacing(3)
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Find a group", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("Find a group")
                    if !query.isEmpty {
                        Button("Clear filter", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(ChannelDeckStyle.muted)
                .padding(12).background(ChannelDeckStyle.inset, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
            }
            .padding(26)
            List(groups, id: \.self) { group in
                Toggle(isOn: Binding(
                    get: { appModel.libraryPreferences.isGroupVisible(group, sourceID: source.id) },
                    set: { appModel.setGroupVisible($0, group: group, sourceID: source.id) }
                )) {
                    Label(group, systemImage: "square.stack")
                        .font(.system(size: 12)).lineLimit(2)
                }
                .toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(group)
                .padding(.vertical, 5)
                .listRowSeparator(.hidden)
                .accessibilityHint("Show or hide this group in channel browsing and the TV guide")
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .overlay {
                if groups.isEmpty {
                    DeckEmptyState(symbol: "magnifyingglass", title: "No matching groups", message: "Try a different group name.")
                }
            }
            HStack {
                Button("Show all groups") { appModel.libraryPreferences.hiddenGroups[source.id.uuidString] = nil }
                    .buttonStyle(DeckButtonStyle())
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(DeckButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 510, height: min(600, 300 + CGFloat(appModel.groups(for: source.id).count) * 48))
        .foregroundStyle(ChannelDeckStyle.ink)
        .background(ChannelDeckStyle.canvas).tint(ChannelDeckStyle.accent)
    }
}

struct FavoriteOrganizationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("YOUR FAVORITES", systemImage: "star").deckEyebrow()
                Text("Put the good stuff first.")
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).tracking(-0.6)
                Text("Drag to arrange your channels, or use the arrows.")
                    .font(.system(size: 12)).foregroundStyle(ChannelDeckStyle.muted)
            }
            .padding(26)
            let favorites = appModel.favoriteChannels
            List {
                ForEach(favorites, id: \.stableID) { channel in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(ChannelDeckStyle.muted)
                            .accessibilityHidden(true)
                        ChannelLogoView(channel: channel, size: 32)
                        Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Move \(channel.name) up", systemImage: "chevron.up") { appModel.moveFavorite(channel, by: -1) }
                            .disabled(favorites.first?.stableID == channel.stableID)
                        Button("Move \(channel.name) down", systemImage: "chevron.down") { appModel.moveFavorite(channel, by: 1) }
                            .disabled(favorites.last?.stableID == channel.stableID)
                    }
                    .labelStyle(.iconOnly).buttonStyle(DeckIconButtonStyle())
                    .accessibilityElement(children: .contain)
                    .padding(.vertical, 6).listRowSeparator(.hidden)
                }
                .onMove { appModel.moveFavorites(from: $0, to: $1) }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            HStack {
                Text("Your order is saved automatically.")
                    .font(.system(size: 11)).foregroundStyle(ChannelDeckStyle.muted)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(DeckButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 510, height: 550).background(ChannelDeckStyle.canvas).tint(ChannelDeckStyle.accent)
    }
}

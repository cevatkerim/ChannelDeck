import SwiftUI

struct ChannelBrowserView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Group {
            if appModel.sources.isEmpty {
                ContentUnavailableView {
                    Label("Add Your First Playlist", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("ChannelDeck keeps credential-bearing playlist URLs in your Mac keychain.")
                } actions: {
                    Button("Add Playlist") { appModel.beginAddingSource() }
                        .buttonStyle(.borderedProminent)
                }
            } else if appModel.filteredChannels.isEmpty {
                ContentUnavailableView.search(text: appModel.searchText)
            } else {
                List(appModel.filteredChannels, id: \.stableID, selection: $appModel.selectedChannelID) { channel in
                    ChannelRow(channel: channel)
                        .tag(channel.stableID)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(
                                channel.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: channel.isFavorite ? "star.slash" : "star"
                            ) {
                                appModel.toggleFavorite(channel)
                            }
                            Button("Play", systemImage: "play.fill") {
                                appModel.play(channel)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(appModel.browserTitle)
        .frame(minWidth: ChannelDeckStyle.browserMinimumWidth)
        .searchable(text: $appModel.searchText, placement: .toolbar, prompt: "Channels or programmes")
        .onChange(of: appModel.selectedChannelID) { _, newValue in
            guard let newValue, let channel = appModel.channel(withID: newValue) else { return }
            appModel.play(channel)
        }
    }
}
private struct ChannelRow: View {
    @Environment(AppModel.self) private var appModel
    let channel: ChannelRecord

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogoView(channel: channel)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                    if appModel.isPlaying(channel) {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Playing")
                    }
                }

                if let current = appModel.currentProgramme(for: channel) {
                    Text(current.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No schedule data")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Button(channel.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: channel.isFavorite ? "star.fill" : "star") {
                appModel.toggleFavorite(channel)
            }
            .buttonStyle(.plain)
            .foregroundStyle(channel.isFavorite ? Color.accentColor : .secondary)
            .labelStyle(.iconOnly)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        List(selection: $appModel.sidebarSelection) {
            Section("Library") {
                Label("Favorites", systemImage: "star.fill")
                    .tag(SidebarSelection.favorites)
                    .accessibilityLabel("Favorite channels")
                Label("Recently Watched", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSelection.recents)
                Label("Recordings", systemImage: "record.circle")
                    .tag(SidebarSelection.recordings)
                    .accessibilityLabel("Saved recordings")
            }

            ForEach(appModel.sources, id: \.id) { source in
                Section {
                    Label("All Channels", systemImage: "rectangle.grid.1x2")
                        .tag(SidebarSelection.source(source.id))

                    ForEach(appModel.groups(for: source.id), id: \.self) { group in
                        Label(group, systemImage: "square.stack.3d.up")
                            .lineLimit(1)
                            .tag(SidebarSelection.group(source.id, group))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(source.displayName)
                            .lineLimit(1)
                        if appModel.refreshingSourceIDs.contains(source.id) {
                            ProgressView().controlSize(.mini)
                        }
                        if let message = source.lastErrorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(message)
                                .accessibilityLabel("Playlist needs attention: \(message)")
                        }
                    }
                }
                .contextMenu {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await appModel.refresh(sourceID: source.id, force: true) }
                    }
                    Button("Edit…", systemImage: "pencil") {
                        Task { await appModel.beginEditingSource(source) }
                    }
                    Menu("Move", systemImage: "arrow.up.arrow.down") {
                        Button("Move Up", systemImage: "arrow.up") {
                            appModel.moveSource(id: source.id, offset: -1)
                        }
                        .disabled(!appModel.canMoveSource(id: source.id, offset: -1))
                        Button("Move Down", systemImage: "arrow.down") {
                            appModel.moveSource(id: source.id, offset: 1)
                        }
                        .disabled(!appModel.canMoveSource(id: source.id, offset: 1))
                    }
                    Divider()
                    Button("Remove…", systemImage: "trash", role: .destructive) {
                        appModel.requestRemoval(of: source)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ChannelDeck")
        .frame(minWidth: ChannelDeckStyle.sidebarMinimumWidth)
        .toolbar {
            ToolbarItemGroup {
                Button("Add Playlist", systemImage: "plus") {
                    appModel.beginAddingSource()
                }
                .help("Add a playlist")

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appModel.refreshSelection(force: true) }
                }
                .help("Refresh selected playlist")
                .disabled(appModel.sourceID(for: appModel.sidebarSelection) == nil)
            }
        }
    }
}

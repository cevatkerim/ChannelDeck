import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @State private var expandedSourceIDs: Set<UUID> = []

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
                DisclosureGroup(isExpanded: expansionBinding(for: source.id)) {
                    Label("All Channels", systemImage: "rectangle.grid.1x2")
                        .tag(SidebarSelection.source(source.id))

                    ForEach(appModel.groups(for: source.id), id: \.self) { group in
                        Label(group, systemImage: "square.stack.3d.up")
                            .lineLimit(1)
                            .tag(SidebarSelection.group(source.id, group))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(source.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if appModel.refreshingSourceIDs.contains(source.id) {
                            ProgressView().controlSize(.mini)
                        }
                        if let message = source.lastErrorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help(message)
                                .accessibilityLabel("Playlist needs attention: \(message)")
                        }
                        Text(appModel.channelCount(for: source.id), format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("\(appModel.channelCount(for: source.id)) channels")
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
        .onAppear {
            expandCurrentOrFirstSource()
        }
        .onChange(of: appModel.sidebarSelection) { _, _ in
            guard let sourceID = appModel.sourceID(for: appModel.sidebarSelection) else { return }
            expandedSourceIDs.insert(sourceID)
        }
        .onChange(of: appModel.sources.map(\.id)) { _, sourceIDs in
            expandedSourceIDs.formIntersection(Set(sourceIDs))
            expandCurrentOrFirstSource()
        }
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

    private func expansionBinding(for sourceID: UUID) -> Binding<Bool> {
        Binding {
            expandedSourceIDs.contains(sourceID)
        } set: { isExpanded in
            if isExpanded {
                expandedSourceIDs.insert(sourceID)
            } else {
                expandedSourceIDs.remove(sourceID)
            }
        }
    }

    private func expandCurrentOrFirstSource() {
        if let sourceID = appModel.sourceID(for: appModel.sidebarSelection) {
            expandedSourceIDs.insert(sourceID)
        } else if expandedSourceIDs.isEmpty, let sourceID = appModel.sources.first?.id {
            expandedSourceIDs.insert(sourceID)
        }
    }
}

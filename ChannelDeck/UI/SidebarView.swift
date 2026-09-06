import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @State private var expandedSourceIDs: Set<UUID> = []
    @State private var groupFilters: [UUID: String] = [:]
    @State private var managedSource: PlaylistSourceRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DeckMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChannelDeck")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(ChannelDeckStyle.ink)
                    Text("A little closer to live.")
                        .font(.system(size: 10))
                        .foregroundStyle(ChannelDeckStyle.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 19)
            .padding(.top, 19)
            .padding(.bottom, 30)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR LIBRARY").deckEyebrow()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    navigationRow("TV guide", symbol: "calendar.day.timeline.left", selection: .guide)
                    navigationRow("Favorites", symbol: "star", selection: .favorites)
                    navigationRow("Recently watched", symbol: "clock.arrow.circlepath", selection: .recents)
                    navigationRow(
                        "Recordings", symbol: "record.circle", selection: .recordings,
                        count: appModel.recordings.count)

                    HStack {
                        Text("PLAYLISTS").deckEyebrow()
                        Spacer()
                        Button("Add Playlist", systemImage: "plus") { appModel.beginAddingSource() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(DeckIconButtonStyle())
                            .help("Add a playlist")
                    }
                    .padding(.leading, 12)
                    .padding(.top, 24)
                    .padding(.bottom, 4)

                    ForEach(appModel.sources, id: \.id) { source in
                        sourceSection(source)
                    }

                    if appModel.sources.isEmpty {
                        Text("Your playlists will feel at home here.")
                            .font(.system(size: 12))
                            .foregroundStyle(ChannelDeckStyle.muted)
                            .lineSpacing(4)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 16) {
                Button {
                    appModel.beginAddingSource()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus.circle")
                        Text("Add playlist")
                        Spacer()
                        Text("⇧⌘N").font(.system(size: 10)).foregroundStyle(ChannelDeckStyle.muted)
                    }
                }
                .buttonStyle(DeckButtonStyle())
                HStack {
                    Label("Made for your Mac", systemImage: "desktopcomputer")
                        .font(.system(size: 10))
                        .foregroundStyle(ChannelDeckStyle.muted)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(DeckIconButtonStyle())
                        .foregroundStyle(ChannelDeckStyle.muted)
                        .help("ChannelDeck Settings")
                        .accessibilityLabel("ChannelDeck Settings")
                }
            }
            .padding(18)
            .background(ChannelDeckStyle.sidebar)
        }
        .background(ChannelDeckStyle.sidebar)
        .sheet(item: $managedSource) { source in GroupManagementView(source: source) }
        .navigationTitle("")
        .navigationSplitViewColumnWidth(min: 200, ideal: 226, max: 290)
        .onAppear { expandCurrentOrFirstSource() }
        .onChange(of: appModel.sidebarSelection) { _, _ in
            guard let sourceID = appModel.sourceID(for: appModel.sidebarSelection) else { return }
            expandedSourceIDs.insert(sourceID)
        }
        .onChange(of: appModel.sources.map(\.id)) { _, sourceIDs in
            expandedSourceIDs.formIntersection(Set(sourceIDs))
            expandCurrentOrFirstSource()
        }
    }

    private func navigationRow(_ title: String, symbol: String, selection: SidebarSelection, count: Int? = nil)
        -> some View
    {
        SidebarNavigationButton(
            title: title, symbol: symbol,
            isSelected: appModel.sidebarSelection == selection, count: count
        ) {
            appModel.searchText = ""
            appModel.sidebarSelection = selection
        }
    }

    private func sourceSection(_ source: PlaylistSourceRecord) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Button {
                    if expandedSourceIDs.contains(source.id) {
                        expandedSourceIDs.remove(source.id)
                    } else {
                        expandedSourceIDs.insert(source.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expandedSourceIDs.contains(source.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 12)
                        Text(source.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(appModel.channelCount(for: source.id), format: .number)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(ChannelDeckStyle.muted)
                    }
                    .frame(minHeight: 35)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(source.displayName), \(appModel.channelCount(for: source.id)) channels")
                .accessibilityValue(expandedSourceIDs.contains(source.id) ? "Expanded" : "Collapsed")
                if let message = source.lastErrorMessage {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .help(message)
                        .accessibilityLabel("Playlist needs attention: \(message)")
                }
                if appModel.refreshingSourceIDs.contains(source.id) || appModel.refreshingGuides.contains(source.id) {
                    ProgressView().controlSize(.mini).frame(width: 30)
                        .accessibilityLabel("Refreshing \(source.displayName)")
                } else {
                    Button("Refresh playlist \(source.displayName)", systemImage: "arrow.clockwise") {
                        Task { await appModel.refresh(sourceID: source.id, force: true) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(DeckIconButtonStyle())
                    .foregroundStyle(ChannelDeckStyle.muted)
                    .help("Refresh \(source.displayName)")
                }
            }
            .padding(.leading, 10)
            .contextMenu {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await appModel.refresh(sourceID: source.id, force: true) }
                }
                Button("Organize groups…", systemImage: "slider.horizontal.3") { managedSource = source }
                Button("Edit…", systemImage: "pencil") {
                    Task { await appModel.beginEditingSource(source) }
                }
                Button("Move Up", systemImage: "arrow.up") { appModel.moveSource(id: source.id, offset: -1) }
                    .disabled(!appModel.canMoveSource(id: source.id, offset: -1))
                Button("Move Down", systemImage: "arrow.down") { appModel.moveSource(id: source.id, offset: 1) }
                    .disabled(!appModel.canMoveSource(id: source.id, offset: 1))
                Divider()
                Button("Remove…", systemImage: "trash", role: .destructive) { appModel.requestRemoval(of: source) }
            }

            if let status = appModel.guideProgress[source.id] {
                ProgressView(status)
                    .progressViewStyle(.linear)
                    .font(.system(size: 10))
                    .foregroundStyle(ChannelDeckStyle.muted)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .help(status)
            }
            if expandedSourceIDs.contains(source.id) {
                navigationRow("All channels", symbol: "rectangle.grid.1x2", selection: .source(source.id))
                let allGroups = appModel.groups(for: source.id)
                if allGroups.count > 6 {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                        TextField("Filter groups", text: Binding(
                            get: { groupFilters[source.id] ?? "" },
                            set: { groupFilters[source.id] = $0 }
                        ))
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .accessibilityLabel("Filter groups in \(source.displayName)")
                        if !(groupFilters[source.id] ?? "").isEmpty {
                            Button("Clear group filter", systemImage: "xmark.circle.fill") { groupFilters[source.id] = "" }
                                .labelStyle(.iconOnly).buttonStyle(.plain)
                        }
                    }
                    .foregroundStyle(ChannelDeckStyle.muted).padding(10)
                    .background(ChannelDeckStyle.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 6).padding(.vertical, 5)
                }
                let visibleGroups = allGroups.filter {
                    appModel.libraryPreferences.isGroupVisible($0, sourceID: source.id)
                        && ((groupFilters[source.id] ?? "").isEmpty || $0.localizedStandardContains(groupFilters[source.id] ?? ""))
                }
                ForEach(visibleGroups, id: \.self) { group in
                    navigationRow(group, symbol: "square.stack", selection: .group(source.id, group))
                        .contextMenu {
                            Button("Hide group", systemImage: "eye.slash") {
                                appModel.setGroupVisible(false, group: group, sourceID: source.id)
                            }
                        }
                }
                if visibleGroups.isEmpty, !(groupFilters[source.id] ?? "").isEmpty {
                    Text("No matching groups").font(.system(size: 11)).foregroundStyle(ChannelDeckStyle.muted).padding(10)
                }
                Button { managedSource = source } label: {
                    Label("Organize groups", systemImage: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ChannelDeckStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 10)
    }

    private func expandCurrentOrFirstSource() {
        if let sourceID = appModel.sourceID(for: appModel.sidebarSelection) {
            expandedSourceIDs.insert(sourceID)
        } else if expandedSourceIDs.isEmpty, let sourceID = appModel.sources.first?.id {
            expandedSourceIDs.insert(sourceID)
        }
    }
}

private struct SidebarNavigationButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let count: Int?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text(count, format: .number).font(.system(size: 10).monospacedDigit())
                }
            }
            .foregroundStyle(isSelected ? ChannelDeckStyle.accent : ChannelDeckStyle.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                isSelected ? ChannelDeckStyle.accentSoft : (isHovered ? ChannelDeckStyle.line.opacity(0.4) : .clear),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

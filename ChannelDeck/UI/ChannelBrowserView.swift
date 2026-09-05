import SwiftUI

struct ChannelBrowserView: View {
    @Environment(AppModel.self) private var appModel

    @AppStorage("channelDeck.density") private var density: DeckDensity = .comfortable
    @State private var arrangingFavorites = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var appModel = appModel
        let filteredChannels = appModel.filteredChannels
        let isGlobalSearch = appModel.isGlobalChannelSearchActive

        VStack(spacing: 0) {
            browserHeader
            Group {
                if appModel.sidebarSelection == .recordings {
                    recordingsContent
                } else if appModel.sources.isEmpty {
                    VStack(spacing: 0) {
                        DeckEmptyState(
                            symbol: "rectangle.stack.badge.plus", title: "Your TV starts here",
                            message: "Connect a playlist to bring your channels together in one place.")
                        Button("Add playlist") { appModel.beginAddingSource() }
                            .buttonStyle(DeckButtonStyle(prominent: true))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isGlobalSearch, appModel.isSearchingChannels {
                    ProgressView("Searching all channels…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Searching all channels")
                } else if filteredChannels.isEmpty {
                    channelEmptyState
                } else {
                    List(filteredChannels, id: \.stableID, selection: $appModel.selectedChannelID) { channel in
                        ChannelRow(
                            channel: channel,
                            searchContext: isGlobalSearch ? appModel.searchContext(for: channel) : nil
                        )
                        .tag(channel.stableID)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(
                                channel.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: channel.isFavorite ? "star.slash" : "star"
                            ) {
                                appModel.toggleFavorite(channel)
                            }
                            Button("Play", systemImage: "play.fill") { appModel.play(channel) }
                            if appModel.sidebarSelection == .favorites {
                                Divider()
                                Button("Arrange favorites…", systemImage: "arrow.up.arrow.down") { arrangingFavorites = true }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(ChannelDeckStyle.surface)
        .sheet(isPresented: $arrangingFavorites) { FavoriteOrganizationView() }
        .navigationTitle("")
        .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 440)
        .onChange(of: appModel.selectedChannelID) { _, newValue in
            guard let newValue, let channel = appModel.channel(withID: newValue) else { return }
            appModel.play(channel)
        }
        .onChange(of: appModel.selectedRecordingID) { _, newValue in
            guard appModel.sidebarSelection == .recordings,
                let newValue,
                let recording = appModel.recordings.first(where: { $0.id == newValue })
            else {
                return
            }
            appModel.play(recording)
        }
    }

    private var browserHeader: some View {
        @Bindable var appModel = appModel
        let isRecordings = appModel.sidebarSelection == .recordings
        let count = isRecordings ? appModel.filteredRecordings.count : appModel.filteredChannels.count

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isRecordings ? "SAVED FOR LATER" : "LIVE TELEVISION").deckEyebrow()
                    Spacer()
                    Menu {
                        Picker("Reading density", selection: $density) {
                            ForEach(DeckDensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if appModel.sidebarSelection == .favorites {
                            Divider()
                            Button("Arrange favorites…", systemImage: "arrow.up.arrow.down") { arrangingFavorites = true }
                                .disabled(appModel.favoriteChannels.isEmpty)
                        }
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Library display options").accessibilityLabel("Library display options")
                }
                Text(appModel.isGlobalChannelSearchActive ? "Search results" : appModel.browserTitle)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(ChannelDeckStyle.ink)
                    .lineLimit(2)
                Text(
                    "\(count.formatted()) \(isRecordings ? (count == 1 ? "recording" : "recordings") : (count == 1 ? "channel" : "channels")) · \(browserSubtitle)"
                )
                .font(.system(size: 11))
                .foregroundStyle(ChannelDeckStyle.muted)
            }
            HStack(spacing: 8) {
                Button("Search", systemImage: "magnifyingglass") { isSearchFocused = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search (⌘F)")
                TextField(isRecordings ? "Search recordings" : "Search all channels", text: $appModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .accessibilityLabel(isRecordings ? "Search recordings" : "Search all channels")
                if !appModel.searchText.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { appModel.searchText = "" }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                } else {
                    Text("⌘F").font(.system(size: 10)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(ChannelDeckStyle.muted)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(ChannelDeckStyle.inset, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSearchFocused ? ChannelDeckStyle.accent : .clear, lineWidth: 1.5)
            }
        }
        .padding(22)
        .padding(.top, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(ChannelDeckStyle.line).frame(height: 1) }
    }

    private var browserSubtitle: String {
        if appModel.isGlobalChannelSearchActive { return "Across all your playlists" }
        return switch appModel.sidebarSelection {
        case .favorites: "Your personal lineup"
        case .recents: "Back to the good stuff"
        case .recordings: "Ready when you are"
        default: "Find your next watch"
        }
    }

    private var channelEmptyState: some View {
        Group {
            if !appModel.searchText.isEmpty {
                DeckEmptyState(
                    symbol: "magnifyingglass", title: "No channels found",
                    message: "Try another channel name, group, or playlist.")
            } else if appModel.sidebarSelection == .favorites {
                DeckEmptyState(
                    symbol: "star", title: "Make it your lineup",
                    message: "Star a channel to keep it close. Your favorites will appear here.")
            } else if appModel.sidebarSelection == .recents {
                DeckEmptyState(
                    symbol: "clock.arrow.circlepath", title: "Pick up where you left off",
                    message: "The channels you watch will appear here, ready for next time.")
            } else {
                DeckEmptyState(
                    symbol: "rectangle.stack", title: "No channels here yet",
                    message: "Refresh this playlist to check for available channels.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var recordingsContent: some View {
        @Bindable var appModel = appModel
        let recordings = appModel.filteredRecordings

        if recordings.isEmpty, !appModel.searchText.isEmpty {
            DeckEmptyState(
                symbol: "magnifyingglass", title: "No recordings found",
                message: "Try another programme or channel name."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if recordings.isEmpty {
            DeckEmptyState(
                symbol: "record.circle", title: "Keep a good moment",
                message: "Choose Record while watching. Your recording will be ready here when you finish."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(recordings, id: \.id, selection: $appModel.selectedRecordingID) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Play", systemImage: "play.fill") {
                            appModel.play(recording)
                        }
                        Button("Show in Finder", systemImage: "folder") {
                            appModel.revealRecording(recording)
                        }
                        Divider()
                        Button("Delete…", systemImage: "trash", role: .destructive) {
                            appModel.requestRemoval(of: recording)
                        }
                    }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct RecordingRow: View {
    @AppStorage("channelDeck.density") private var density: DeckDensity = .comfortable
    @Environment(AppModel.self) private var appModel
    let recording: RecordingRecord

    var body: some View {
        HStack(spacing: 12) {
            RecordingThumbnailView(recording: recording, width: 76, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.programmeTitle ?? recording.channelName)
                    .font(.system(size: density.titleSize, weight: .semibold))
                    .lineLimit(1)
                Text("\(recording.channelName) · \(recording.endedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: density.subtitleSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(recordingSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, density.rowPadding)
        .accessibilityElement(children: .contain)
    }

    private var durationText: String {
        let total = max(0, Int(recording.duration.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private var recordingSummary: String {
        guard let rawValue = recording.qualityRawValue,
            let quality = BufferRecordingQuality(rawValue: rawValue)
        else {
            return durationText
        }
        return "\(durationText) · \(quality.compactTitle)"
    }
}

struct RecordingThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    let recording: RecordingRecord
    var width: CGFloat
    var height: CGFloat
    @State private var thumbnail: ChannelLogoImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail.cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                ChannelLogoView(
                    name: recording.channelName,
                    logoURLString: recording.logoURLString,
                    size: min(width, height)
                )
            }
        }
        .frame(width: width, height: height)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: appModel.recordingThumbnailURL(for: recording)?.path) {
            thumbnail = nil
            guard let url = appModel.recordingThumbnailURL(for: recording) else { return }
            thumbnail = await ChannelLogoImageCache.shared.image(
                forLocalFile: url,
                maximumPixelSize: Int(max(width, height) * 2)
            )
        }
    }
}

private struct ChannelRow: View {
    @AppStorage("channelDeck.density") private var density: DeckDensity = .comfortable
    @Environment(AppModel.self) private var appModel
    let channel: ChannelRecord
    let searchContext: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogoView(channel: channel, size: density.logoSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(channel.name)
                        .font(.system(size: density.titleSize, weight: .semibold))
                        .lineLimit(1)
                    if appModel.isPlaying(channel) {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Playing")
                    }
                }

                if let searchContext {
                    Text(searchContext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let current = appModel.currentProgramme(for: channel) {
                    Text(current.title)
                        .font(.system(size: density.subtitleSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if appModel.isLoadingProgrammeGuide {
                    Text("Loading schedule…")
                        .font(.system(size: density.subtitleSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(channel.groupName.isEmpty ? "Ready to watch" : channel.groupName)
                        .lineLimit(1)
                        .font(.system(size: density.subtitleSize))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button(
                channel.isFavorite ? "Remove Favorite" : "Add Favorite",
                systemImage: channel.isFavorite ? "star.fill" : "star"
            ) {
                appModel.toggleFavorite(channel)
            }
            .buttonStyle(DeckIconButtonStyle())
            .foregroundStyle(
                appModel.selectedChannelID == channel.stableID
                    ? Color.primary : (channel.isFavorite ? ChannelDeckStyle.accent : Color.secondary)
            )
            .help(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, density.rowPadding)
        .accessibilityElement(children: .contain)
    }
}

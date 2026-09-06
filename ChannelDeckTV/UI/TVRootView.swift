import SwiftUI

enum TVTheme {
    static let mint = Color(red: 0.57, green: 0.93, blue: 0.76)
    static let forest = Color(red: 0.035, green: 0.10, blue: 0.085)
    static let panel = Color(red: 0.075, green: 0.16, blue: 0.135)
    static var background: some View {
        LinearGradient(colors: [panel, forest, .black], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
}

extension View {
    func tvCardSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Keep the label's clipping and the system card platter identical.
        // Clipping the Button itself would also cut off its focus animation.
        return background(TVTheme.panel, in: shape)
            .clipShape(shape)
            .contentShape([.interaction, .hoverEffect, .contextMenuPreview], shape)
    }
}

struct TVRootView: View {
    @Bindable var library: TVLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = TVPlaybackController()
    @State private var selectedTab = 0
    @State private var pendingShelfURL: URL?
#if DEBUG
    @State private var preparedDevelopmentSetup = false
#endif
    var body: some View {
        TabView(selection: $selectedTab) {
            TVChannelBrowser(library: library, title: "Your channels", mode: .all, play: tune)
                .overlay(alignment: .bottomTrailing) { miniPlayer(in: 0) }
                .tabItem {
                    Label {
                        Text("Channels")
                    } icon: {
                        Image(systemName: "tv")
                            .renderingMode(.template)
                            .symbolRenderingMode(.monochrome)
                    }
                }.tag(0)
            TVChannelBrowser(library: library, title: "Your front row", mode: .favorites, play: tune)
                .overlay(alignment: .bottomTrailing) { miniPlayer(in: 1) }
                .tabItem { Label("Favorites", systemImage: "star") }.tag(1)
            TVGuideView(library: library, currentChannel: player.channel, play: tune)
                .overlay(alignment: .bottomTrailing) { miniPlayer(in: 2) }
                .tabItem { Label("Guide", systemImage: "calendar") }.tag(2)
            TVChannelBrowser(library: library, title: "Find something to watch", mode: .search, play: tune)
                .overlay(alignment: .bottomTrailing) { miniPlayer(in: 3) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(3)
            TVSettingsView(library: library)
                .overlay(alignment: .bottomTrailing) { miniPlayer(in: 4) }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
        .background(TVTheme.background)
        .onOpenURL { url in pendingShelfURL = url }
        .task(id: pendingShelfURL) { await openShelfChannel() }
        .task(id: "\(library.revision)|\(library.state.recents)|\(library.state.favorites.sorted())") {
            await library.artwork.updateShelf(library.shelfChannels, favoriteIDs: library.state.favorites)
        }
        .buttonStyle(TVActionButtonStyle())
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                library.advanceGuideClock()
            }
        }
        .task {
            await library.bootstrap()
#if DEBUG
            guard !preparedDevelopmentSetup else { return }
            preparedDevelopmentSetup = true
            // Explicit development launch option; never add sample content to a release library.
            if ProcessInfo.processInfo.arguments.contains("--fixture") {
                let fixture = ProcessInfo.processInfo.arguments.contains("--fixture-large") ? "large-playlist.m3u" : "playlist.m3u"
                do { try await library.save(source: library.sources.first { $0.name == "Playback lab" }, name: "Playback lab", playlist: "http://127.0.0.1:8765/\(fixture)", guide: "", mode: .playlist) }
                catch { library.notice = TVLibrary.safeMessage(error) }
            }
            if ProcessInfo.processInfo.arguments.contains("--fixture-autoplay") {
                let large = ProcessInfo.processInfo.arguments.contains("--fixture-large")
                for _ in 0..<100 {
                    // Wait for the requested fixture, not the previously cached
                    // small/large playlist while its replacement is importing.
                    if let channel = library.channels.first(where: { $0.name == "Synthetic MPEG-TS" && ($0.streamURL.query != nil) == large }) { tune(channel); break }
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                }
            }
            if let setup = TVDevelopmentProbe.takeSetup() {
                do {
                    try await library.save(source: library.sources.first { $0.name == setup.name }, name: setup.name, playlist: setup.playlist, guide: "", mode: .openEPG)
                    if let channelName = setup.channelName {
                        for _ in 0..<300 {
                            if let channel = library.channels.first(where: { $0.name == channelName }) {
                                tune(channel)
                                Task { await TVDevelopmentProbe.run(player: player, library: library, seconds: setup.probeSeconds ?? 0, interruptAtSeconds: setup.interruptAtSeconds) }
                                break
                            }
                            try await Task.sleep(for: .seconds(1))
                        }
                    }
                } catch { library.notice = TVLibrary.safeMessage(error) }
            }
#endif
        }
        .fullScreenCover(isPresented: Binding(get: { player.isFullscreenPresented }, set: { if !$0 { player.dismissFullscreen() } }), onDismiss: { player.fullscreenDidDismiss() }) {
            if let channel = player.channel {
                TVPlayerView(player: player, channel: channel, library: library).id(channel.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.stop() }
        }
        .onPlayPauseCommand { if player.isMinimized { player.togglePause() } }
        .alert("ChannelDeck", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("OK") { library.notice = nil }
        } message: { Text(library.notice ?? "") }
    }
    private func openShelfChannel() async {
        guard let url = pendingShelfURL else { return }
        guard TVShelfStore.channelKey(from: url) != nil else { pendingShelfURL = nil; return }
        // A cold launch may still be restoring several playlist caches. Keep
        // the opaque request until its channel is available or import times out.
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            if let channel = library.channel(forShelfURL: url) { pendingShelfURL = nil; tune(channel); return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        pendingShelfURL = nil
        library.notice = "This channel could not be found. Refresh its playlist and try again."
    }
    private func tune(_ channel: TVChannel) {
        pendingShelfURL = nil
        player.play(channel, minutes: library.state.bufferMinutes, artwork: library.artwork, programmeTitle: { library.current(channel, at: $0)?.title }) { library.watched(channel) }
    }
    @ViewBuilder private func miniPlayer(in tab: Int) -> some View {
        // Keep the overlay inside the selected tab's focus/navigation context
        // so Back returns to the tab bar instead of leaving the app.
        if selectedTab == tab, player.isMinimized, let channel = player.channel {
            TVMiniPlayerView(player: player, channel: channel)
                .padding(.trailing, 60).padding(.bottom, 36)
        }
    }
}

enum TVBrowserMode { case all, favorites, search }

struct TVChannelBrowser: View {
    @Bindable var library: TVLibrary
    let title: String
    let mode: TVBrowserMode
    let play: (TVChannel) -> Void
    @State private var query = ""
    @State private var source: UUID?
    @State private var group = "All groups"
    @State private var matches: [TVChannel] = []
    private var groups: [String] {
        ["All groups"] + Set(library.channels.filter { source == nil || $0.sourceID == source }.map(\.group)).sorted()
    }
    private var visible: [TVChannel] {
        let base = mode == .favorites ? library.favorites : matches
        return base.filter { (source == nil || $0.sourceID == source) && (group == "All groups" || $0.group == group) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                TVHeading(title: title, subtitle: "\(library.channels.count.formatted()) channels · ChannelDeck")
                if mode == .search {
                    TextField("Channel or group", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if mode != .favorites && !library.sources.isEmpty {
                    HStack(spacing: 24) {
                        Picker("Playlist", selection: $source) {
                            Text("All playlists").tag(nil as UUID?)
                            ForEach(library.sources) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Picker("Group", selection: $group) { ForEach(groups, id: \.self) { Text($0).tag($0) } }
                        if !library.refreshing.isEmpty { ProgressView().accessibilityLabel("Refreshing playlists") }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: source) { _, _ in group = "All groups" }
                }
                if mode == .all && query.isEmpty && source == nil && group == "All groups" && !library.shelfChannels.isEmpty {
                    Text("Your top shelf").font(.title3.weight(.semibold))
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 28) { ForEach(library.shelfChannels) { card($0).frame(width: 400) } }.padding(12)
                    }.scrollClipDisabled()
                    Text("All channels").font(.title3.weight(.semibold))
                }
                if visible.isEmpty {
                    ContentUnavailableView(mode == .favorites ? "Your favorites live here" : "Ready when you are",
                                           systemImage: mode == .favorites ? "star" : "tv",
                                           description: Text(library.sources.isEmpty ? "Add your M3U playlist in Settings to get started." : mode == .favorites ? "Hold a channel to add it to Favorites." : "No channels match these filters. Try another search or refresh your playlist."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 28)], spacing: 32) {
                        ForEach(visible) { card($0) }
                    }
                }
            }.padding(.horizontal, 64).padding(.vertical, 40)
        }
        .task(id: "\(query)|\(library.revision)") {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let result = await library.search(query)
            if !Task.isCancelled { matches = result }
        }
    }
    private func card(_ channel: TVChannel) -> some View {
        Button { play(channel) } label: {
            VStack(alignment: .leading, spacing: 18) {
                TVChannelArtworkView(channel: channel, artwork: library.artwork, favorite: library.isFavorite(channel))
                    .aspectRatio(16.0 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(channel.name).font(.headline)
                    .lineLimit(2, reservesSpace: true).truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(channel.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(24).frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
                .tvCardSurface(cornerRadius: 18)
        }
        .buttonStyle(.card)
        .contextMenu {
            Button(library.isFavorite(channel) ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { library.toggleFavorite(channel) }
            Button("Watch live", systemImage: "play.fill") { play(channel) }
        }
        .accessibilityLabel("\(channel.name), \(library.current(channel)?.title ?? channel.group)")
    }
}

struct TVHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(subtitle.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(TVTheme.mint)
            Text(title).font(.largeTitle.weight(.bold))
        }.padding(.bottom, 6)
    }
}

struct TVChannelLogo: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: {
            Image(systemName: "tv").resizable().scaledToFit().padding(12).foregroundStyle(TVTheme.mint.opacity(0.7))
        }
    }
}

struct TVActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionLabel(label: configuration.label, pressed: configuration.isPressed)
    }
    private struct ActionLabel<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            label
                .foregroundStyle(focused ? TVTheme.forest : Color.white)
                .padding(.horizontal, 24).padding(.vertical, 18)
                .background(focused ? TVTheme.mint : TVTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? TVTheme.mint : .white.opacity(0.2), lineWidth: 2))
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(pressed ? 0.98 : focused ? 1.04 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

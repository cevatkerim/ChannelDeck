import SwiftUI

struct TVPlayerView: View {
    @Bindable var player: TVPlaybackController
    let channel: TVChannel
    @Bindable var library: TVLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true
    @State private var interaction = 0
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var channelListVisible = false
    @FocusState private var focusedControl: Control?
    @Namespace private var playbackFocus
    @Environment(\.resetFocus) private var resetFocus
    private enum Control: Hashable { case playPause, timeline, channels, miniPlayer }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = player.engine {
                // The native video view receives hidden-toolbar remote input.
                // A fullscreen SwiftUI Button draws a focus overlay on tvOS.
                TVVideoSurface(displayLayer: engine.displayLayer, acceptsRemote: !controlsVisible && !channelListVisible && player.failure.isEmpty) { command in
                    switch command {
                    case .showControls: showControls()
                    case .showChannels: showChannels()
                    }
                }
                .ignoresSafeArea()
            }
            if !player.isReady && player.failure.isEmpty {
                VStack(spacing: 24) { ProgressView(); Text("Connecting to \(channel.name)…").font(.title3) }
            }
            if !player.failure.isEmpty {
                VStack(spacing: 30) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(player.failure).font(.title3).multilineTextAlignment(.center)
                    HStack {
                        Button("Retry") { player.play(channel, minutes: library.state.bufferMinutes, artwork: library.artwork, programmeTitle: { library.current(channel, at: $0)?.title }) { library.watched(channel) } }
                        Button("Back to channels") { dismiss() }
                    }
                }.padding(60).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).padding(100)
            } else if controlsVisible {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(channel.name).font(.title2.bold())
                            Text(library.current(channel)?.title ?? "Live TV").foregroundStyle(.secondary)
                            Text("Swipe right to switch channels").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(player.isLive ? "LIVE" : "−\(TVPlaybackController.clock(player.liveOffset))")
                            .font(.headline.monospacedDigit()).foregroundStyle(TVTheme.mint)
                        Button("Channels", systemImage: "list.bullet") { showChannels() }
                            .focused($focusedControl, equals: .channels)
                            .accessibilityIdentifier("Show channel drawer")
                        Button("Mini player", systemImage: "pip.enter") { player.minimize() }
                            .focused($focusedControl, equals: .miniPlayer)
                    }.font(.callout).buttonStyle(TVActionButtonStyle())
                    Spacer()
                    VStack(spacing: 22) {
                        if !player.message.isEmpty { Text(player.message).font(.caption).foregroundStyle(.secondary) }
                        if scrubbing {
                            Text("Seek to −\(TVPlaybackController.clock(player.bufferedRange.upperBound - scrubPosition)) · Left / Right to adjust · Select to play")
                        }
                        GeometryReader { geometry in
                            let duration = max(1, player.bufferedRange.upperBound - player.bufferedRange.lowerBound)
                            let progress = min(1, max(0, ((scrubbing ? scrubPosition : player.position) - player.bufferedRange.lowerBound) / duration))
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(TVTheme.mint).frame(width: geometry.size.width * progress)
                            }
                        }.frame(height: 8).accessibilityLabel("\(TVPlaybackController.clock(player.bufferedRange.upperBound - player.bufferedRange.lowerBound)) of live history")
                        HStack {
                            Text("−\(TVPlaybackController.clock(player.bufferedRange.upperBound - player.bufferedRange.lowerBound)) available")
                            Spacer()
                            Text("LIVE").foregroundStyle(TVTheme.mint)
                        }.font(.caption.monospacedDigit())
                        HStack(spacing: 30) {
                            Button("10 sec", systemImage: "gobackward.10") { player.seek(player.position - 10); interacted() }.disabled(scrubbing).accessibilityLabel("Back 10 seconds")
                            Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") { player.togglePause(); interacted() }
                                .focused($focusedControl, equals: .playPause).disabled(scrubbing)
                                .prefersDefaultFocus(!scrubbing, in: playbackFocus)
                                .onMoveCommand { if $0 == .up { focusedControl = .channels } }
                            Button("10 sec", systemImage: "goforward.10") { player.seek(player.position + 10); interacted() }.disabled(scrubbing).accessibilityLabel("Forward 10 seconds")
                            Button(scrubbing ? "Play here" : "Timeline", systemImage: "slider.horizontal.3") {
                                if scrubbing { player.seek(scrubPosition); player.resume(); scrubbing = false }
                                else { scrubPosition = player.position; scrubbing = true }
                                interacted()
                            }
                            .focused($focusedControl, equals: .timeline)
                            .onMoveCommand { direction in
                                guard scrubbing else { return }
                                if direction == .left { scrubPosition = max(player.bufferedRange.lowerBound, scrubPosition - 10) }
                                if direction == .right { scrubPosition = min(player.bufferedRange.upperBound, scrubPosition + 10) }
                                interacted()
                            }
                            Button("Go Live", systemImage: "dot.radiowaves.left.and.right") { player.goLive(); scrubbing = false; interacted() }.disabled(scrubbing)
                            Button(library.isFavorite(channel) ? "Unfavorite" : "Favorite", systemImage: library.isFavorite(channel) ? "star.fill" : "star") { library.toggleFavorite(channel); interacted() }.disabled(scrubbing)
                        }.font(.callout).buttonStyle(TVActionButtonStyle())
                    }
                }.padding(64).background(LinearGradient(colors: [.black.opacity(0.7), .clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
                    .disabled(channelListVisible)
            }
            if channelListVisible {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TVChannelDrawer(channels: library.channels, groups: library.groups, current: channel, favoriteIDs: library.state.favorites, play: { selected in
                        if selected.id != channel.id {
                            player.play(selected, minutes: library.state.bufferMinutes, artwork: library.artwork, programmeTitle: { library.current(selected, at: $0)?.title }) { library.watched(selected) }
                        }
                        channelListVisible = false
                        controlsVisible = false
                    }, close: { channelListVisible = false; controlsVisible = false })
                }.background(.black.opacity(0.25)).ignoresSafeArea(edges: .trailing)
            }
        }
        .focusScope(playbackFocus)
        .task(id: controlsVisible) {
            // Wait for the new controls to join the focus hierarchy before
            // restoring focus; changing FocusState during insertion is too early.
            await Task.yield()
            if controlsVisible { resetFocus(in: playbackFocus); focusedControl = .playPause }
        }
        .onPlayPauseCommand { player.togglePause(); if !channelListVisible { showControls() } }
        .onMoveCommand { direction in
            guard !channelListVisible else { return }
            if !controlsVisible && direction == .right { showChannels() }
            else if !controlsVisible { showControls() }
            else { interacted() }
        }
        .onChange(of: focusedControl) { _, _ in if controlsVisible { interacted() } }
        .onExitCommand {
            if channelListVisible { channelListVisible = false; controlsVisible = false }
            else if scrubbing { scrubbing = false }
            else if controlsVisible { controlsVisible = false }
            else { dismiss() }
        }
        .task(id: "\(interaction)|\(player.isReady)|\(player.isPaused)") {
#if DEBUG
            // Navigation tests hide the toolbar explicitly. Accessibility
            // snapshots of large libraries can outlast the normal timer.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
#endif
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, !scrubbing, !channelListVisible, !player.isPaused, player.isReady else { return }
            controlsVisible = false
        }
    }
    private func interacted() { interaction &+= 1 }
    private func showControls() { controlsVisible = true; focusedControl = .playPause; interacted() }
    private func showChannels() { scrubbing = false; controlsVisible = false; channelListVisible = true; interacted() }
}

import SwiftUI

struct PlayerDetailView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            if let channel = appModel.selectedChannel {
                player(channel: channel)
            } else {
                ContentUnavailableView {
                    Label("Choose a Channel", systemImage: "play.rectangle")
                } description: {
                    Text("Select a channel to begin native playback.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(appModel.selectedChannel?.name ?? "Player")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AirPlayRoutePicker(player: appModel.playerController.player)
                    .frame(width: 30, height: 26)
                    .accessibilityLabel("Choose AirPlay device")
            }
        }
    }

    @ViewBuilder
    private func player(channel: ChannelRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius)
                    .fill(.black)

                PlayerViewRepresentable(player: appModel.playerController.player)
                    .clipShape(RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius))

                switch appModel.playerController.state {
                case .preparing:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Tuning in…")
                            .font(.callout.weight(.medium))
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .buffering:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Buffering…")
                            .font(.callout.weight(.medium))
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .failed(let failure):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.yellow)
                        Text("Playback Unavailable").font(.headline)
                        Text(failure.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            appModel.play(channel)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                default:
                    EmptyView()
                }
            }
            .aspectRatio(ChannelDeckStyle.playerAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .channelDeckPanel()

            if appModel.playerController.liveDVRState.isAvailable {
                LiveDVRControls(controller: appModel.playerController)
            }

            if appModel.playerController.isExternalPlaybackActive {
                Label("AirPlay Active", systemImage: "airplayvideo")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("AirPlay is active")
            }

            if let warning = appModel.playerController.airPlayWarningMessage {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("AirPlay notice: \(warning)")
            }

            if let notice = appModel.airPlayRelayController.playbackNotice {
                Label {
                    Text(notice)
                } icon: {
                    Image(systemName: appModel.airPlayRelayController.playbackIsRelayed
                        ? "lock.shield.fill"
                        : "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (appModel.airPlayRelayController.playbackIsRelayed ? Color.green : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .accessibilityLabel("AirPlay relay notice: \(notice)")
            }

            HStack(alignment: .top, spacing: 16) {
                ChannelLogoView(channel: channel, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(channel.name)
                        .font(.title2.weight(.semibold))
                    Text(channel.groupName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let current = appModel.currentProgramme(for: channel) {
                        Divider().padding(.vertical, 4)
                        Text("Now").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        Text(current.title).font(.headline)
                        if let description = current.programmeDescription, !description.isEmpty {
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }

                    if let next = appModel.nextProgramme(for: channel) {
                        Text("Next · \(next.startDate.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(next.title).font(.callout)
                    }
                }
                Spacer()
                Button(channel.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: channel.isFavorite ? "star.fill" : "star") {
                    appModel.toggleFavorite(channel)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct LiveDVRControls: View {
    let controller: PlayerController

    @State private var scrubberValue = 0.0
    @State private var isScrubbing = false

    private var timeline: LiveDVRState { controller.liveDVRState }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Label("Live Buffer", systemImage: "clock.arrow.circlepath")
                    .font(.callout.weight(.semibold))

                Spacer()

                Text(timeline.isAtLiveEdge
                    ? "At live edge"
                    : "\(formatted(timeline.secondsBehindLive)) behind")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    controller.jumpToLive()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(timeline.isAtLiveEdge ? Color.red : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(timeline.isAtLiveEdge ? "Live" : "Go Live")
                    }
                    .frame(minHeight: 28)
                }
                .buttonStyle(.bordered)
                .disabled(timeline.isAtLiveEdge)
                .accessibilityHint("Jump to the newest available point in the broadcast")
            }

            HStack(spacing: 12) {
                Text("−\(formatted(timeline.windowDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)

                Slider(
                    value: $scrubberValue,
                    in: 0 ... max(timeline.windowDuration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            controller.seek(toBufferedOffset: scrubberValue)
                        }
                    }
                )
                .accessibilityLabel("Live broadcast position")
                .accessibilityValue(timeline.isAtLiveEdge
                    ? "Live"
                    : "\(formatted(timeline.secondsBehindLive)) behind live")

                Text(timeline.isAtLiveEdge
                    ? "Live"
                    : "−\(formatted(timeline.secondsBehindLive))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(timeline.isAtLiveEdge ? Color.red : Color.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { synchronizeScrubber() }
        .onChange(of: timeline.position) { _, _ in synchronizeScrubber() }
        .onChange(of: timeline.windowDuration) { _, _ in synchronizeScrubber() }
    }

    private func synchronizeScrubber() {
        guard !isScrubbing else { return }
        scrubberValue = min(max(timeline.position, 0), timeline.windowDuration)
    }

    private func formatted(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

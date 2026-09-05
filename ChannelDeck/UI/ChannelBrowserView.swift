import SwiftUI

struct ChannelBrowserView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        let filteredChannels = appModel.filteredChannels

        Group {
            if appModel.sidebarSelection == .recordings {
                recordingsContent
            } else if appModel.sources.isEmpty {
                ContentUnavailableView {
                    Label("Add Your First Playlist", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("ChannelDeck keeps credential-bearing playlist URLs in your Mac keychain.")
                } actions: {
                    Button("Add Playlist") { appModel.beginAddingSource() }
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredChannels.isEmpty {
                ContentUnavailableView.search(text: appModel.searchText)
            } else {
                List(filteredChannels, id: \.stableID, selection: $appModel.selectedChannelID) { channel in
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
        .searchable(
            text: $appModel.searchText,
            placement: .toolbar,
            prompt: appModel.sidebarSelection == .recordings
                ? "Recordings"
                : "Channels or programmes"
        )
        .onChange(of: appModel.selectedChannelID) { _, newValue in
            guard let newValue, let channel = appModel.channel(withID: newValue) else { return }
            appModel.play(channel)
        }
        .onChange(of: appModel.selectedRecordingID) { _, newValue in
            guard appModel.sidebarSelection == .recordings,
                  let newValue,
                  let recording = appModel.recordings.first(where: { $0.id == newValue }) else {
                return
            }
            appModel.play(recording)
        }
    }

    @ViewBuilder
    private var recordingsContent: some View {
        @Bindable var appModel = appModel
        let recordings = appModel.filteredRecordings

        if recordings.isEmpty, !appModel.searchText.isEmpty {
            ContentUnavailableView.search(text: appModel.searchText)
        } else if recordings.isEmpty {
            ContentUnavailableView {
                Label("No Recordings Yet", systemImage: "record.circle")
            } description: {
                Text("While watching a channel, check Save Buffer. ChannelDeck saves it when you switch channels or turn the option off.")
            }
        } else {
            List(recordings, id: \.id, selection: $appModel.selectedRecordingID) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
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
        }
    }
}

private struct RecordingRow: View {
    @Environment(AppModel.self) private var appModel
    let recording: RecordingRecord

    var body: some View {
        HStack(spacing: 12) {
            RecordingThumbnailView(recording: recording, width: 72, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.programmeTitle ?? recording.channelName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(recording.channelName) · \(recording.endedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(recordingSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Image(systemName: "play.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
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
              let quality = BufferRecordingQuality(rawValue: rawValue) else {
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
                } else if appModel.isLoadingProgrammeGuide {
                    Text("Loading schedule…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
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

import SwiftUI

struct PlayerDetailView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("channelDeck.density") private var density: DeckDensity = .comfortable

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: appModel.selectedRecording != nil ? "play.rectangle" : "tv")
                    .foregroundStyle(ChannelDeckStyle.accent)
                Text(appModel.selectedRecording != nil ? "YOUR SCREENING ROOM" : "YOUR FRONT ROW SEAT")
                    .deckEyebrow()
                Spacer()
                if appModel.selectedChannel != nil || appModel.selectedRecording != nil {
                    AirPlayRoutePicker(player: appModel.playerController.player)
                        .frame(width: 30, height: 28)
                }
            }
            .padding(.horizontal, 28)
            .frame(height: 58)

            if let channel = appModel.selectedChannel {
                ScrollView { player(channel: channel) }
            } else if let recording = appModel.selectedRecording {
                ScrollView { player(recording: recording) }
            } else {
                PlayerWelcomeView()
            }
        }
        .background(ChannelDeckStyle.canvas)
        .navigationTitle("")
    }

    @ViewBuilder
    private func player(channel: ChannelRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                ChannelLogoView(channel: channel, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(ChannelDeckStyle.ink)
                    Text(channel.groupName)
                        .font(.system(size: 12))
                        .foregroundStyle(ChannelDeckStyle.muted)
                }
                Spacer(minLength: 8)
                Button(
                    channel.isFavorite ? "Remove Favorite" : "Add Favorite",
                    systemImage: channel.isFavorite ? "star.fill" : "star"
                ) {
                    appModel.toggleFavorite(channel)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(DeckIconButtonStyle())
                .foregroundStyle(ChannelDeckStyle.accent)
                .help(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            playbackSurface
            .aspectRatio(ChannelDeckStyle.playerAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.10), radius: 16, y: 8)

            if appModel.playerController.liveDVRState.isAvailable {
                LiveDVRControls(appModel: appModel)
            } else if appModel.playerController.state == .playing || appModel.bufferRecordingPhase.isEnabled {
                RecordingControls(appModel: appModel)
                    .padding(18).channelDeckPanel()
            }

            if appModel.playerController.isExternalPlaybackActive {
                Label("AirPlay Active", systemImage: "airplayvideo")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChannelDeckStyle.accentSoft, in: RoundedRectangle(cornerRadius: 10))
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

            if let notice = appModel.airPlayRelayController.playbackNotice,
               appModel.playbackPreparation != nil || appModel.playerController.state != .idle {
                Label {
                    Text(notice)
                } icon: {
                    Image(
                        systemName: appModel.airPlayRelayController.playbackIsRelayed
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

            if let current = appModel.currentProgramme(for: channel) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("ON NOW", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(ChannelDeckStyle.accent)
                        Spacer()
                        Text(
                            "\(current.startDate.formatted(date: .omitted, time: .shortened)) – \(current.endDate.formatted(date: .omitted, time: .shortened))"
                        )
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(ChannelDeckStyle.muted)
                    }
                    Text(current.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(ChannelDeckStyle.ink)
                    if let description = current.programmeDescription, !description.isEmpty {
                        Text(description)
                            .font(.system(size: density.readingSize))
                            .foregroundStyle(ChannelDeckStyle.muted)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ProgressView(value: programmeProgress(current, at: context.date))
                            .tint(ChannelDeckStyle.accent)
                            .accessibilityLabel("Programme progress")
                    }
                    if let next = appModel.nextProgramme(for: channel) {
                        Rectangle().fill(ChannelDeckStyle.line).frame(height: 1)
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text("UP NEXT").deckEyebrow()
                            Text(next.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ChannelDeckStyle.ink)
                            Spacer(minLength: 0)
                            Text(next.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(ChannelDeckStyle.muted)
                        }
                    }
                }
                .padding(22)
                .channelDeckPanel()
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "tv").foregroundStyle(ChannelDeckStyle.accent)
                    Text(
                        appModel.isLoadingProgrammeGuide
                            ? "Getting the programme guide…" : "You're tuned in. Enjoy the moment."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(ChannelDeckStyle.muted)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func player(recording: RecordingRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            playbackSurface
            .aspectRatio(ChannelDeckStyle.playerAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.10), radius: 16, y: 8)

            HStack(alignment: .top, spacing: 16) {
                RecordingThumbnailView(recording: recording, width: 128, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text(recording.programmeTitle ?? recording.channelName)
                        .font(.title2.weight(.semibold))
                    Text(recording.channelName)
                        .font(.headline)
                    Text(
                        "\(recording.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formattedDuration(recording.duration))"
                    )
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let rawValue = recording.qualityRawValue,
                        let quality = BufferRecordingQuality(rawValue: rawValue)
                    {
                        Label(quality.title, systemImage: quality.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let description = recording.programmeDescription,
                        !description.isEmpty
                    {
                        Divider().padding(.vertical, 4)
                        Text(description)
                            .font(.system(size: density.readingSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Show in Finder", systemImage: "folder") {
                        appModel.revealRecording(recording)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Show recording in Finder")

                    Button("Delete Recording…", systemImage: "trash", role: .destructive) {
                        appModel.requestRemoval(of: recording)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Delete recording")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var playbackOverlayIsVisible: Bool {
        if appModel.playbackPreparation != nil || appModel.playbackIssue != nil { return true }
        switch appModel.playerController.state {
        case .idle, .preparing, .buffering, .failed: return true
        default: return false
        }
    }

    private var playbackSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius).fill(Color.black)
            PlayerViewRepresentable(player: appModel.playerController.player)
                .accessibilityHidden(playbackOverlayIsVisible)
                .clipShape(RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius))

            if let issue = appModel.playbackIssue {
                playbackMessage(title: issue.title, message: issue.message,
                                action: issue.sourceToRefresh == nil ? "Try again" : "Refresh & play")
            } else if let preparation = appModel.playbackPreparation {
                loadingMessage(
                    preparation.kind == .recording ? "Opening your recording…"
                        : appModel.airPlayRelayController.playbackIsRelayed ? "Preparing your stream…" : "Connecting to your channel…",
                    detail: preparation.kind == .recording ? "Getting your saved moment ready to play."
                        : appModel.airPlayRelayController.playbackIsRelayed || appModel.airPlayRelayController.phase.isBusy
                        ? "Making this channel ready for playback and AirPlay."
                        : "Getting everything ready for your front row seat."
                )
            } else {
                switch appModel.playerController.state {
                case .preparing:
                    loadingMessage("Preparing the picture…", detail: "The channel is connected. Video will begin shortly.")
                case .buffering:
                    loadingMessage("Catching up…", detail: "Waiting for a little more video from the channel.")
                case .failed(let failure):
                    playbackMessage(title: "Let's try that again.", message: failure.message, action: "Try again")
                case .idle:
                    playbackMessage(title: "Ready when you are.", message: appModel.selectedRecording != nil ? "Your recording is waiting for you." : "Your channel is waiting for you.", action: "Play")
                default:
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius))
    }

    private func loadingMessage(_ title: String, detail: String) -> some View {
        VStack(spacing: 13) {
            ProgressView().controlSize(.large).environment(\.colorScheme, .dark)
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center).frame(maxWidth: 330)
            Button("Cancel") { appModel.stopPlayback() }
                .buttonStyle(DeckButtonStyle()).padding(.top, 3)
        }
        .foregroundStyle(.white)
        .padding(25)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.105, blue: 0.085).opacity(0.96))
        .accessibilityElement(children: .contain)
    }

    private func playbackMessage(title: String, message: String, action: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: action == "Play" ? "play.circle" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Color(red: 0.55, green: 0.86, blue: 0.72))
            Text(title).font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button(action, systemImage: action == "Play" ? "play.fill" : "arrow.clockwise") { appModel.retryPlayback() }
                .buttonStyle(DeckButtonStyle(prominent: true)).padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(25)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.105, blue: 0.085))
    }

    private func programmeProgress(_ programme: ProgrammeRecord, at date: Date) -> Double {
        let duration = programme.endDate.timeIntervalSince(programme.startDate)
        guard duration > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(programme.startDate) / duration))
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct LiveDVRControls: View {
    let appModel: AppModel

    @State private var scrubberValue = 0.0
    @State private var isScrubbing = false

    private var controller: PlayerController { appModel.playerController }
    private var timeline: LiveDVRState { controller.liveDVRState }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Label("Live buffer", systemImage: "clock.arrow.circlepath")
                    .font(.callout.weight(.semibold))

                Spacer()

                Text(
                    timeline.isAtLiveEdge
                        ? "At live edge"
                        : "\(formatted(timeline.secondsBehindLive)) behind"
                )
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
                    in: 0...max(timeline.windowDuration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            controller.seek(toBufferedOffset: scrubberValue)
                        }
                    }
                )
                .accessibilityLabel("Live broadcast position")
                .accessibilityValue(
                    timeline.isAtLiveEdge
                        ? "Live"
                        : "\(formatted(timeline.secondsBehindLive)) behind live")

                Text(
                    timeline.isAtLiveEdge
                        ? "Live"
                        : "−\(formatted(timeline.secondsBehindLive))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(timeline.isAtLiveEdge ? Color.red : Color.secondary)
                .frame(minWidth: 44, alignment: .leading)
            }

            Divider()

            RecordingControls(appModel: appModel)
        }
        .font(.system(size: 11))
        .padding(18)
        .channelDeckPanel()
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

private struct RecordingControls: View {
    let appModel: AppModel
    private var isRecording: Bool { appModel.bufferRecordingPhase.isEnabled }
    private var canRecord: Bool { appModel.playerController.liveDVRState.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Button {
                    appModel.setSaveBufferEnabled(!isRecording)
                } label: {
                    Label(isRecording ? "Stop recording" : "Record",
                          systemImage: isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(isRecording ? Color.red : ChannelDeckStyle.ink)
                }
                .buttonStyle(DeckButtonStyle())
                .disabled(appModel.bufferRecordingPhase.isBusy || (!canRecord && !isRecording))
                .help("Includes the available live buffer. Saves when you stop recording or change channels.")
                Menu {
                    Picker("Recording quality", selection: Binding(
                        get: { appModel.bufferRecordingQuality },
                        set: { appModel.bufferRecordingQuality = $0 }
                    )) {
                        ForEach(BufferRecordingQuality.allCases) { quality in
                            Label(quality.title, systemImage: quality.systemImage).tag(quality)
                        }
                    }
                } label: {
                    Label(appModel.bufferRecordingQuality.compactTitle,
                          systemImage: appModel.bufferRecordingQuality.systemImage)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(isRecording).help(appModel.bufferRecordingQuality.guidance)
                .accessibilityLabel("Recording quality")
                Spacer(minLength: 0)
                recordingStatus
            }
            HStack(alignment: .top) {
                Text(canRecord ? "Includes the live buffer · Saved on this Mac" : "Recording is available on channels with a live buffer.")
                Spacer(minLength: 10)
                if let bytes = appModel.availableRecordingBytes {
                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free")
                        .fixedSize().monospacedDigit()
                }
            }
            .font(.system(size: 11)).foregroundStyle(ChannelDeckStyle.muted)
        }
        .task {
            while !Task.isCancelled {
                await appModel.refreshRecordingDiskSpace()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    @ViewBuilder
    private var recordingStatus: some View {
        switch appModel.bufferRecordingPhase {
        case .idle: EmptyView()
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…") }.font(.caption)
        case .recording(let startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(duration(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.red)
                .accessibilityLabel("Recording, \(duration(context.date.timeIntervalSince(startedAt))) including live buffer")
            }
        case .finalizing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }.font(.caption)
        case .failed(let message):
            Label("Couldn't record", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).help(message)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}

private struct PlayerWelcomeView: View {
    @Environment(AppModel.self) private var appModel

    private var isRecordings: Bool { appModel.sidebarSelection == .recordings }
    private var quickChannels: [ChannelRecord] {
        let recent = appModel.recents.prefix(3).compactMap { appModel.channel(withID: $0.channelStableID) }
        return recent.isEmpty ? Array(appModel.channels.lazy.filter(\.isFavorite).prefix(3)) : recent
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    illustration
                        .padding(.bottom, 27)
                    Text(isRecordings ? "Worth watching again." : "Something good is on.")
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(ChannelDeckStyle.ink)
                        .multilineTextAlignment(.center)
                    Text(
                        isRecordings
                            ? "Your saved moments, on your schedule.\nChoose a recording and settle in."
                            : "Your channels. Your favorites. Your front row seat.\nPick something to watch and make yourself at home."
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(ChannelDeckStyle.muted)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .padding(.top, 13)

                    if appModel.sources.isEmpty {
                        Button {
                            appModel.beginAddingSource()
                        } label: {
                            Label("Add your first playlist", systemImage: "plus")
                        }
                        .buttonStyle(DeckButtonStyle(prominent: true))
                        .padding(.top, 25)
                    } else if !isRecordings, let channel = quickChannels.first {
                        Button {
                            appModel.play(channel)
                        } label: {
                            Label("Watch \(channel.name)", systemImage: "play.fill").lineLimit(1)
                        }
                        .buttonStyle(DeckButtonStyle(prominent: true))
                        .padding(.top, 25)
                        .padding(.horizontal, 30)
                    } else if !isRecordings || appModel.recordings.isEmpty {
                        Button {
                            appModel.searchText = ""
                            if let source = appModel.sources.first { appModel.sidebarSelection = .source(source.id) }
                        } label: {
                            Label("Explore your channels", systemImage: "arrow.left")
                        }
                        .buttonStyle(DeckButtonStyle(prominent: true))
                        .padding(.top, 25)
                    }
                    Spacer(minLength: 40)

                    if !isRecordings, !quickChannels.isEmpty {
                        VStack(alignment: .leading, spacing: 13) {
                            Text(appModel.recents.isEmpty ? "FROM YOUR FAVORITES" : "RECENTLY WATCHED").deckEyebrow()
                            ForEach(quickChannels, id: \.stableID) { channel in
                                Button {
                                    appModel.play(channel)
                                } label: {
                                    HStack(spacing: 12) {
                                        ChannelLogoView(channel: channel, size: 34)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(channel.name).font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(ChannelDeckStyle.ink)
                                            Text(appModel.currentProgramme(for: channel)?.title ?? channel.groupName)
                                                .font(.system(size: 11))
                                                .foregroundStyle(ChannelDeckStyle.muted)
                                        }
                                        .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "play.circle")
                                            .font(.system(size: 20, weight: .light))
                                            .foregroundStyle(ChannelDeckStyle.accent)
                                    }
                                    .padding(12)
                                    .background(ChannelDeckStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: 400)
                        .padding(.horizontal, 34)
                        .padding(.bottom, 32)
                    } else {
                        HStack(spacing: 23) {
                            feature("All together", symbol: "rectangle.stack")
                            feature("At your pace", symbol: "clock.arrow.circlepath")
                            feature("On the big screen", symbol: "airplayvideo")
                        }
                        .padding(.bottom, 40)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
    }

    private func feature(_ title: String, symbol: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 17, weight: .light))
            Text(title).font(.system(size: 10))
        }
        .foregroundStyle(ChannelDeckStyle.muted)
    }

    private var illustration: some View {
        ZStack {
            Circle().fill(ChannelDeckStyle.accentSoft.opacity(0.7)).frame(width: 210, height: 210)
            Circle().strokeBorder(ChannelDeckStyle.accent.opacity(0.09), lineWidth: 1).frame(width: 250, height: 250)
            RoundedRectangle(cornerRadius: 22)
                .fill(ChannelDeckStyle.accent.opacity(0.13))
                .frame(width: 143, height: 105)
                .rotationEffect(.degrees(13))
                .offset(x: 22, y: -14)
            RoundedRectangle(cornerRadius: 22)
                .fill(ChannelDeckStyle.accent.opacity(0.23))
                .frame(width: 143, height: 105)
                .rotationEffect(.degrees(-10))
                .offset(x: -18, y: -2)
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(ChannelDeckStyle.surface)
                    .shadow(color: ChannelDeckStyle.accent.opacity(0.12), radius: 18, y: 12)
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(ChannelDeckStyle.accent.opacity(0.18), lineWidth: 1)
                Image(systemName: isRecordings ? "play.rectangle.on.rectangle" : "play.fill")
                    .font(.system(size: 31, weight: .light))
                    .foregroundStyle(ChannelDeckStyle.accent)
            }
            .frame(width: 143, height: 105)
            .rotationEffect(.degrees(-3))
            .offset(y: 9)
            HStack(spacing: 5) {
                Circle().fill(ChannelDeckStyle.accent).frame(width: 5, height: 5)
                Text(isRecordings ? "ON YOUR TIME" : "READY WHEN YOU ARE")
                    .font(.system(size: 8, weight: .semibold)).tracking(0.7)
            }
            .foregroundStyle(ChannelDeckStyle.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ChannelDeckStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(ChannelDeckStyle.line, lineWidth: 1))
            .offset(x: 20, y: 75)
        }
        .frame(height: 250)
        .accessibilityHidden(true)
    }
}

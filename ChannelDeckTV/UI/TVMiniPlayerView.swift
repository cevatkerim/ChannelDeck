import SwiftUI

struct TVMiniPlayerView: View {
    @Bindable var player: TVPlaybackController
    let channel: TVChannel
    @FocusState private var previewFocused: Bool
    @Namespace private var miniFocus
    @Environment(\.resetFocus) private var resetFocus

    var body: some View {
        VStack(spacing: 14) {
            Button { player.expand() } label: {
                VStack(alignment: .leading, spacing: 12) {
                    if let engine = player.engine {
                        TVVideoSurface(displayLayer: engine.displayLayer)
                            .frame(width: 384, height: 216).clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name).font(.headline).lineLimit(1)
                            Text(player.failure.isEmpty ? (player.isPaused ? "Paused" : player.isLive ? "Live" : "−\(TVPlaybackController.clock(player.liveOffset))") : "Playback interrupted")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            .buttonStyle(TVMiniPlayerButtonStyle())
            .accessibilityLabel("Return to fullscreen")
            .accessibilityValue(channel.name)
            .focused($previewFocused)
            .prefersDefaultFocus(true, in: miniFocus)
            HStack(spacing: 18) {
                Button(player.isPaused ? "Play" : "Pause", systemImage: player.isPaused ? "play.fill" : "pause.fill") { player.togglePause() }
                    .accessibilityLabel(player.isPaused ? "Play mini player" : "Pause mini player")
                Button("Close", systemImage: "xmark") { player.stop() }
                    .accessibilityLabel("Close mini player")
            }.font(.caption).buttonStyle(TVActionButtonStyle())
        }
        .frame(width: 400)
        .padding(20).background(TVTheme.forest, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 8)
        .accessibilityIdentifier("Mini player")
        .focusScope(miniFocus)
        .task(id: player.miniPlayerFocusRevision) {
            await Task.yield()
            if player.takeMiniPlayerFocusRequest() { resetFocus(in: miniFocus); previewFocused = true }
        }
    }
}

private struct TVMiniPlayerButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white).padding(8)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(focused ? TVTheme.mint : .clear, lineWidth: 4))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

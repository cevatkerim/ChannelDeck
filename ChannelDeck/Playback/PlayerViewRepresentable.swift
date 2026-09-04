import AVFoundation
import AVKit
import SwiftUI

/// SwiftUI bridge for the native macOS player UI, including its standard
/// controls, full-screen button, and Picture in Picture support.
@MainActor
public struct PlayerViewRepresentable: NSViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.updatesNowPlayingInfoCenter = true
        playerView.allowsVideoFrameAnalysis = false
        return playerView
    }

    public func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = player
        }
    }

    public static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Void) {
        // The controller, rather than view lifetime, owns playback. Only sever
        // the rendering connection when SwiftUI dismantles this view.
        playerView.player = nil
    }
}

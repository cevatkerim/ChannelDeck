import AVFoundation
import AVKit
import SwiftUI

/// SwiftUI bridge for the native macOS player UI, including its standard
/// controls, full-screen button, and Picture in Picture support.
@MainActor
public struct PlayerViewRepresentable: NSViewRepresentable {
    public let player: AVPlayer
    private let controller: PlayerController?
    private let isVideoSurfaceVisible: Bool

    public init(player: AVPlayer) {
        self.player = player
        controller = nil
        isVideoSurfaceVisible = true
    }

    init(controller: PlayerController, isVideoSurfaceVisible: Bool = true) {
        player = controller.player
        self.controller = controller
        self.isVideoSurfaceVisible = isVideoSurfaceVisible
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
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
        context.coordinator.attach(to: playerView, controller: controller)
        controller?.setVideoSurfaceVisible(isVideoSurfaceVisible)
        return playerView
    }

    public func updateNSView(_ playerView: AVPlayerView, context: Context) {
        controller?.setVideoSurfaceVisible(isVideoSurfaceVisible)
        if playerView.player !== player {
            playerView.player = player
            context.coordinator.attach(to: playerView, controller: controller)
        }
    }

    public static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        // The controller, rather than view lifetime, owns playback. Only sever
        // the rendering connection when SwiftUI dismantles this view.
        coordinator.detach()
        playerView.player = nil
    }

    @MainActor
    public final class Coordinator {
        private weak var playerView: AVPlayerView?
        private weak var controller: PlayerController?
        private var observations: [NSKeyValueObservation] = []
        private var itemStatusObservation: NSKeyValueObservation?
        private weak var observedItem: AVPlayerItem?
        private var attachmentID = UUID()

        func attach(to playerView: AVPlayerView, controller: PlayerController?) {
            detach()
            self.playerView = playerView
            self.controller = controller
            guard let player = playerView.player, controller != nil else { return }
            let attachmentID = attachmentID
            let notifyChange: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.refreshReadiness(attachmentID: attachmentID)
                }
            }
            observations = [
                playerView.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, _ in
                    notifyChange()
                },
                player.observe(\.currentItem, options: [.new]) { _, _ in
                    notifyChange()
                }
            ]
            refreshReadiness(attachmentID: attachmentID)
        }

        private func refreshReadiness(attachmentID: UUID) {
            guard self.attachmentID == attachmentID,
                  let view = playerView, view.player === controller?.player else { return }
            let item = view.player?.currentItem
            if observedItem !== item {
                itemStatusObservation?.invalidate()
                observedItem = item
                // AVKit readiness and item readiness may arrive in either
                // order. Observe both so an early display-ready event is not
                // lost while the item's status is still unknown.
                itemStatusObservation = item?.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item,
                              self.attachmentID == attachmentID,
                              self.observedItem === item,
                              self.playerView?.player?.currentItem === item else { return }
                        self.refreshReadiness(attachmentID: attachmentID)
                    }
                }
            }
            guard let item, item.status == .readyToPlay else { return }
            // Read the live value after dispatching to the main actor; an old
            // queued KVO event must not report a stale `true` for a new item.
            controller?.reportVideoDisplayReady(view.isReadyForDisplay, for: item)
        }

        func detach() {
            attachmentID = UUID()
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
            observedItem = nil
            playerView = nil
            controller = nil
        }
    }
}

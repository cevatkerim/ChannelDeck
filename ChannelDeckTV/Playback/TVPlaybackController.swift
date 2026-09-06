import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class TVPlaybackController {
    private(set) var engine: CDTVMediaEngine?
    private(set) var channel: TVChannel?
    private(set) var position = 0.0
    private(set) var bufferedRange = 0.0...0.0
    private(set) var bufferBytes: UInt64 = 0
    private(set) var isPaused = false
    private(set) var isReady = false
    private(set) var failure = ""
    private(set) var message = ""
    private(set) var isMinimized = false
    private(set) var miniPlayerFocusRevision = 0
    @ObservationIgnored private var miniPlayerNeedsFocus = false
    var isFullscreenPresented: Bool { channel != nil && !isMinimized }
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var previewIsLive = true
    var liveOffset: Double { max(0, bufferedRange.upperBound - position) }
    var isLive: Bool { liveOffset < 3 }

    func play(_ channel: TVChannel, minutes: Int, artwork: TVArtworkLibrary? = nil, programmeTitle: @escaping @MainActor (Date) -> String? = { _ in nil }, didStart: @escaping @MainActor () -> Void = {}) {
        stop()
        self.channel = channel
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { failure = "The audio output could not be activated."; return }
        let directory = URL.cachesDirectory.appending(path: "ChannelDeckTV/Live", directoryHint: .isDirectory)
        let engine = CDTVMediaEngine(cacheDirectory: directory)
        self.engine = engine
        engine.play(channel.streamURL, bufferSeconds: Double(minutes * 60))
        poll = Task { [weak self, weak engine] in
            var reportedStart = false
            var lastThumbnail = Date.distantPast
            while !Task.isCancelled {
                guard let self, let engine else { return }
                let snapshot = engine.snapshot()
                self.position = min(snapshot.end, max(snapshot.start, snapshot.position))
                self.bufferedRange = min(snapshot.start, snapshot.end)...snapshot.end
                self.bufferBytes = snapshot.bytes
                self.isPaused = snapshot.paused
                self.isReady = snapshot.ready
                self.failure = snapshot.failure
                self.message = snapshot.message
                if snapshot.ready && !reportedStart { reportedStart = true; didStart() }
                // Providers may deliver TS packets well ahead of their render
                // time. Track user time-shifting instead of treating that
                // ingestion lead as evidence that the viewer rewound.
                if let artwork, self.previewIsLive, snapshot.videoFrames > 12, !snapshot.paused,
                   Date.now.timeIntervalSince(lastThumbnail) >= 30 {
                    lastThumbnail = .now
                    let capturedAt = Date.now
                    let title = programmeTitle(capturedAt)
                    let data = await engine.captureThumbnail()
                    if !Task.isCancelled, self.engine === engine, self.previewIsLive, !self.isPaused, let data {
                        await artwork.capture(data, channel: channel, capturedAt: capturedAt, programmeTitle: title)
                    }
                    if data == nil { lastThumbnail = Date.now.addingTimeInterval(-27) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    func pause() { previewIsLive = false; engine?.setPaused(true) }
    func resume() { if liveOffset < 3 { previewIsLive = true }; engine?.setPaused(false) }
    func togglePause() { if isPaused { resume() } else { pause() } }
    func seek(_ time: Double) {
        let target = min(bufferedRange.upperBound, max(bufferedRange.lowerBound, time))
        previewIsLive = bufferedRange.upperBound - target < 3
        engine?.seek(to: target)
    }
    func goLive() { previewIsLive = true; engine?.goLive() }
    func minimize() { if engine != nil { isMinimized = true } }
    func fullscreenDidDismiss() {
        if isMinimized { miniPlayerNeedsFocus = true; miniPlayerFocusRevision &+= 1 }
    }
    func takeMiniPlayerFocusRequest() -> Bool {
        guard isMinimized, miniPlayerNeedsFocus else { return false }
        miniPlayerNeedsFocus = false
        return true
    }
    func expand() { if channel != nil { isMinimized = false } }
    func dismissFullscreen() {
        // SwiftUI can write the presentation binding again after minimization.
        // That dismissal must not terminate the continuing mini-player session.
        if isFullscreenPresented { stop() }
    }
    func stop() {
        poll?.cancel(); poll = nil
        UIApplication.shared.isIdleTimerDisabled = false
        engine?.stop(); engine = nil; channel = nil
        position = 0; bufferedRange = 0...0; bufferBytes = 0
        isReady = false; isPaused = false; failure = ""; message = ""
        isMinimized = false
        previewIsLive = true
        miniPlayerNeedsFocus = false
    }
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

enum TVRemoteCommand { case showControls, showChannels }

struct TVVideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    var acceptsRemote = false
    var command: (TVRemoteCommand) -> Void = { _ in }
    func makeUIView(context: Context) -> VideoView { VideoView(displayLayer) }
    func updateUIView(_ view: VideoView, context: Context) {
        view.setDisplayLayer(displayLayer)
        view.command = command
        view.setAcceptsRemote(acceptsRemote)
    }
    final class VideoView: UIView {
        private var display: AVSampleBufferDisplayLayer
        private var acceptsRemote = false
        var command: (TVRemoteCommand) -> Void = { _ in }
        override var canBecomeFocused: Bool { acceptsRemote }
        override var canBecomeFirstResponder: Bool { acceptsRemote }
        init(_ display: AVSampleBufferDisplayLayer) {
            self.display = display
            super.init(frame: .zero)
            backgroundColor = .black
            layer.addSublayer(display)
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
            swipe.direction = .right
            addGestureRecognizer(swipe)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        @objc private func swipedRight() {
            if acceptsRemote { command(.showChannels) }
        }
        func setAcceptsRemote(_ value: Bool) {
            guard acceptsRemote != value else { return }
            acceptsRemote = value
            isAccessibilityElement = value
            accessibilityLabel = "Show playback controls"
            accessibilityTraits = .button
            if value { requestVideoFocus() } else { resignFirstResponder() }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if acceptsRemote { requestVideoFocus() }
        }
        private func requestVideoFocus() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.acceptsRemote, self.window != nil else { return }
                self.becomeFirstResponder()
                let system = UIFocusSystem.focusSystem(for: self)
                system?.requestFocusUpdate(to: self)
                system?.updateFocusIfNeeded()
            }
        }
        private func handles(_ presses: Set<UIPress>) -> Bool {
            // Back and Play/Pause belong to SwiftUI's command handlers. A
            // toolbar can disappear between press-began and press-ended; the
            // newly focused native view must not process that press again.
            acceptsRemote && presses.contains { [.select, .upArrow, .downArrow, .leftArrow, .rightArrow].contains($0.type) }
        }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if !handles(presses) { super.pressesBegan(presses, with: event) }
        }
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard handles(presses) else { super.pressesEnded(presses, with: event); return }
            if presses.contains(where: { $0.type == .rightArrow }) { command(.showChannels) }
            else { command(.showControls) }
        }
        func setDisplayLayer(_ value: AVSampleBufferDisplayLayer) {
            guard display !== value else { return }
            display.removeFromSuperlayer(); display = value; layer.addSublayer(display); setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Fullscreen and mini views briefly coexist during presentation
            // transitions. Only the current host may resize the shared layer.
            guard display.superlayer === layer else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            display.frame = bounds; CATransaction.commit()
        }
    }
}

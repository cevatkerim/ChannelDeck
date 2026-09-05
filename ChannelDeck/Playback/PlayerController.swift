import AVFoundation
import Foundation
import Observation

/// A URL-free description of a playback failure that is safe to show in the UI
/// and diagnostics.
public struct PlaybackFailure: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unavailable
        case network
        case insecureTransport
        case unsupportedFormat
        case protectedContent
        case airPlayUnavailable
        case unknown
    }

    public let kind: Kind

    public var message: String {
        switch kind {
        case .unavailable:
            "This channel is currently unavailable."
        case .network:
            "The stream could not be reached. Check your connection and try again."
        case .insecureTransport:
            "macOS blocked an insecure media connection used by this stream."
        case .unsupportedFormat:
            "This stream uses a format that is not supported by the system player."
        case .protectedContent:
            "This stream cannot be played because its content is protected."
        case .airPlayUnavailable:
            "AirPlay cannot play this stream directly. Try macOS Screen Mirroring or an end-to-end HTTPS stream."
        case .unknown:
            "The channel could not be played."
        }
    }

    init(error: (any Error)?) {
        guard let error else {
            kind = .unknown
            return
        }

        var visitedErrors = Set<ObjectIdentifier>()
        kind = Self.classify(error as NSError, visitedErrors: &visitedErrors) ?? .unknown
    }

    public init(kind: Kind) {
        self.kind = kind
    }

    /// AVFoundation frequently wraps the actionable URL loading error inside a
    /// generic AVError. Walk that chain so the UI reports the useful category
    /// without ever displaying a credential-bearing stream URL.
    private static func classify(
        _ error: NSError,
        visitedErrors: inout Set<ObjectIdentifier>
    ) -> Kind? {
        guard visitedErrors.insert(ObjectIdentifier(error)).inserted else { return nil }

        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                return .insecureTransport
            }
            return .network
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           let underlyingKind = classify(underlyingError, visitedErrors: &visitedErrors) {
            return underlyingKind
        }

        guard error.domain == AVFoundationErrorDomain,
              let code = AVError.Code(rawValue: error.code) else {
            return nil
        }

        switch code {
        case .fileFormatNotRecognized,
             .fileFailedToParse,
             .decoderNotFound,
             .decoderTemporarilyUnavailable,
             .decodeFailed,
             .invalidSourceMedia,
             .undecodableMediaData,
             .formatUnsupported:
            return .unsupportedFormat
        case .contentIsProtected,
             .contentIsNotAuthorized:
            return .protectedContent
        case .deviceWasDisconnected,
             .serverIncorrectlyConfigured,
             .contentIsUnavailable,
             .noLongerPlayable:
            return .unavailable
        case .noCompatibleAlternatesForExternalDisplay,
             .externalPlaybackNotSupportedForAsset,
             .airPlayControllerRequiresInternet,
             .airPlayReceiverRequiresInternet,
             .airPlayReceiverTemporarilyUnavailable:
            return .airPlayUnavailable
        default:
            return .unknown
        }
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case buffering
    case failed(PlaybackFailure)
}

/// AVFoundation's assessment of whether the current asset can use AirPlay
/// Video's direct URL handoff. This does not guarantee that the receiver can
/// reach the provider, but an incompatible result is definitive.
public enum AirPlayVideoCompatibility: Equatable, Sendable {
    case unavailable
    case checking
    case compatible
    case incompatible
    case indeterminate
}

/// A URL-free snapshot of the current live HLS seekable window. Position zero
/// is the oldest retained point and `windowDuration` is the live edge.
struct LiveDVRState: Equatable, Sendable {
    static let unavailable = LiveDVRState(
        windowDuration: 0,
        position: 0,
        secondsBehindLive: 0
    )

    let windowDuration: TimeInterval
    let position: TimeInterval
    let secondsBehindLive: TimeInterval

    var isAvailable: Bool { windowDuration >= 8 }
    var isAtLiveEdge: Bool { isAvailable && secondsBehindLive <= 3 }

    static func make(
        rangeStart: TimeInterval,
        rangeDuration: TimeInterval,
        currentTime: TimeInterval
    ) -> LiveDVRState {
        guard rangeStart.isFinite,
              rangeDuration.isFinite,
              currentTime.isFinite,
              rangeDuration > 0 else {
            return .unavailable
        }
        let position = min(max(currentTime - rangeStart, 0), rangeDuration)
        return LiveDVRState(
            windowDuration: rangeDuration,
            position: position,
            secondsBehindLive: max(0, rangeDuration - position)
        )
    }
}

/// Owns the application's single native player and translates AVFoundation's
/// KVO state into a small, URL-free state model suitable for SwiftUI.
@MainActor
@Observable
public final class PlayerController {
    @ObservationIgnored public let player: AVPlayer

    public private(set) var state: PlaybackState = .idle
    public private(set) var currentChannelName: String?
    public private(set) var isExternalPlaybackActive = false
    public private(set) var airPlayVideoCompatibility: AirPlayVideoCompatibility = .unavailable
    public private(set) var currentStreamUsesInsecureTransport = false
    private(set) var liveDVRState: LiveDVRState = .unavailable

    /// A privacy-safe explanation for the common cases where local playback
    /// works but direct AirPlay Video cannot complete its receiver handoff.
    public var airPlayWarningMessage: String? {
        guard !isExternalPlaybackActive else { return nil }
        if currentStreamUsesInsecureTransport {
            return "This channel is delivered over HTTP. It can play on this Mac, but an AirPlay receiver may reject the handoff. Try Screen Mirroring or an HTTPS stream."
        }
        if airPlayVideoCompatibility == .incompatible {
            return "This channel is not compatible with direct AirPlay Video. Try macOS Screen Mirroring instead."
        }
        return nil
    }

    @ObservationIgnored private var currentRequest: PlaybackRequest?
    @ObservationIgnored private var observationGeneration = UUID()
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemFailureObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var airPlayCompatibilityTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var userPaused = false

    public init(player: AVPlayer = AVPlayer()) {
        self.player = player
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer()
        observePlaybackTime()
    }

    /// Replaces the current channel immediately. The URL is retained privately
    /// only so `retry()` can recreate a failed item.
    public func play(
        url: URL,
        channelName: String,
        allowsExternalPlayback: Bool = true
    ) {
        beginPlayback(
            PlaybackRequest(
                url: url,
                channelName: channelName,
                allowsExternalPlayback: allowsExternalPlayback
            )
        )
    }

    public func pause() {
        guard player.currentItem != nil else { return }
        userPaused = true
        player.pause()
        refreshState()
    }

    public func resume() {
        guard player.currentItem != nil else { return }
        userPaused = false
        player.play()
        refreshState()
    }

    public func togglePlayback() {
        if userPaused || player.timeControlStatus == .paused {
            resume()
        } else {
            pause()
        }
    }

    /// Seeks to an offset within the current rolling live window. The window
    /// is resolved again at the moment of the seek because its start advances
    /// continuously while the user is dragging the scrubber.
    func seek(toBufferedOffset requestedOffset: TimeInterval) {
        guard let range = currentSeekableRange() else { return }
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let offset = min(max(requestedOffset, 0), duration)
        let target = CMTimeAdd(
            range.start,
            CMTime(seconds: offset, preferredTimescale: 600)
        )
        player.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLiveDVRState()
            }
        }
    }

    /// Moves close to (rather than beyond) the current live edge and resumes.
    func jumpToLive() {
        guard let range = currentSeekableRange() else { return }
        userPaused = false
        seek(toBufferedOffset: max(0, range.duration.seconds - 0.5))
        player.play()
    }

    /// Recreates the current player item without exposing its URL to callers or
    /// incorporating it into an error message.
    public func retry() {
        guard let currentRequest else { return }
        beginPlayback(currentRequest)
    }

    /// Stops network/media activity and invalidates all item-specific observers.
    public func stop() {
        observationGeneration = UUID()
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.allowsExternalPlayback = true
        currentRequest = nil
        currentChannelName = nil
        isExternalPlaybackActive = false
        airPlayVideoCompatibility = .unavailable
        currentStreamUsesInsecureTransport = false
        liveDVRState = .unavailable
        userPaused = false
        state = .idle
    }

    private func beginPlayback(_ request: PlaybackRequest) {
        observationGeneration = UUID()
        let generation = observationGeneration

        removeItemObservers()
        player.pause()

        currentRequest = request
        currentChannelName = request.channelName
        player.allowsExternalPlayback = request.allowsExternalPlayback
        currentStreamUsesInsecureTransport = request.url.scheme?.lowercased() == "http"
        liveDVRState = .unavailable
        userPaused = false
        state = .preparing

        let item = AVPlayerItem(url: request.url)
        observe(item: item, generation: generation)
        player.replaceCurrentItem(with: item)
        player.play()
        evaluateAirPlayCompatibility(of: item.asset, generation: generation)
    }

    private func observePlayer() {
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshState()
                }
            },
            player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshExternalPlaybackState()
                }
            }
        ]
    }

    private func observe(item: AVPlayerItem, generation: UUID) {
        let notifyChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.observationGeneration == generation else { return }
                self?.refreshState()
            }
        }

        itemObservations = [
            item.observe(\.status, options: [.initial, .new]) { _, _ in
                notifyChange()
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { _, _ in
                notifyChange()
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { _, _ in
                notifyChange()
            },
            item.observe(\.isPlaybackBufferFull, options: [.initial, .new]) { _, _ in
                notifyChange()
            },
            item.observe(\.seekableTimeRanges, options: [.initial, .new]) { _, _ in
                notifyChange()
            }
        ]

        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.observationGeneration == generation else { return }
                self?.handleItemFailure()
            }
        }
    }

    private func removeItemObservers() {
        airPlayCompatibilityTask?.cancel()
        airPlayCompatibilityTask = nil
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        if let itemFailureObserver {
            NotificationCenter.default.removeObserver(itemFailureObserver)
            self.itemFailureObserver = nil
        }
    }

    private func refreshExternalPlaybackState() {
        isExternalPlaybackActive = player.isExternalPlaybackActive
    }

    private func observePlaybackTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLiveDVRState()
            }
        }
    }

    private func currentSeekableRange() -> CMTimeRange? {
        guard let item = player.currentItem else { return nil }
        return item.seekableTimeRanges.reversed().lazy
            .map(\.timeRangeValue)
            .first { range in
                let start = range.start.seconds
                let duration = range.duration.seconds
                return start.isFinite && duration.isFinite && duration > 0
            }
    }

    private func refreshLiveDVRState() {
        guard let range = currentSeekableRange() else {
            liveDVRState = .unavailable
            return
        }
        liveDVRState = .make(
            rangeStart: range.start.seconds,
            rangeDuration: range.duration.seconds,
            currentTime: player.currentTime().seconds
        )
    }

    private func evaluateAirPlayCompatibility(of asset: AVAsset, generation: UUID) {
        airPlayVideoCompatibility = .checking
        airPlayCompatibilityTask = Task { @MainActor [weak self] in
            do {
                let isCompatible = try await asset.load(.isCompatibleWithAirPlayVideo)
                try Task.checkCancellation()
                guard self?.observationGeneration == generation else { return }
                self?.airPlayVideoCompatibility = isCompatible ? .compatible : .incompatible
            } catch is CancellationError {
                return
            } catch {
                guard self?.observationGeneration == generation else { return }
                self?.airPlayVideoCompatibility = .indeterminate
            }
        }
    }

    private func handleItemFailure() {
        player.pause()
        state = .failed(PlaybackFailure(error: player.currentItem?.error))
    }

    private func refreshState() {
        refreshLiveDVRState()
        guard let item = player.currentItem else {
            state = .idle
            return
        }

        switch item.status {
        case .unknown:
            state = .preparing
        case .failed:
            player.pause()
            state = .failed(PlaybackFailure(error: item.error))
        case .readyToPlay:
            if userPaused {
                state = .paused
                return
            }

            switch player.timeControlStatus {
            case .playing:
                state = .playing
            case .waitingToPlayAtSpecifiedRate:
                state = .buffering
            case .paused:
                state = item.isPlaybackBufferEmpty && !item.isPlaybackLikelyToKeepUp
                    ? .buffering
                    : .paused
            @unknown default:
                state = .preparing
            }
        @unknown default:
            state = .failed(PlaybackFailure(kind: .unknown))
        }
    }
}

private struct PlaybackRequest {
    let url: URL
    let channelName: String
    let allowsExternalPlayback: Bool
}

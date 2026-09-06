import AVFoundation
import AVKit
import SwiftUI
import XCTest
@testable import ChannelDeck

final class ProgrammeGuideIndexTests: XCTestCase {
    func testCurrentAndNextLookupsStayWithinOneChannelSchedule() {
        let sourceID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let previous = programme(
            id: "previous",
            channelID: "channel-a",
            sourceID: sourceID,
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800)
        )
        let current = programme(
            id: "current",
            channelID: "channel-a",
            sourceID: sourceID,
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1_500)
        )
        let next = programme(
            id: "next",
            channelID: "channel-a",
            sourceID: sourceID,
            start: current.endDate,
            end: current.endDate.addingTimeInterval(1_800)
        )
        let otherChannel = programme(
            id: "other",
            channelID: "channel-b",
            sourceID: sourceID,
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1_500)
        )

        let index = ProgrammeGuideIndex(programmes: [next, otherChannel, previous, current])

        XCTAssertEqual(index.current(channelStableID: "channel-a", at: now)?.stableID, "current")
        XCTAssertEqual(index.next(channelStableID: "channel-a", at: now)?.stableID, "next")
        XCTAssertEqual(index.current(channelStableID: "channel-b", at: now)?.stableID, "other")
        XCTAssertNil(index.current(channelStableID: "missing", at: now))
    }

    func testNextLookupUsesNowWhenNothingIsCurrentlyAiring() {
        let sourceID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let upcoming = programme(
            id: "upcoming",
            channelID: "channel-a",
            sourceID: sourceID,
            start: now.addingTimeInterval(900),
            end: now.addingTimeInterval(1_800)
        )
        let index = ProgrammeGuideIndex(programmes: [upcoming])

        XCTAssertNil(index.current(channelStableID: "channel-a", at: now))
        XCTAssertEqual(index.next(channelStableID: "channel-a", at: now)?.stableID, "upcoming")
    }

    private func programme(
        id: String,
        channelID: String,
        sourceID: UUID,
        start: Date,
        end: Date
    ) -> ProgrammeRecord {
        ProgrammeRecord(
            stableID: id,
            sourceID: sourceID,
            channelStableID: channelID,
            title: id,
            programmeDescription: nil,
            startDate: start,
            endDate: end
        )
    }
}

final class ChannelSearchIndexTests: XCTestCase {
    func testMatchesAcrossChannelGroupAndPlaylistWithFoldedTerms() {
        let index = ChannelSearchIndex(entries: [
            entry(
                id: "sports",
                name: "Télévision Málaga",
                group: "Live Sports",
                source: "Premium Europe",
                sourceOrder: 0,
                channelOrder: 5
            ),
            entry(
                id: "news",
                name: "World News",
                group: "News",
                source: "Basic",
                sourceOrder: 1,
                channelOrder: 0
            ),
        ])

        XCTAssertEqual(index.matchingIDs(for: "television malaga"), ["sports"])
        XCTAssertEqual(index.matchingIDs(for: "premium sports"), ["sports"])
        XCTAssertEqual(index.matchingIDs(for: "  WORLD   news "), ["news"])
    }

    func testRanksExactAndPrefixNamesBeforeMetadataMatches() {
        let index = ChannelSearchIndex(entries: [
            entry(id: "metadata", name: "One", group: "Sky Sports", source: "A", sourceOrder: 0, channelOrder: 0),
            entry(id: "contains", name: "The Sky Sports Show", group: "TV", source: "A", sourceOrder: 0, channelOrder: 1),
            entry(id: "prefix", name: "Sky Sports News", group: "TV", source: "B", sourceOrder: 1, channelOrder: 0),
            entry(id: "exact", name: "Sky Sports", group: "TV", source: "B", sourceOrder: 1, channelOrder: 1),
        ])

        XCTAssertEqual(
            index.matchingIDs(for: "sky sports"),
            ["exact", "prefix", "contains", "metadata"]
        )
        XCTAssertTrue(index.matchingIDs(for: "   ").isEmpty)
    }

    private func entry(
        id: String,
        name: String,
        group: String,
        source: String,
        sourceOrder: Int,
        channelOrder: Int
    ) -> ChannelSearchEntry {
        ChannelSearchEntry(
            stableID: id,
            channelName: name,
            groupName: group,
            sourceName: source,
            sourceOrder: sourceOrder,
            channelOrder: channelOrder
        )
    }
}

final class PlaybackControllerTests: XCTestCase {
    @MainActor
    func testPlayingMediaContinuesBehindGuideWithoutASeekOrRestart() async throws {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("FFmpeg is required to generate the local audio/video fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-playback-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("fixture.mp4")
        let exitStatus = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            // A real video + silent audio track exercises AVKit without making
            // noise or connecting to a provider during automated tests.
            process.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=25",
                "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "12", "-c:v", "libx264",
                "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", mediaURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        XCTAssertEqual(exitStatus, 0)
        let item = AVPlayerItem(url: mediaURL)
        let player = AVPlayer(playerItem: item)
        func workspace(showGuide: Bool) -> some View {
            PlayerWorkspace(isShowingGuide: showGuide) {
                PlayerViewRepresentable(player: player).frame(width: 640, height: 360)
            } guide: {
                Text("Programme guide")
            }
            .frame(width: 640, height: 360)
        }
        let host = NSHostingView(rootView: workspace(showGuide: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { player.pause(); player.replaceCurrentItem(with: nil); window.close() }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<500 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(item.status, .readyToPlay)
        let surface = try XCTUnwrap(videoViews(in: host).first)
        player.play()
        for _ in 0..<500 where player.currentTime().seconds < 0.1 { try await Task.sleep(for: .milliseconds(10)) }
        for showGuide in [true, false, true, false] {
            let before = player.currentTime().seconds
            host.rootView = workspace(showGuide: showGuide)
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(videoViews(in: host).first === surface)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(player.rate, 1)
            XCTAssertFalse(player.isMuted)
            XCTAssertEqual(player.volume, 1)
            XCTAssertGreaterThan(player.currentTime().seconds, before + 0.05,
                                 "The audio/video clock must continue advancing while the guide covers the video")
        }
    }

    @MainActor
    func testGuideRoundTripsKeepTheNativeVideoSurfaceAndItemMounted() async throws {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        func workspace(showGuide: Bool) -> some View {
            PlayerWorkspace(isShowingGuide: showGuide) {
                HSplitView {
                    Text("Channels").frame(width: 290)
                    VStack {
                        Text("Now playing")
                        ScrollView {
                            PlayerViewRepresentable(player: player)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            } guide: {
                Text("Programme guide")
            }
            .frame(width: 1100, height: 700)
        }
        let host = NSHostingView(rootView: workspace(showGuide: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); player.replaceCurrentItem(with: nil) }
        host.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(videoViews(in: host).first)
        let originalFrame = surface.convert(surface.bounds, to: host)
        XCTAssertGreaterThan(originalFrame.height, 300)
        XCTAssertTrue(surface.player === player)

        for showGuide in [true, false, true, false] {
            host.rootView = workspace(showGuide: showGuide)
            // Allow SwiftUI to commit its removal/insertion transaction. Merely
            // examining the old hierarchy synchronously would miss dismantles.
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let currentViews = videoViews(in: host)
            XCTAssertEqual(currentViews.count, 1)
            XCTAssertTrue(currentViews.first === surface, "The native surface must survive guide navigation")
            XCTAssertTrue(surface.window === window, "Keep the renderer attached, even behind the guide")
            XCTAssertTrue(surface.player === player)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(player.rate, 0, "Returning to video must not resume paused playback")
            XCTAssertFalse(player.allowsExternalPlayback, "Navigation must not change the output route")
            if !showGuide {
                XCTAssertEqual(surface.convert(surface.bounds, to: host), originalFrame)
            }
        }
    }

    @MainActor
    private func videoViews(in view: NSView) -> [AVPlayerView] {
        (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { videoViews(in: $0) }
    }

    func testLiveDVRStateTracksPositionAndDistanceFromLiveEdge() {
        let state = LiveDVRState.make(
            rangeStart: 100,
            rangeDuration: 300,
            currentTime: 340
        )

        XCTAssertTrue(state.isAvailable)
        XCTAssertEqual(state.windowDuration, 300)
        XCTAssertEqual(state.position, 240)
        XCTAssertEqual(state.secondsBehindLive, 60)
        XCTAssertFalse(state.isAtLiveEdge)
    }

    func testLiveDVRStateClampsToWindowAndRecognizesLiveEdge() {
        let beforeWindow = LiveDVRState.make(
            rangeStart: 100,
            rangeDuration: 300,
            currentTime: 50
        )
        let live = LiveDVRState.make(
            rangeStart: 100,
            rangeDuration: 300,
            currentTime: 399
        )

        XCTAssertEqual(beforeWindow.position, 0)
        XCTAssertEqual(beforeWindow.secondsBehindLive, 300)
        XCTAssertEqual(live.position, 299)
        XCTAssertEqual(live.secondsBehindLive, 1)
        XCTAssertTrue(live.isAtLiveEdge)
        XCTAssertEqual(
            LiveDVRState.make(
                rangeStart: .nan,
                rangeDuration: 300,
                currentTime: 100
            ),
            .unavailable
        )
    }

    @MainActor
    func testDismantlingRoutePickerPreservesSharedPlayerBinding() {
        let player = AVPlayer()
        let routePicker = AVRoutePickerView()
        routePicker.player = player

        AirPlayRoutePicker.dismantleNSView(routePicker, coordinator: ())

        XCTAssertTrue(routePicker.player === player)
    }

    @MainActor
    func testControllerConfiguresNativeExternalPlayback() {
        let player = AVPlayer()
        let controller = PlayerController(player: player)

        XCTAssertTrue(player.allowsExternalPlayback)
        XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentChannelName)
        XCTAssertFalse(controller.isExternalPlaybackActive)
        XCTAssertEqual(controller.airPlayVideoCompatibility, .unavailable)
        XCTAssertFalse(controller.currentStreamUsesInsecureTransport)
        XCTAssertNil(controller.airPlayWarningMessage)
    }

    @MainActor
    func testAirPlayReadinessPreservesTheLocalItemAndPause() {
        let controller = PlayerController()
        controller.play(
            url: URL(fileURLWithPath: "/private/tmp/local-channel.m3u8"),
            channelName: "Local channel", allowsExternalPlayback: false, preferQuickStart: true
        )
        let originalItem = controller.player.currentItem
        XCTAssertFalse(controller.player.allowsExternalPlayback)
        XCTAssertTrue(controller.player.automaticallyWaitsToMinimizeStalling,
                      "Quick startup must retain automatic recovery from later buffer underruns")
        XCTAssertEqual(originalItem?.preferredForwardBufferDuration, 1)
        controller.pause()
        controller.setExternalPlaybackAllowed(true)
        XCTAssertTrue(controller.player.currentItem === originalItem)
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertTrue(controller.player.allowsExternalPlayback)
        XCTAssertTrue(controller.player.automaticallyWaitsToMinimizeStalling)
        controller.stop()
    }

    func testRawTransportNeverFallsBackToAVPlayerFileLoading() {
        for path in ["channel.ts", "channel.TS", "live/12345", "live/12345?output=ts", "movie.mkv"] {
            XCTAssertFalse(PlaybackSourcePolicy.permitsDirectPlayback(URL(string: "http://provider.invalid/\(path)")!))
        }
        for path in ["index.m3u8", "INDEX.M3U8?output=ts", "recording.mp4"] {
            XCTAssertTrue(PlaybackSourcePolicy.permitsDirectPlayback(URL(string: "https://provider.invalid/\(path)")!))
        }
    }

    @MainActor
    func testPlayReplacesTheSinglePlayerItem() {
        let controller = PlayerController()

        controller.play(
            url: URL(string: "http://192.0.2.1/channel-one.m3u8")!,
            channelName: "Channel One"
        )
        let firstItem = controller.player.currentItem

        controller.play(
            url: URL(string: "http://192.0.2.1/channel-two.m3u8")!,
            channelName: "Channel Two"
        )

        XCTAssertNotNil(firstItem)
        XCTAssertNotNil(controller.player.currentItem)
        XCTAssertFalse(firstItem === controller.player.currentItem)
        XCTAssertEqual(controller.currentChannelName, "Channel Two")
        XCTAssertEqual(controller.state, .preparing)
        XCTAssertEqual(controller.airPlayVideoCompatibility, .checking)
        XCTAssertTrue(controller.currentStreamUsesInsecureTransport)
        XCTAssertEqual(controller.airPlayWarningMessage?.contains("HTTP"), true)
    }

    @MainActor
    func testStopClearsPlaybackAndPublicChannelState() {
        let controller = PlayerController()
        controller.play(
            url: URL(fileURLWithPath: "/private/tmp/channel.m3u8"),
            channelName: "Private Channel"
        )

        controller.stop()

        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.currentChannelName)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.airPlayVideoCompatibility, .unavailable)
        XCTAssertFalse(controller.currentStreamUsesInsecureTransport)
        XCTAssertNil(controller.airPlayWarningMessage)
        XCTAssertTrue(controller.player.allowsExternalPlayback)
    }

    @MainActor
    func testLocalRecordingPlaybackDisablesExternalHandoff() {
        let controller = PlayerController()

        controller.play(
            url: URL(fileURLWithPath: "/private/tmp/recording.ts"),
            channelName: "Saved Programme",
            allowsExternalPlayback: false
        )

        XCTAssertFalse(controller.player.allowsExternalPlayback)
        controller.retry()
        XCTAssertFalse(controller.player.allowsExternalPlayback)
    }

    func testFailureMessagesDoNotIncludeUnderlyingErrorDetails() {
        let secretURL = "https://example.invalid/user:secret/channel"
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: secretURL]
        )

        let failure = PlaybackFailure(error: error)

        XCTAssertEqual(failure.kind, .network)
        XCTAssertFalse(failure.message.contains("secret"))
        XCTAssertFalse(failure.message.contains("example.invalid"))
    }

    func testWrappedTransportSecurityFailureIsClassifiedWithoutLeakingURL() {
        let secretURL = "http://192.0.2.1/user:secret/channel"
        let transportError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection,
            userInfo: [NSURLErrorFailingURLStringErrorKey: secretURL]
        )
        let playerError = NSError(
            domain: AVFoundationErrorDomain,
            code: -11800,
            userInfo: [NSUnderlyingErrorKey: transportError]
        )

        let failure = PlaybackFailure(error: playerError)

        XCTAssertEqual(failure.kind, .insecureTransport)
        XCTAssertFalse(failure.message.contains("secret"))
        XCTAssertFalse(failure.message.contains("192.0.2.1"))
    }

    func testExternalPlaybackFailureIsSafeAndActionable() {
        let error = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.externalPlaybackNotSupportedForAsset.rawValue
        )

        let failure = PlaybackFailure(error: error)

        XCTAssertEqual(failure.kind, .airPlayUnavailable)
        XCTAssertTrue(failure.message.contains("Screen Mirroring"))
    }
}

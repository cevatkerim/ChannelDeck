import AVFoundation
import AVKit
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

final class PlaybackControllerTests: XCTestCase {
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

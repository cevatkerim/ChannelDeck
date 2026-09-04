import Foundation
import XCTest
@testable import ChannelDeck

final class RelayHLSCoreTests: XCTestCase {
    private let relayOrigin = URL(string: "https://relay.example:8443")!
    private static let fixedToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    func testSessionRewritesRootAndRelaysRangeRequestWithSafeHeaders() async throws {
        let rootURL = URL(string: "http://provider.invalid/live/index.m3u8?account=private")!
        let segmentURL = URL(string: "http://provider.invalid/live/segment.ts?credential=hidden")!
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        segment.ts?credential=hidden
        """
        let upstream = RelayUpstreamStub(responses: [
            rootURL: [
                HLSRelayUpstreamResponse(
                    statusCode: 200,
                    body: Data(playlist.utf8),
                    finalURL: rootURL,
                    contentType: "application/x-mpegURL",
                    contentLength: Int64(playlist.utf8.count),
                    etag: "root-v1"
                )
            ],
            segmentURL: [
                HLSRelayUpstreamResponse(
                    statusCode: 206,
                    body: Data([1, 2, 3, 4]),
                    finalURL: segmentURL,
                    contentType: "video/mp2t",
                    contentLength: 4,
                    contentRange: "bytes 10-13/100",
                    acceptRanges: "bytes",
                    cacheControl: "public, max-age=120"
                )
            ]
        ])
        let core = makeCore(upstream: upstream)
        let session = try await core.createSession(sourceURL: rootURL, relayOrigin: relayOrigin)

        XCTAssertTrue(session.playlistURL.absoluteString.contains(Self.fixedToken))
        XCTAssertFalse(session.playlistURL.absoluteString.contains("provider"))
        let rootResponse = try await core.handle(request(path: session.playlistURL.path))
        let rewritten = try XCTUnwrap(String(data: rootResponse.body, encoding: .utf8))
        let segmentRelayURL = try XCTUnwrap(
            rewritten.split(separator: "\n")
                .map(String.init)
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })
                .flatMap(URL.init(string:))
        )
        XCTAssertEqual(segmentRelayURL.pathExtension, "ts")

        XCTAssertEqual(rootResponse.statusCode, 200)
        XCTAssertEqual(rootResponse.headers["Content-Type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(rootResponse.headers["Cache-Control"], "no-cache, no-store, must-revalidate")
        XCTAssertFalse(rewritten.contains("provider.invalid"))
        XCTAssertFalse(rewritten.contains("credential"))

        let segmentResponse = try await core.handle(
            request(path: segmentRelayURL.path, range: "bytes=10-13")
        )
        XCTAssertEqual(segmentResponse.statusCode, 206)
        XCTAssertEqual(segmentResponse.body, Data([1, 2, 3, 4]))
        XCTAssertEqual(segmentResponse.headers["Content-Type"], "video/mp2t")
        XCTAssertEqual(segmentResponse.headers["Content-Range"], "bytes 10-13/100")
        XCTAssertEqual(segmentResponse.headers["Accept-Ranges"], "bytes")
        XCTAssertEqual(segmentResponse.headers["Content-Length"], "4")

        let requests = await upstream.capturedRequests()
        XCTAssertEqual(requests.last?.url, segmentURL)
        XCTAssertEqual(requests.last?.range, "bytes=10-13")
    }

    func testLivePlaylistIsFetchedAgainAfterInitialResponse() async throws {
        let rootURL = URL(string: "https://provider.invalid/live/index.m3u8")!
        let first = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:2,\na.ts\n"
        let second = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:2\n#EXTINF:2,\nb.ts\n"
        let upstream = RelayUpstreamStub(responses: [
            rootURL: [response(first, url: rootURL), response(second, url: rootURL)]
        ])
        let core = makeCore(upstream: upstream)
        let session = try await core.createSession(sourceURL: rootURL, relayOrigin: relayOrigin)

        let initial = try await core.handle(request(path: session.playlistURL.path))
        let refreshed = try await core.handle(request(path: session.playlistURL.path))
        let initialText = String(decoding: initial.body, as: UTF8.self)
        let refreshedText = String(decoding: refreshed.body, as: UTF8.self)

        XCTAssertTrue(initialText.contains("MEDIA-SEQUENCE:1"))
        XCTAssertTrue(refreshedText.contains("MEDIA-SEQUENCE:2"))
        let requestCount = await upstream.requestCount(for: rootURL)
        XCTAssertEqual(requestCount, 2)
    }

    func testRejectsRawContinuousTransportStreamsBeforeOrAfterPreflight() async throws {
        let upstream = RelayUpstreamStub(responses: [:])
        let core = makeCore(upstream: upstream)
        await XCTAssertThrowsErrorAsync(
            try await core.createSession(
                sourceURL: URL(string: "https://provider.invalid/live/channel.ts")!,
                relayOrigin: relayOrigin
            )
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .unsupportedContinuousTransportStream)
        }
        let initialRequestCount = await upstream.totalRequestCount()
        XCTAssertEqual(initialRequestCount, 0)

        let extensionless = URL(string: "https://provider.invalid/live/channel")!
        let transportUpstream = RelayUpstreamStub(responses: [
            extensionless: [
                HLSRelayUpstreamResponse(
                    statusCode: 200,
                    body: Data([0x47, 0x00, 0x00]),
                    finalURL: extensionless,
                    contentType: "video/mp2t"
                )
            ]
        ])
        let secondCore = makeCore(upstream: transportUpstream)
        await XCTAssertThrowsErrorAsync(
            try await secondCore.createSession(sourceURL: extensionless, relayOrigin: relayOrigin)
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .unsupportedContinuousTransportStream)
        }
    }

    func testRejectsInvalidRangeWithoutCallingUpstream() async throws {
        let rootURL = URL(string: "https://provider.invalid/index.m3u8")!
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n"
        let upstream = RelayUpstreamStub(responses: [
            rootURL: [response(playlist, url: rootURL)]
        ])
        let core = makeCore(upstream: upstream)
        let session = try await core.createSession(sourceURL: rootURL, relayOrigin: relayOrigin)
        let root = try await core.handle(request(path: session.playlistURL.path))
        let text = String(decoding: root.body, as: UTF8.self)
        let segmentPath = try XCTUnwrap(
            text.split(separator: "\n").first(where: { !$0.hasPrefix("#") }).flatMap {
                URL(string: String($0))?.path
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await core.handle(request(path: segmentPath, range: "bytes=0-1,4-5"))
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .invalidRequest)
        }
        let requestCount = await upstream.totalRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testServesRegisteredTranscodedPlaylistAndSegmentForGetAndHead() async throws {
        let rootURL = URL(string: "https://provider.invalid/index.m3u8")!
        let upstream = RelayUpstreamStub(responses: [
            rootURL: [response(minimalPlaylist, url: rootURL)]
        ])
        let core = makeCore(upstream: upstream)
        let session = try await core.createSession(sourceURL: rootURL, relayOrigin: relayOrigin)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nmedia-0.m3u8\n"
        let mediaPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:12
        #EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:00:00.000+02:00
        #EXTINF:4,
        segment-0-000000000.ts

        """
        let segment = Data([0, 1, 2, 3, 4, 5, 6, 7])
        try Data(playlist.utf8).write(to: directory.appendingPathComponent("index.m3u8"))
        try Data(mediaPlaylist.utf8).write(to: directory.appendingPathComponent("media-0.m3u8"))
        try segment.write(to: directory.appendingPathComponent("segment-0-000000000.ts"))

        let transcodedURL = try await core.registerTranscodedOutputDirectory(directory, for: session)
        XCTAssertEqual(
            transcodedURL.path,
            "/s/\(Self.fixedToken)/transcoded/index.m3u8"
        )
        XCTAssertFalse(transcodedURL.absoluteString.contains(directory.path))

        let playlistGET = try await core.handle(request(path: transcodedURL.path))
        XCTAssertEqual(playlistGET.statusCode, 200)
        XCTAssertEqual(playlistGET.body, Data(playlist.utf8))
        XCTAssertEqual(playlistGET.headers["Content-Type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(playlistGET.headers["Content-Length"], String(playlist.utf8.count))
        XCTAssertEqual(playlistGET.headers["Cache-Control"], "no-cache, no-store, must-revalidate")
        XCTAssertEqual(playlistGET.headers["Accept-Ranges"], "bytes")

        let playlistHEAD = try await core.handle(
            request(method: .head, path: transcodedURL.path)
        )
        XCTAssertEqual(playlistHEAD.statusCode, 200)
        XCTAssertTrue(playlistHEAD.body.isEmpty)
        XCTAssertEqual(playlistHEAD.headers["Content-Length"], String(playlist.utf8.count))

        let playlistRange = try await core.handle(
            request(path: transcodedURL.path, range: "bytes=0-6")
        )
        XCTAssertEqual(playlistRange.statusCode, 206)
        XCTAssertEqual(playlistRange.body, Data(playlist.utf8.prefix(7)))
        XCTAssertEqual(
            playlistRange.headers["Content-Range"],
            "bytes 0-6/\(playlist.utf8.count)"
        )

        let mediaPath = transcodedURL.deletingLastPathComponent()
            .appendingPathComponent("media-0.m3u8").path
        let mediaGET = try await core.handle(request(path: mediaPath))
        XCTAssertEqual(mediaGET.statusCode, 200)
        XCTAssertEqual(mediaGET.body, Data(mediaPlaylist.utf8))
        XCTAssertEqual(mediaGET.headers["Content-Type"], "application/vnd.apple.mpegurl")
        XCTAssertEqual(mediaGET.headers["Cache-Control"], "no-cache, no-store, must-revalidate")

        let segmentPath = transcodedURL.deletingLastPathComponent()
            .appendingPathComponent("segment-0-000000000.ts").path
        let segmentGET = try await core.handle(request(path: segmentPath))
        XCTAssertEqual(segmentGET.statusCode, 200)
        XCTAssertEqual(segmentGET.body, segment)
        XCTAssertEqual(segmentGET.headers["Content-Type"], "video/mp2t")
        XCTAssertEqual(segmentGET.headers["Cache-Control"], "public, max-age=60")
        let upstreamRequestCount = await upstream.totalRequestCount()
        XCTAssertEqual(upstreamRequestCount, 1)
    }

    func testGzipsFullTranscodedMasterAndMediaPlaylistsWithMatchingHeadLength() async throws {
        let fixture = try await makeTranscodedFixture(segment: Data([0, 1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent()) }
        let mediaPlaylist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:12
        #EXT-X-PROGRAM-DATE-TIME:2026-09-05T00:00:00.000+02:00
        #EXTINF:4,
        segment-0-000000000.ts

        """
        try Data(mediaPlaylist.utf8).write(
            to: fixture.directory.appendingPathComponent("media-0.m3u8")
        )
        let mediaPath = fixture.playlistURL.deletingLastPathComponent()
            .appendingPathComponent("media-0.m3u8").path

        for (path, expected) in [
            (fixture.playlistURL.path, "#EXTM3U\n#EXTINF:4,\nsegment-0-000000000.ts\n"),
            (mediaPath, mediaPlaylist)
        ] {
            let get = try await fixture.core.handle(
                request(path: path, acceptsGzip: true)
            )
            XCTAssertEqual(get.statusCode, 200)
            XCTAssertEqual(get.headers["Content-Encoding"], "gzip")
            XCTAssertEqual(get.headers["Vary"], "Accept-Encoding")
            XCTAssertEqual(get.headers["Content-Length"], String(get.body.count))
            XCTAssertEqual(
                try GzipDecompressor.decompress(
                    get.body,
                    maximumExpandedBytes: expected.utf8.count
                ),
                Data(expected.utf8)
            )

            let head = try await fixture.core.handle(
                request(method: .head, path: path, acceptsGzip: true)
            )
            XCTAssertEqual(head.statusCode, 200)
            XCTAssertTrue(head.body.isEmpty)
            XCTAssertEqual(head.headers["Content-Encoding"], "gzip")
            XCTAssertEqual(head.headers["Vary"], "Accept-Encoding")
            XCTAssertEqual(head.headers["Content-Length"], get.headers["Content-Length"])
        }
    }

    func testGzipNegotiationLeavesPlaylistRangesAndSegmentsIdentityEncoded() async throws {
        let segment = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let fixture = try await makeTranscodedFixture(segment: segment)
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent()) }

        let playlistRange = try await fixture.core.handle(
            request(
                path: fixture.playlistURL.path,
                range: "bytes=0-6",
                acceptsGzip: true
            )
        )
        XCTAssertEqual(playlistRange.statusCode, 206)
        XCTAssertEqual(playlistRange.body, Data("#EXTM3U".utf8))
        XCTAssertNil(playlistRange.headers["Content-Encoding"])
        XCTAssertEqual(playlistRange.headers["Vary"], "Accept-Encoding")

        let segmentPath = fixture.playlistURL.deletingLastPathComponent()
            .appendingPathComponent("segment-0-000000000.ts").path
        let segmentResponse = try await fixture.core.handle(
            request(path: segmentPath, acceptsGzip: true)
        )
        XCTAssertEqual(segmentResponse.statusCode, 200)
        XCTAssertEqual(segmentResponse.body, segment)
        XCTAssertNil(segmentResponse.headers["Content-Encoding"])
        XCTAssertNil(segmentResponse.headers["Vary"])
    }

    func testServesSingleLocalByteRangesAndUnsatisfiableRange() async throws {
        let fixture = try await makeTranscodedFixture(segment: Data([0, 1, 2, 3, 4, 5, 6, 7]))
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent()) }
        let segmentPath = fixture.playlistURL.deletingLastPathComponent()
            .appendingPathComponent("segment-0-000000000.ts").path

        let bounded = try await fixture.core.handle(
            request(path: segmentPath, range: "bytes=2-5")
        )
        XCTAssertEqual(bounded.statusCode, 206)
        XCTAssertEqual(bounded.body, Data([2, 3, 4, 5]))
        XCTAssertEqual(bounded.headers["Content-Length"], "4")
        XCTAssertEqual(bounded.headers["Content-Range"], "bytes 2-5/8")

        let suffixHEAD = try await fixture.core.handle(
            request(method: .head, path: segmentPath, range: "bytes=-3")
        )
        XCTAssertEqual(suffixHEAD.statusCode, 206)
        XCTAssertTrue(suffixHEAD.body.isEmpty)
        XCTAssertEqual(suffixHEAD.headers["Content-Length"], "3")
        XCTAssertEqual(suffixHEAD.headers["Content-Range"], "bytes 5-7/8")

        let openEnded = try await fixture.core.handle(
            request(path: segmentPath, range: "bytes=6-")
        )
        XCTAssertEqual(openEnded.statusCode, 206)
        XCTAssertEqual(openEnded.body, Data([6, 7]))
        XCTAssertEqual(openEnded.headers["Content-Range"], "bytes 6-7/8")

        let unsatisfiable = try await fixture.core.handle(
            request(path: segmentPath, range: "bytes=8-20")
        )
        XCTAssertEqual(unsatisfiable.statusCode, 416)
        XCTAssertTrue(unsatisfiable.body.isEmpty)
        XCTAssertEqual(unsatisfiable.headers["Content-Length"], "0")
        XCTAssertEqual(unsatisfiable.headers["Content-Range"], "bytes */8")
    }

    func testTranscodedRouteRejectsTraversalUnexpectedNamesAndSymlinks() async throws {
        let fixture = try await makeTranscodedFixture(segment: Data([0, 1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: fixture.directory.deletingLastPathComponent()) }
        let basePath = "/s/\(Self.fixedToken)/transcoded"

        for path in [
            "\(basePath)/../index.m3u8",
            "\(basePath)/%2e%2e",
            "\(basePath)//index.m3u8",
            "\(basePath)/segment-0.ts/extra",
            "\(basePath)/arbitrary.ts",
            "\(basePath)/segment--1.ts",
            "\(basePath)/media-1.m3u8",
            "\(basePath)/media-0.m3u8?ignored=true",
            "\(basePath)/segment-0-1.ts",
            "\(basePath)/segment-1-000000001.ts",
            "\(basePath)/segment-0-000000001.ts?ignored=true"
        ] {
            await XCTAssertThrowsErrorAsync(
                try await fixture.core.handle(request(path: path))
            ) { error in
                XCTAssertEqual(error as? HLSRelayError, .invalidRequest, "path: \(path)")
            }
        }

        let outsideFile = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("outside.ts")
        try Data([9, 9, 9]).write(to: outsideFile)
        let symlink = fixture.directory.appendingPathComponent("segment-0-000000009.ts")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: outsideFile
        )
        await XCTAssertThrowsErrorAsync(
            try await fixture.core.handle(request(path: "\(basePath)/segment-0-000000009.ts"))
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .resourceNotFound)
        }
    }

    func testRejectsSymlinkedOutputDirectoryAndInvalidationDoesNotDeleteArtifacts() async throws {
        let rootURL = URL(string: "https://provider.invalid/index.m3u8")!
        let upstream = RelayUpstreamStub(responses: [
            rootURL: [response(minimalPlaylist, url: rootURL)]
        ])
        let core = makeCore(upstream: upstream)
        let session = try await core.createSession(sourceURL: rootURL, relayOrigin: relayOrigin)
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let playlistFile = directory.appendingPathComponent("index.m3u8")
        try Data(minimalPlaylist.utf8).write(to: playlistFile)
        let directoryLink = parent.appendingPathComponent("output-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)

        await XCTAssertThrowsErrorAsync(
            try await core.registerTranscodedOutputDirectory(directoryLink, for: session)
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .invalidTranscodedOutputDirectory)
        }

        let transcodedURL = try await core.registerTranscodedOutputDirectory(directory, for: session)
        await core.invalidateAllSessions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: playlistFile.path))
        await XCTAssertThrowsErrorAsync(
            try await core.handle(request(path: transcodedURL.path))
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .sessionNotFound)
        }
    }

    func testCreatesTranscodingOnlySessionWithoutFetchingProviderAndPublishesOutput() async throws {
        let upstream = RelayUpstreamStub(responses: [:])
        let core = makeCore(upstream: upstream)
        let session = try await core.createTranscodingSession(relayOrigin: relayOrigin)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let publicURL = try await core.registerTranscodedOutputDirectory(directory, for: session)
        let upstreamRequestCount = await upstream.totalRequestCount()

        XCTAssertEqual(publicURL.path, "/s/\(Self.fixedToken)/transcoded/index.m3u8")
        XCTAssertEqual(upstreamRequestCount, 0)
        await XCTAssertThrowsErrorAsync(
            try await core.handle(request(path: session.playlistURL.path))
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .resourceNotFound)
        }
    }

    func testCoordinatorStreamsRawTransportIntoTranscoderWithoutWholeBodyPreflight() async throws {
        let upstream = RelayUpstreamStub(responses: [:])
        let core = makeCore(upstream: upstream)
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        try Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia-0.m3u8\n".utf8)
            .write(to: output.appendingPathComponent("index.m3u8"))
        let transcoder = RelayAudioTranscoderStub(outputDirectory: output)
        let streamer = RelayMPEGTSStreamerStub(payload: Data([0x47, 0x01, 0x02]))
        let coordinator = HLSRelaySessionCoordinator(
            core: core,
            audioTranscoder: transcoder,
            mpegTSStreamer: streamer,
            preparationTimeout: .seconds(2)
        )
        let sourceURL = URL(string: "http://provider.invalid/live/channel.ts?credential=private")!

        let session = try await coordinator.prepare(sourceURL: sourceURL, relayOrigin: relayOrigin)
        let upstreamRequestCount = await upstream.totalRequestCount()
        let streamedSourceURL = await streamer.capturedSourceURL()
        let rawInput = await transcoder.rawInputBytes()
        let relayInputURLs = await transcoder.relayInputURLs()

        XCTAssertEqual(session.playlistURL.path, "/s/\(Self.fixedToken)/transcoded/index.m3u8")
        XCTAssertEqual(upstreamRequestCount, 0)
        XCTAssertEqual(streamedSourceURL, sourceURL)
        XCTAssertEqual(rawInput, Data([0x47, 0x01, 0x02]))
        XCTAssertEqual(relayInputURLs, [])
        await coordinator.stop()
    }

    func testCoordinatorTimesOutRawPreparationCancelsProducerAndClearsSession() async throws {
        let upstream = RelayUpstreamStub(responses: [:])
        let core = makeCore(upstream: upstream)
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let transcoder = RelayAudioTranscoderStub(outputDirectory: output)
        let streamer = RelayMPEGTSStreamerStub(payload: nil)
        let coordinator = HLSRelaySessionCoordinator(
            core: core,
            audioTranscoder: transcoder,
            mpegTSStreamer: streamer,
            preparationTimeout: .milliseconds(100)
        )
        let sourceURL = URL(string: "https://provider.invalid/live/channel.ts")!
        let clock = ContinuousClock()
        let started = clock.now

        await XCTAssertThrowsErrorAsync(
            try await coordinator.prepare(sourceURL: sourceURL, relayOrigin: relayOrigin)
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .preparationTimedOut)
        }

        let elapsed = started.duration(to: clock.now)
        let producerWasCancelled = await streamer.wasCancelled()
        let stopCount = await transcoder.stopCount()
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(producerWasCancelled)
        XCTAssertGreaterThanOrEqual(stopCount, 2)
        await XCTAssertThrowsErrorAsync(
            try await core.handle(
                request(path: "/s/\(Self.fixedToken)/transcoded/index.m3u8")
            )
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .sessionNotFound)
        }
    }

    func testCoordinatorBoundsWholeBodyHLSPreflightAndCancelsFetch() async {
        let upstream = RelayHangingUpstreamStub()
        let core = HLSRelayCore(
            upstream: upstream,
            sessionTokenGenerator: { Self.fixedToken }
        )
        let coordinator = HLSRelaySessionCoordinator(
            core: core,
            audioTranscoder: nil,
            mpegTSStreamer: nil,
            preparationTimeout: .milliseconds(100)
        )
        let clock = ContinuousClock()
        let started = clock.now

        await XCTAssertThrowsErrorAsync(
            try await coordinator.prepare(
                sourceURL: URL(string: "https://provider.invalid/live/index.m3u8")!,
                relayOrigin: relayOrigin
            )
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .preparationTimedOut)
        }

        let elapsed = started.duration(to: clock.now)
        let fetchWasCancelled = await upstream.wasCancelled()
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(fetchWasCancelled)
    }

    private func makeCore(upstream: RelayUpstreamStub) -> HLSRelayCore {
        HLSRelayCore(upstream: upstream, sessionTokenGenerator: { Self.fixedToken })
    }

    private var minimalPlaylist: String {
        "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nupstream.ts\n"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChannelDeckRelayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeTranscodedFixture(
        segment: Data
    ) async throws -> (core: HLSRelayCore, playlistURL: URL, directory: URL) {
        let rootURL = URL(string: "https://provider.invalid/index.m3u8")!
        let upstream = RelayUpstreamStub(responses: [
            rootURL: [response(minimalPlaylist, url: rootURL)]
        ])
        let core = makeCore(upstream: upstream)
        let session = try await core.createSession(sourceURL: rootURL, relayOrigin: relayOrigin)
        let parent = try makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("#EXTM3U\n#EXTINF:4,\nsegment-0-000000000.ts\n".utf8)
            .write(to: directory.appendingPathComponent("index.m3u8"))
        try segment.write(to: directory.appendingPathComponent("segment-0-000000000.ts"))
        let playlistURL = try await core.registerTranscodedOutputDirectory(directory, for: session)
        return (core, playlistURL, directory)
    }

    private func request(
        method: HLSRelayUpstreamMethod = .get,
        path: String,
        range: String? = nil,
        acceptsGzip: Bool = false
    ) -> HLSRelayRequest {
        HLSRelayRequest(
            method: method,
            path: path,
            range: range,
            ifNoneMatch: nil,
            ifModifiedSince: nil,
            acceptsGzip: acceptsGzip
        )
    }

    private func response(_ playlist: String, url: URL) -> HLSRelayUpstreamResponse {
        HLSRelayUpstreamResponse(
            statusCode: 200,
            body: Data(playlist.utf8),
            finalURL: url,
            contentType: "application/vnd.apple.mpegurl",
            contentLength: Int64(playlist.utf8.count)
        )
    }
}

private actor RelayUpstreamStub: HLSRelayUpstreamFetching {
    private var responses: [URL: [HLSRelayUpstreamResponse]]
    private var requests: [HLSRelayUpstreamRequest] = []

    init(responses: [URL: [HLSRelayUpstreamResponse]]) {
        self.responses = responses
    }

    func fetch(_ request: HLSRelayUpstreamRequest) throws -> HLSRelayUpstreamResponse {
        requests.append(request)
        guard var queued = responses[request.url], !queued.isEmpty else {
            throw HLSRelayError.upstreamFailure
        }
        let response = queued.removeFirst()
        responses[request.url] = queued
        return response
    }

    func capturedRequests() -> [HLSRelayUpstreamRequest] {
        requests
    }

    func requestCount(for url: URL) -> Int {
        requests.count { $0.url == url }
    }

    func totalRequestCount() -> Int {
        requests.count
    }
}

private actor RelayAudioTranscoderStub: HLSAudioTranscoding {
    private let outputDirectory: URL
    private let consumer = RelayMPEGTSConsumerStub()
    private var relayURLs: [URL] = []
    private var stops = 0

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func start(relayURL: URL) async throws -> FFmpegHLSAudioTranscodeSession {
        relayURLs.append(relayURL)
        return session
    }

    func startMPEGTS(feeding feed: @escaping MPEGTSFeeding) async throws
        -> FFmpegHLSAudioTranscodeSession {
        try await feed(consumer)
        return session
    }

    func stop() {
        stops += 1
    }

    func rawInputBytes() async -> Data {
        await consumer.bytes()
    }

    func relayInputURLs() -> [URL] {
        relayURLs
    }

    func stopCount() -> Int {
        stops
    }

    private var session: FFmpegHLSAudioTranscodeSession {
        FFmpegHLSAudioTranscodeSession(
            playlistURL: outputDirectory.appendingPathComponent("index.m3u8")
        )
    }
}

private actor RelayMPEGTSConsumerStub: MPEGTSByteConsuming {
    private var received = Data()

    func consume(_ bytes: Data) {
        received.append(bytes)
    }

    func bytes() -> Data {
        received
    }
}

private actor RelayMPEGTSStreamerStub: MPEGTSUpstreamStreaming {
    private let payload: Data?
    private var sourceURL: URL?
    private var cancelled = false

    init(payload: Data?) {
        self.payload = payload
    }

    func stream(from sourceURL: URL, into consumer: any MPEGTSByteConsuming) async throws {
        self.sourceURL = sourceURL
        if let payload {
            try await consumer.consume(payload)
            return
        }
        do {
            while true {
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func capturedSourceURL() -> URL? {
        sourceURL
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor RelayHangingUpstreamStub: HLSRelayUpstreamFetching {
    private var cancelled = false

    func fetch(_ request: HLSRelayUpstreamRequest) async throws -> HLSRelayUpstreamResponse {
        do {
            while true {
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (any Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}

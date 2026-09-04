import XCTest
@testable import ChannelDeck

final class RelayHLSPlaylistRewriterTests: XCTestCase {
    func testRewritesMasterPlaylistLinesAndURIAttributesWithoutLeakingUpstreamURLs() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio/main.m3u8?token=secret,part"
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=86000,URI="iframe.m3u8"
        #EXT-X-SESSION-KEY:METHOD=AES-128,URI="keys/session.key?credential=hidden"
        #EXT-X-SESSION-DATA:DATA-ID="com.example",URI="metadata.json"
        #EXT-X-CONTENT-STEERING:SERVER-URI="steering.json",PATHWAY-ID="cdn-a"
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,AUDIO="audio"
        video/main.m3u8?auth=private
        """
        var captured: [(URL, HLSRelayResourceKind)] = []

        let outputData = try HLSPlaylistRewriter().rewrite(
            Data(playlist.utf8),
            relativeTo: URL(string: "http://upstream.invalid/live/master.m3u8?account=private")!
        ) { url, kind in
            captured.append((url, kind))
            return URL(string: "https://relay.example/s/session/r/\(captured.count)")!
        }
        let output = try XCTUnwrap(String(data: outputData, encoding: .utf8))

        XCTAssertEqual(captured.count, 6)
        XCTAssertEqual(captured[0].1, .playlist)
        XCTAssertEqual(captured[1].1, .playlist)
        XCTAssertEqual(captured[2].1, .media)
        XCTAssertEqual(captured[5].1, .playlist)
        XCTAssertTrue(captured[0].0.absoluteString.contains("secret,part"))
        XCTAssertFalse(output.contains("upstream.invalid"))
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("credential"))
        XCTAssertFalse(output.contains("private"))
        XCTAssertEqual(output.components(separatedBy: "https://relay.example").count - 1, 6)
    }

    func testRewritesMediaPlaylistKeysMapsPartsAndSegments() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXT-X-PART:DURATION=0.333,URI="part.0.m4s"
        #EXT-X-PRELOAD-HINT:TYPE=PART,URI="part.1.m4s"
        #EXTINF:6,
        segment.ts
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://license.example/key"
        """
        var capturedURLs: [URL] = []

        let outputData = try HLSPlaylistRewriter().rewrite(
            Data(playlist.utf8),
            relativeTo: URL(string: "https://media.example/path/index.m3u8")!
        ) { url, _ in
            capturedURLs.append(url)
            return URL(string: "https://relay.example/resource/\(capturedURLs.count)")!
        }
        let output = try XCTUnwrap(String(data: outputData, encoding: .utf8))

        XCTAssertEqual(capturedURLs.map(\.lastPathComponent), [
            "key.bin", "init.mp4", "part.0.m4s", "part.1.m4s", "segment.ts"
        ])
        XCTAssertTrue(output.contains("skd://license.example/key"))
        XCTAssertFalse(output.contains("media.example"))
    }

    func testRejectsNonHLSM3UAndInvalidUTF8() {
        let channelList = Data("#EXTM3U\n#EXTINF:-1,Channel\nhttp://example.invalid/live.ts\n".utf8)
        XCTAssertThrowsError(
            try HLSPlaylistRewriter().rewrite(
                channelList,
                relativeTo: URL(string: "https://example.invalid/list.m3u")!,
                relayURL: { url, _ in url }
            )
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .sourceIsNotHLS)
        }

        XCTAssertThrowsError(
            try HLSPlaylistRewriter().rewrite(
                Data([0xff, 0xfe]),
                relativeTo: URL(string: "https://example.invalid/list.m3u8")!,
                relayURL: { url, _ in url }
            )
        ) { error in
            XCTAssertEqual(error as? HLSRelayError, .invalidPlaylistEncoding)
        }
    }
}

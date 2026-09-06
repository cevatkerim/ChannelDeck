import XCTest

@MainActor
final class TVRemoteTests: XCTestCase {
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
    func testLargePlaylistScrollsContinuouslyThroughGroupsAndGuide() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/large-playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for large library tests.") }
        let app = XCUIApplication()
        app.launchArguments = ["--fixture", "--fixture-large", "--fixture-autoplay", "--ui-testing"]
        app.launch()
        defer { app.terminate() }
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForFocus(app.buttons["Pause"]), "Wait for the fullscreen presentation to accept remote commands.")
        // Verify physical Play/Pause after the presentation has established focus.
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 4))
        remote.press(.up)
        XCTAssertTrue(app.buttons["Show channel drawer"].hasFocus)
        remote.press(.select)
        let group = app.buttons["Choose group Test channels"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(group.hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Switch to Synthetic MPEG-TS"].waitForExistence(timeout: 4))
        remote.press(.playPause)
        XCTAssertFalse(app.buttons["Next"].exists)
        for _ in 0..<16 { remote.press(.down) }
        XCTAssertTrue(app.staticTexts["Switch channel"].exists)
        XCTAssertTrue(app.buttons["Switch to Synthetic channel 0016"].hasFocus)
        remote.press(.menu)
        XCTAssertTrue(group.waitForExistence(timeout: 4))
        remote.press(.menu)
        XCTAssertFalse(app.staticTexts["Switch channel"].exists)
        remote.press(.select)
        remote.press(.up)
        remote.press(.right)
        XCTAssertTrue(app.buttons["Mini player"].hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Return to fullscreen"].waitForExistence(timeout: 5))
        if !app.tabBars.buttons.allElementsBoundByIndex.contains(where: { $0.hasFocus }) { remote.press(.menu) }
        let guide = app.tabBars.buttons["Guide"]
        for _ in 0..<5 { if guide.hasFocus { break }; remote.press(.right) }
        XCTAssertTrue(guide.hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["500 channels"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Next channels"].exists)
        for _ in 0..<16 { remote.press(.down) }
        XCTAssertTrue(app.buttons["Guide channel Synthetic channel 0013"].hasFocus, "Down must move focus through the guide's channel rows.")
        let scrolledGuide = XCTAttachment(screenshot: app.screenshot())
        scrolledGuide.name = "Continuous guide scrolling"
        scrolledGuide.lifetime = .keepAlways
        add(scrolledGuide)
        XCTAssertTrue(app.buttons["Return to fullscreen"].exists)
        remote.press(.menu)
        XCTAssertTrue(guide.hasFocus, "Back must respond after scrolling through a large guide.")

    }
    func testChannelDrawerAndMiniPlayerNavigation() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for remote playback tests.") }
        let app = XCUIApplication()
        app.launchArguments = ["--fixture", "--fixture-autoplay", "--ui-testing"]
        app.launch()
        defer { app.terminate() }
        let remote = XCUIRemote.shared
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForFocus(app.buttons["Pause"]), "Wait for the fullscreen presentation to accept remote commands.")
        remote.press(.menu)
        XCTAssertTrue(app.buttons["Show playback controls"].waitForExistence(timeout: 4))
        remote.press(.right)
        XCTAssertTrue(app.staticTexts["Switch channel"].waitForExistence(timeout: 4))
        let group = app.buttons["Choose group Test channels"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.hasFocus)
        remote.press(.select)
        let current = app.buttons["Switch to Synthetic MPEG-TS"]
        XCTAssertTrue(current.hasFocus)
        let drawer = XCTAttachment(screenshot: app.screenshot())
        drawer.name = "Channel drawer"
        drawer.lifetime = .keepAlways
        add(drawer)
        remote.press(.up)
        let other = app.buttons["Switch to Synthetic HLS"]
        if !other.hasFocus { remote.press(.down); remote.press(.down) }
        XCTAssertTrue(other.hasFocus)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(app.buttons["Pause"]))
        XCTAssertTrue(app.staticTexts["Synthetic HLS"].exists)
        XCTAssertFalse(app.staticTexts["Switch channel"].exists)
        remote.press(.up)
        XCTAssertTrue(app.buttons["Show channel drawer"].hasFocus)
        remote.press(.right)
        XCTAssertTrue(app.buttons["Mini player"].hasFocus)
        remote.press(.select)
        let expand = app.buttons["Return to fullscreen"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        // The library stays interactive underneath the floating video.
        if !app.tabBars.buttons.allElementsBoundByIndex.contains(where: { $0.hasFocus }) { remote.press(.menu) }
        let guide = app.tabBars.buttons["Guide"]
        for _ in 0..<5 {
            if guide.hasFocus { break }
            remote.press(.right)
        }
        XCTAssertTrue(guide.hasFocus)
        remote.press(.select)
        XCTAssertTrue(expand.exists)
        let mini = XCTAttachment(screenshot: app.screenshot())
        mini.name = "Mini player over guide"
        mini.lifetime = .keepAlways
        add(mini)
        // Backgrounding still discards temporary media and closes the mini player.
        remote.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(expand.exists)
    }
    func testRemoteRevealsControlsAndRestoresFocusAfterTheyHide() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/playlist.m3u")!)
        request.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Start Scripts/tvos_fixture_server.py for remote playback tests.") }
        let app = XCUIApplication()
        app.launchArguments = ["--fixture", "--fixture-autoplay", "--ui-testing"]
        app.launch()
        defer { app.terminate() }
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForFocus(pause), "Wait for the fullscreen presentation to accept remote commands.")
        let remote = XCUIRemote.shared
        remote.press(.menu)
        XCTAssertTrue(app.buttons["Show playback controls"].waitForExistence(timeout: 3))
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3), "A hidden-toolbar Play/Pause press must toggle exactly once.")
        remote.press(.playPause)
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        remote.press(.menu)
        XCTAssertTrue(app.buttons["Show playback controls"].waitForExistence(timeout: 3))
        remote.press(.select)
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        XCTAssertTrue(pause.hasFocus)
        let controls = XCTAttachment(screenshot: app.screenshot())
        controls.name = "Playback controls"
        controls.lifetime = .keepAlways
        add(controls)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(app.buttons["Timeline"].hasFocus)
        remote.press(.select)
        remote.press(.left)
        XCTAssertTrue(app.buttons["Play here"].hasFocus)
        remote.press(.select)
        XCTAssertTrue(pause.waitForExistence(timeout: 3), "Play here resumes a paused viewer at the selected position.")
        remote.press(.playPause)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        remote.press(.playPause)
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        remote.press(.menu)
        remote.press(.down)
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        remote.press(.menu)
        remote.press(.menu)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForFocus(pause), "Wait for the fullscreen presentation to accept remote commands.")
        remote.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5), "Suspension ends playback and returns to the library.")
        XCTAssertFalse(app.buttons["Show playback controls"].exists)
    }
}

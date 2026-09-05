import AppKit
import SwiftData
import SwiftUI

@main
@MainActor
struct ChannelDeckApp: App {
    private let modelContainer: ModelContainer
    @State private var appModel: AppModel
    @AppStorage("channelDeck.appearance") private var appearance: DeckAppearance = .system

    init() {
        do {
            let container = try ChannelDeckSchema.makeContainer()
            modelContainer = container
            _appModel = State(initialValue: AppModel(modelContainer: container))
        } catch {
            fatalError("ChannelDeck could not create its local library: \(error.localizedDescription)")
        }

        if let applicationIcon = ChannelDeckBrand.applicationIcon {
            NSApplication.shared.applicationIconImage = applicationIcon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1380, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            ChannelDeckCommands(appModel: appModel)
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(modelContainer)
    }
}

private struct ChannelDeckCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About ChannelDeck") {
                ChannelDeckBrand.showAboutPanel()
            }
        }

        CommandGroup(after: .newItem) {
            Button("Add Playlist…") {
                appModel.beginAddingSource()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Refresh Playlist") {
                Task { await appModel.refreshSelection(force: true) }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(appModel.sourceID(for: appModel.sidebarSelection) == nil)
        }

        CommandMenu("Library") {
            Button("Favorites") { appModel.searchText = ""; appModel.sidebarSelection = .favorites }
                .keyboardShortcut("1", modifiers: .command)
            Button("TV Guide") { appModel.searchText = ""; appModel.sidebarSelection = .guide }
                .keyboardShortcut("2", modifiers: .command)
            Button("Recordings") { appModel.searchText = ""; appModel.sidebarSelection = .recordings }
                .keyboardShortcut("3", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button("Play or Pause") {
                appModel.playerController.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(appModel.selectedChannel == nil && appModel.selectedRecording == nil)

            Button("Try Channel Again") {
                appModel.retryPlayback()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(appModel.selectedChannel == nil && appModel.selectedRecording == nil)

            Divider()

            Button(appModel.bufferRecordingPhase.isEnabled ? "Stop Recording" : "Record") {
                appModel.setSaveBufferEnabled(!appModel.bufferRecordingPhase.isEnabled)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(appModel.bufferRecordingPhase.isBusy
                || (!appModel.playerController.liveDVRState.isAvailable && !appModel.bufferRecordingPhase.isEnabled))

            Button("Stop") {
                appModel.stopPlayback()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(appModel.selectedChannel == nil && appModel.selectedRecording == nil)
        }
    }
}

@MainActor
private enum ChannelDeckBrand {
    static let repositoryURL = URL(string: "https://github.com/cevatkerim/ChannelDeck")!

    static var applicationIcon: NSImage? {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        return NSImage(named: "ChannelDeckMark")
    }

    static func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Native IPTV playback, live buffering, recording, and secure AirPlay.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        credits.append(
            NSAttributedString(
                string: "View ChannelDeck on GitHub",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.linkColor,
                    .link: repositoryURL,
                    .paragraphStyle: paragraph,
                ]
            )
        )

        if let noticesURL = Bundle.main.resourceURL?.appendingPathComponent("ThirdPartyNotices"),
           FileManager.default.fileExists(atPath: noticesURL.path) {
            credits.append(NSAttributedString(
                string: "\nIncludes FFmpeg under the GNU LGPL.\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            credits.append(NSAttributedString(
                string: "Third-party licenses and source information",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.linkColor,
                    .link: noticesURL,
                    .paragraphStyle: paragraph,
                ]
            ))
        }

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ChannelDeck",
            .credits: credits,
        ]
        if let applicationIcon {
            options[.applicationIcon] = applicationIcon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

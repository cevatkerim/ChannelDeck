import SwiftData
import SwiftUI

@main
@MainActor
struct ChannelDeckApp: App {
    private let modelContainer: ModelContainer
    @State private var appModel: AppModel

    init() {
        do {
            let container = try ChannelDeckSchema.makeContainer()
            modelContainer = container
            _appModel = State(initialValue: AppModel(modelContainer: container))
        } catch {
            fatalError("ChannelDeck could not create its local library: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1280, height: 780)
        .commands {
            ChannelDeckCommands(appModel: appModel)
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
        .modelContainer(modelContainer)
    }
}

private struct ChannelDeckCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
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

        CommandMenu("Playback") {
            Button("Play or Pause") {
                appModel.playerController.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(appModel.selectedChannel == nil && appModel.selectedRecording == nil)

            Button("Try Channel Again") {
                appModel.playerController.retry()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(appModel.selectedChannel == nil && appModel.selectedRecording == nil)

            Divider()

            Button("Stop") {
                appModel.playerController.stop()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(appModel.selectedChannel == nil && appModel.selectedRecording == nil)
        }
    }
}

import SwiftUI

@main
struct ChannelDeckTVApp: App {
    @State private var library = TVLibrary()
    init() {
        // A terminated/suspended process may leave its temporary session on disk.
        // Every new launch starts with no live history.
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "ChannelDeckTV/Live"))
    }
    var body: some Scene {
        WindowGroup {
            TVRootView(library: library)
                .preferredColorScheme(.dark)
                .tint(TVTheme.mint)
        }
    }
}

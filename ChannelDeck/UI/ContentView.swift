import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } content: {
            ChannelBrowserView()
        } detail: {
            PlayerDetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: ChannelDeckStyle.windowMinimumSize.width,
            minHeight: ChannelDeckStyle.windowMinimumSize.height
        )
        .sheet(isPresented: $appModel.isPresentingSourceEditor) {
            SourceEditorView()
        }
        .alert(item: $appModel.presentedAlert) { alert in
            if let sourceID = alert.sourceID {
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .destructive(Text("Remove")) {
                        Task { await appModel.removeSource(id: sourceID) }
                    },
                    secondaryButton: .cancel()
                )
            } else {
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
        .task {
            await appModel.bootstrap()
        }
    }
}

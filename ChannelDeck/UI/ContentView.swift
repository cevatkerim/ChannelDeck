import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var appModel = appModel

        ZStack {
            Group {
                if appModel.sidebarSelection == .guide {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        SidebarView()
                    } detail: {
                        ProgrammeGuideView()
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        SidebarView()
                    } content: {
                        ChannelBrowserView()
                    } detail: {
                        PlayerDetailView()
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
            .tint(ChannelDeckStyle.accent)
            .opacity(appModel.isBootstrapping ? 0 : 1)
            .accessibilityHidden(appModel.isBootstrapping)

            if appModel.isBootstrapping {
                LaunchScreenView()
                    .zIndex(1)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.22),
            value: appModel.isBootstrapping
        )
        .toolbarVisibility(
            appModel.isBootstrapping ? .hidden : .visible,
            for: .windowToolbar
        )
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
            } else if let recordingID = alert.recordingID {
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .destructive(Text("Delete")) {
                        appModel.removeRecording(id: recordingID)
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

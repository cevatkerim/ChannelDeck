import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var appModel = appModel

        ZStack {
            if !appModel.isBootstrapping {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } detail: {
                    PlayerWorkspace(isShowingGuide: appModel.sidebarSelection == .guide) {
                        HSplitView {
                            ChannelBrowserView()
                                .frame(minWidth: 290, idealWidth: 340, maxWidth: 440)
                            PlayerDetailView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } guide: {
                        ProgrammeGuideView()
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .tint(ChannelDeckStyle.accent)
            }

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

/// The guide covers the workspace without dismantling its AVPlayerView. A new
/// rendering surface attached to an already-playing live item can remain black
/// until the next seek. Keeping the surface mounted also preserves paused frames,
/// the live buffer, and the split/sidebar state; navigation never touches playback.
struct PlayerWorkspace<PlayerContent: View, GuideContent: View>: View {
    let isShowingGuide: Bool
    @ViewBuilder var player: () -> PlayerContent
    @ViewBuilder var guide: () -> GuideContent

    var body: some View {
        ZStack {
            player()
                // Occlude rather than hide the native surface. AVKit can treat
                // a hidden rendering view differently from a covered one.
                .allowsHitTesting(!isShowingGuide)
                .disabled(isShowingGuide)
                .accessibilityHidden(isShowingGuide)

            if isShowingGuide {
                guide()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ChannelDeckStyle.canvas)
            }
        }
    }
}

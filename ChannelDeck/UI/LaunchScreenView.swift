import SwiftUI

struct LaunchScreenView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ChannelDeckStyle.canvas
            VStack(spacing: 24) {
                DeckMark(size: 88)
                VStack(spacing: 9) {
                    Text("ChannelDeck")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .tracking(-0.8)
                        .foregroundStyle(ChannelDeckStyle.ink)
                    Text("A little closer to live.")
                        .font(.system(size: 13))
                        .foregroundStyle(ChannelDeckStyle.muted)
                }
                HStack(spacing: 9) {
                    ProgressView().controlSize(.mini)
                    Text(appModel.launchStatus)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(ChannelDeckStyle.muted)
                }
                .padding(.top, 15)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ChannelDeck. \(appModel.launchStatus)")
        .transition(reduceMotion ? .identity : .opacity)
    }
}

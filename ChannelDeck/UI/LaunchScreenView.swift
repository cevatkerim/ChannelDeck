import SwiftUI

struct LaunchScreenView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 360, height: 360)
                .blur(radius: 70)

            VStack(spacing: 18) {
                Image("ChannelDeckMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("ChannelDeck")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("Preparing your channels…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ChannelDeck is preparing your channels")
        .transition(reduceMotion ? .identity : .opacity)
    }
}

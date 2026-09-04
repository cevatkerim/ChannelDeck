import SwiftUI

struct ChannelLogoView: View {
    let channel: ChannelRecord
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url = channel.logoURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(5)
                    case .failure:
                        fallback
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Text(channel.name.prefix(2).uppercased())
            .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
    }
}

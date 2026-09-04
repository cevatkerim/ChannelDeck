import SwiftUI

enum ChannelDeckStyle {
    static let cornerRadius: CGFloat = 14
    static let compactCornerRadius: CGFloat = 9
    static let playerAspectRatio: CGFloat = 16 / 9
    static let sidebarMinimumWidth: CGFloat = 190
    static let browserMinimumWidth: CGFloat = 310
    static let windowMinimumSize = CGSize(width: 920, height: 620)
}
extension View {
    func channelDeckPanel() -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }
    }
}

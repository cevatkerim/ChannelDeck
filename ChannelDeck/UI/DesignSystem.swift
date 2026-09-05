import AppKit
import SwiftUI

/// Shared semantic surfaces keep the library, player, and settings in the same visual family.
enum ChannelDeckStyle {
    static let cornerRadius: CGFloat = 20
    static let compactCornerRadius: CGFloat = 12
    static let playerAspectRatio: CGFloat = 16 / 9
    static let sidebarMinimumWidth: CGFloat = 200
    static let browserMinimumWidth: CGFloat = 290
    static let windowMinimumSize = CGSize(width: 1020, height: 660)

    static let accent = adaptive(light: 0x16745F, dark: 0x83D9BC)
    static let accentSoft = adaptive(light: 0xE3F3EC, dark: 0x213C34)
    static let canvas = adaptive(light: 0xFAFBF9, dark: 0x171B19)
    static let sidebar = adaptive(light: 0xF3F5F1, dark: 0x1C211E)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x242A26)
    static let inset = adaptive(light: 0xF2F5F1, dark: 0x1B211D)
    static let ink = adaptive(light: 0x22352D, dark: 0xE8F0EA)
    static let muted = adaptive(light: 0x65736B, dark: 0xA4B3A9)
    static let line = adaptive(light: 0xE2E8E1, dark: 0x364039)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: Double((hex >> 16) & 0xFF) / 255,
                    green: Double((hex >> 8) & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255, alpha: 1)
            })
    }
}

extension View {
    func channelDeckPanel() -> some View {
        background(ChannelDeckStyle.surface, in: RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ChannelDeckStyle.cornerRadius)
                    .strokeBorder(ChannelDeckStyle.line, lineWidth: 1)
            }
    }

    func deckEyebrow() -> some View {
        font(.system(size: 10, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(ChannelDeckStyle.muted)
    }
}

struct DeckMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image("ChannelDeckSymbol")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(ChannelDeckStyle.accent)
            .background(ChannelDeckStyle.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.27))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct DeckButtonStyle: ButtonStyle {
    var prominent = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15)
            .frame(minHeight: 36)
            .foregroundStyle(prominent ? Color.white : ChannelDeckStyle.ink)
            .background(
                prominent ? Color(red: 0.075, green: 0.40, blue: 0.32) : ChannelDeckStyle.inset,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : (isHovered ? 0.88 : 1)) : 0.4)
            .onHover { isHovered = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct DeckIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .background(
                configuration.isPressed ? ChannelDeckStyle.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct DeckEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(ChannelDeckStyle.accent)
                .frame(width: 64, height: 64)
                .background(ChannelDeckStyle.accentSoft, in: RoundedRectangle(cornerRadius: 21))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ChannelDeckStyle.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ChannelDeckStyle.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 340)
    }
}

enum DeckAppearance: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}


enum DeckDensity: String, CaseIterable {
    case compact = "Compact"
    case comfortable = "Comfortable"

    var titleSize: CGFloat { self == .comfortable ? 14 : 12 }
    var subtitleSize: CGFloat { self == .comfortable ? 12 : 11 }
    var rowPadding: CGFloat { self == .comfortable ? 15 : 9 }
    var logoSize: CGFloat { self == .comfortable ? 46 : 36 }
    var readingSize: CGFloat { self == .comfortable ? 14 : 12 }
}

import SwiftUI
import UIKit

/// Shared paper and ink tones. Photo overlays and semantic status colours stay separate.
enum DaymarkPalette {
    static let accent = Color("AccentColor")
    static let paper = Color(uiColor: paperUIColor)
    static let surface = adaptive(light: 0xFFFDF7, dark: 0x202B23)
    static let recessed = adaptive(light: 0xEEEEE4, dark: 0x18221C)
    static let ink = Color(uiColor: inkUIColor)
    static let secondaryInk = adaptive(light: 0x646E61, dark: 0xA9B6A7)
    static let rule = adaptive(light: 0xDCDDD0, dark: 0x3C4B40)
    static let shadow = Color.black.opacity(0.035)
    // A light photo mount remains visible over both maps and photographs in either theme.
    static let photoMount = Color(red: 0.99, green: 0.98, blue: 0.95)

    static let paperUIColor = adaptiveUIColor(light: 0xF9F5ED, dark: 0x171F1A)
    static let inkUIColor = adaptiveUIColor(light: 0x28372D, dark: 0xF2F0E7)
    static let buttonFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.68, green: 0.79, blue: 0.70, alpha: 1)
            : UIColor(red: 0.16, green: 0.31, blue: 0.24, alpha: 1)
    })
    static let buttonText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.15, blue: 0.11, alpha: 1)
            : UIColor(red: 0.99, green: 0.98, blue: 0.94, alpha: 1)
    })

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: adaptiveUIColor(light: light, dark: dark))
    }

    private static func adaptiveUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// Serif type marks dates and chapter headings; controls and body copy use system type.
enum DaymarkTypography {
    static let pageTitle = Font.system(.largeTitle, design: .serif, weight: .medium)
    static let sectionTitle = Font.system(.title3, design: .serif, weight: .medium)
    static let entryTitle = Font.system(.headline, design: .serif, weight: .medium)
    static let body = Font.body
    static let metadata = Font.caption
    static let timelineDay = Font.system(.title2, design: .serif, weight: .medium)
    static let timelineMonth = Font.caption.weight(.medium)
    static let timelineYear = Font.caption2
}

extension View {
    func daymarkNavigationTitle(_ title: String, inline: Bool = false) -> some View {
        self
            .navigationTitle(title)
            .toolbar {
                if inline {
                    ToolbarItem(placement: .title) {
                        Text(title)
                            .font(.system(.headline, design: .serif, weight: .medium))
                            .foregroundStyle(DaymarkPalette.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                } else {
                    ToolbarItem(placement: .largeTitle) {
                        Text(title)
                            .font(DaymarkTypography.pageTitle)
                            .foregroundStyle(DaymarkPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
    }

    func daymarkScreen() -> some View {
        self
            .foregroundStyle(DaymarkPalette.ink)
            .tint(DaymarkPalette.accent)
            .background(DaymarkPalette.paper)
            .toolbarBackground(DaymarkPalette.paper, for: .navigationBar)
    }

    func daymarkSurface(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(DaymarkPalette.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DaymarkPalette.rule, lineWidth: 0.75)
            }
            .shadow(color: DaymarkPalette.shadow, radius: 3, x: 0, y: 2)
    }
}

struct DaymarkPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.medium)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(DaymarkPalette.buttonText)
            .background(DaymarkPalette.buttonFill, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct DaymarkSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.medium)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(DaymarkPalette.accent)
            .background(DaymarkPalette.accent.opacity(configuration.isPressed ? 0.18 : 0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(DaymarkPalette.accent.opacity(0.22), lineWidth: 0.75))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

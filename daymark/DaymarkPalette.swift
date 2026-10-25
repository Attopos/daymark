import SwiftUI
import UIKit

/// The six named swatches of the Daymark palette (MP088). Use the semantic
/// tokens in `DaymarkPalette` for UI; reach for a swatch only when a view needs
/// one exact palette colour, such as a gradient or a decorative surface.
enum DaymarkSwatch {
    static let heiSeBlack = hex(0x142030)
    static let siestaTan = hex(0xE9D8C8)
    static let picoEggplant = hex(0x732553)
    static let stellarStrawberry = hex(0xFF5C8D)
    static let blueWhale = hex(0x1E3442)
    static let grauzone = hex(0x85A3B2)

    static func hex(_ rgb: UInt32) -> Color {
        Color(uiColor: DaymarkPalette.uiColor(rgb))
    }
}

/// Shared paper and ink tones built from `DaymarkSwatch`. Light mode is warm
/// Siesta Tan paper with Hēi Sè ink and an eggplant accent; dark mode is Hēi Sè
/// paper with Blue Whale surfaces and a strawberry accent. Photo overlays and
/// semantic status colours stay separate.
enum DaymarkPalette {
    static let accent = Color("AccentColor")
    /// A second, louder accent for highlights such as today or a completed month.
    static let highlight = DaymarkSwatch.stellarStrawberry
    static let paper = Color(uiColor: paperUIColor)
    static let surface = adaptive(light: 0xFBF6F0, dark: 0x1E3442)
    static let recessed = adaptive(light: 0xE9D8C8, dark: 0x192A39)
    static let ink = Color(uiColor: inkUIColor)
    static let secondaryInk = adaptive(light: 0x4E6474, dark: 0x85A3B2)
    static let rule = adaptive(light: 0xDCCAB9, dark: 0x2E4757)
    static let shadow = DaymarkSwatch.heiSeBlack.opacity(0.06)
    // A light photo mount remains visible over both maps and photographs in either theme.
    static let photoMount = DaymarkSwatch.hex(0xFBF6F0)

    static let paperUIColor = adaptiveUIColor(light: 0xF3E9DF, dark: 0x142030)
    static let inkUIColor = adaptiveUIColor(light: 0x142030, dark: 0xE9D8C8)
    static let buttonFill = adaptive(light: 0x732553, dark: 0xFF5C8D)
    static let buttonText = adaptive(light: 0xF3E9DF, dark: 0x142030)

    /// The palette's signature bloom: strawberry fading through eggplant into Blue Whale.
    static var bloom: LinearGradient {
        LinearGradient(
            colors: [DaymarkSwatch.stellarStrawberry, DaymarkSwatch.picoEggplant, DaymarkSwatch.blueWhale],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: adaptiveUIColor(light: light, dark: dark))
    }

    private static func adaptiveUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    fileprivate static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
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

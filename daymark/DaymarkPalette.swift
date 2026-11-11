import SwiftUI
import UIKit

/// Daymark's look is quiet and editorial: paper, ink and serif dates, so the
/// photographs are the only colour on screen. One accent, the *mark*, appears
/// only where a day is marked or is today.
enum DaymarkSwatch {
    /// Used for shadows and shading on the desk calendar, the one tactile object.
    static let heiSeBlack = hex(0x000000)
    /// The mark colour in light mode.
    static let picoEggplant = hex(0x732553)

    static func hex(_ rgb: UInt32) -> Color {
        Color(uiColor: DaymarkPalette.uiColor(rgb))
    }
}

/// Semantic colours. Light mode is ink on warm white paper; dark mode is the
/// reverse. Controls are ink-coloured; `mark` is the only hue. Semantic status
/// colours (errors, sync state) stay separate.
enum DaymarkPalette {
    /// Tint for controls: ink in both themes (the asset mirrors `ink`).
    static let accent = Color("AccentColor")
    /// The single accent: today, the selected day and the stroke on marked days.
    static let mark = adaptive(light: 0x732553, dark: 0xD68FB8)
    static let highlight = mark
    static let paper = Color(uiColor: paperUIColor)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C1C1B)
    static let recessed = adaptive(light: 0xEFECE6, dark: 0x262625)
    static let ink = Color(uiColor: inkUIColor)
    static let secondaryInk = adaptive(light: 0x6F6B65, dark: 0x9E9991)
    static let rule = adaptive(light: 0xE1DDD5, dark: 0x30302E)
    static let shadow = DaymarkSwatch.heiSeBlack.opacity(0.06)
    // A white photo mount remains visible over both maps and photographs in either theme.
    static let photoMount = DaymarkSwatch.hex(0xFFFFFF)
    /// The back board of the desk calendar.
    static let stand = adaptive(light: 0x2B2A28, dark: 0x3B3A37)
    /// Brushed metal for the desk calendar's rings.
    static let metal = adaptive(light: 0x9A9A98, dark: 0x8A8A88)
    static let metalHighlight = adaptive(light: 0xF2F2F0, dark: 0xD8D8D6)

    static let paperUIColor = adaptiveUIColor(light: 0xFAF8F4, dark: 0x111110)
    static let inkUIColor = adaptiveUIColor(light: 0x161514, dark: 0xF2EFE9)
    static let buttonFill = ink
    static let buttonText = paper

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
    static let pageTitle = Font.system(.largeTitle, design: .serif, weight: .regular)
    static let sectionTitle = Font.system(.title3, design: .serif, weight: .regular)
    static let entryTitle = Font.system(.headline, design: .serif, weight: .medium)
    static let body = Font.body
    static let metadata = Font.caption
    static let timelineDay = Font.system(.title2, design: .serif, weight: .medium)
    static let timelineMonth = Font.caption.weight(.medium)
    static let timelineYear = Font.caption2
}

/// Corner radii. Photographs stay close to square; only panels are rounded.
enum DaymarkRadius {
    /// Photo tiles in the calendar and search grids.
    static let tile: CGFloat = 4
    /// Badges, inline thumbnails and the photo on a calendar page.
    static let small: CGFloat = 6
    /// Cards and the photo on the detail page.
    static let card: CGFloat = 14
    /// Sheets and other full-width surfaces.
    static let panel: CGFloat = 24

    /// A tile radius that stays in proportion when the grid is pinched to more columns.
    static func tile(for size: CGFloat) -> CGFloat {
        min(tile, max(2, size * 0.04))
    }
}

/// A 4-point spacing scale for padding and stack spacing.
enum DaymarkSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Shared motion curves so every transition and press settles the same way.
enum DaymarkMotion {
    /// Taps and toggles.
    static let snappy = Animation.snappy(duration: 0.24)
    /// Layout changes such as switching grids or showing a panel.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// Presses on buttons and cards.
    static let press = Animation.spring(response: 0.26, dampingFraction: 0.68)
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

    /// Paper, ink and control tint for a whole screen. The navigation bar stays
    /// transparent so iOS draws its own scroll-edge glass.
    func daymarkScreen() -> some View {
        self
            .foregroundStyle(DaymarkPalette.ink)
            .tint(DaymarkPalette.accent)
            .background { DaymarkPalette.paper.ignoresSafeArea() }
    }

    /// A flat card: surface fill and a hairline rule, no shadow.
    func daymarkSurface(cornerRadius: CGFloat = DaymarkRadius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(DaymarkPalette.surface, in: shape)
            .overlay { shape.strokeBorder(DaymarkPalette.rule, lineWidth: 0.75) }
    }

    /// Glass for the few controls that float over a map. Everything else is
    /// paper; the system supplies the glass for tab and navigation bars.
    func daymarkFloatingGlass<S: Shape>(in shape: S) -> some View {
        // Never interactive glass: inside a button label it swallows the tap.
        glassEffect(.regular, in: shape)
    }
}

/// A hairline that separates a tile or photograph from the paper around it.
struct DaymarkHairline: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(DaymarkPalette.ink.opacity(0.08), lineWidth: 0.5)
            .allowsHitTesting(false)
    }
}

/// The mark: a short diagonal stroke through a day, as if struck off with a pen.
/// It is Daymark's one recurring motif and always drawn in the mark colour
/// unless it sits on that colour.
struct DaymarkStroke: View {
    var length: CGFloat = 24
    var thickness: CGFloat = 2.5
    var color: Color = DaymarkPalette.mark

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: length, height: thickness)
            .rotationEffect(.degrees(-18))
            .accessibilityHidden(true)
    }
}

/// A plain ink symbol that leads a settings row.
struct DaymarkIconBadge: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(DaymarkPalette.ink)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

/// Gives cards, tiles and links a small spring when pressed.
struct DaymarkPressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
    }
}

/// Full-width actions at the bottom of a sheet or page: solid ink for the main
/// action, a hairline outline for the rest. `color` is for destructive actions.
struct DaymarkBlockButtonStyle: ButtonStyle {
    var prominent = false
    var color: Color = DaymarkPalette.ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DaymarkSpacing.m)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? DaymarkPalette.paper : color)
            .background {
                if prominent {
                    Capsule().fill(color)
                } else {
                    Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(DaymarkPalette.buttonText)
            .background(DaymarkPalette.buttonFill, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(DaymarkPalette.ink)
            .background(Capsule().strokeBorder(DaymarkPalette.ink.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
    }
}

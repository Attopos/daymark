import SwiftUI
import UIKit

/// Daymark looks like an e-ink page set the way Medium sets type: black, white
/// and grey only, crisp one-point lines, no shadows, gradients or translucency.
/// The photographs are the only colour on screen.
enum DaymarkSwatch {
    /// Shading for a desk-calendar leaf while it turns.
    static let heiSeBlack = hex(0x000000)

    static func hex(_ rgb: UInt32) -> Color {
        Color(uiColor: DaymarkPalette.uiColor(rgb))
    }
}

/// Semantic colours. Light mode is black ink on the pale grey of an e-ink
/// panel; dark mode is the inverted panel. There is no hue: `mark` is ink.
/// Semantic status colours (errors, sync state) stay separate.
enum DaymarkPalette {
    /// Tint for controls: ink in both themes (the asset mirrors `ink`).
    static let accent = Color("AccentColor")
    /// Today, the selected day, the stroke on marked days and the postmark: solid ink.
    static let mark = ink
    static let highlight = mark
    static let paper = Color(uiColor: paperUIColor)
    static let surface = paper
    static let recessed = adaptive(light: 0xDFDEDA, dark: 0x242424)
    static let ink = Color(uiColor: inkUIColor)
    static let secondaryInk = adaptive(light: 0x6B6B6B, dark: 0x9A9A9A)
    /// Dividers between rows, in the light grey of Medium's list rules.
    static let rule = adaptive(light: 0xCFCEC9, dark: 0x3A3A3A)
    // A white photo mount remains visible over both maps and photographs in either theme.
    static let photoMount = DaymarkSwatch.hex(0xFFFFFF)
    /// The back board of the desk calendar.
    static let stand = adaptive(light: 0x1A1A1A, dark: 0x4A4A4A)
    /// The desk calendar's rings: flat grey wire.
    static let metal = adaptive(light: 0x6B6B6B, dark: 0x9A9A9A)

    static let paperUIColor = adaptiveUIColor(light: 0xF1F0EC, dark: 0x0C0C0C)
    static let inkUIColor = adaptiveUIColor(light: 0x121212, dark: 0xE4E3DF)
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

/// Type set the way Medium sets it: tight bold sans-serif headings, a serif
/// reading face (Charter) for anything you read rather than tap, and small
/// grey sans-serif metadata. Dates keep a serif display face.
enum DaymarkTypography {
    static let pageTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let sectionTitle = Font.system(.title3, design: .default, weight: .bold)
    static let entryTitle = Font.system(.headline, design: .default, weight: .semibold)
    /// The reading face for captions, places and explanatory copy.
    static let reading = Font.custom("Charter", size: 18, relativeTo: .body)
    static let readingSmall = Font.custom("Charter", size: 15, relativeTo: .subheadline)
    static let body = reading
    static let metadata = Font.footnote
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
    /// Outlined panels.
    static let card: CGFloat = 8
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
                            .font(.system(.headline, design: .default, weight: .bold))
                            .foregroundStyle(DaymarkPalette.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                } else {
                    ToolbarItem(placement: .largeTitle) {
                        Text(title)
                            .font(DaymarkTypography.pageTitle)
                            .tracking(-0.6)
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

    /// A list row in the Medium manner: no box, just a rule underneath.
    func daymarkSurface(cornerRadius: CGFloat = DaymarkRadius.card) -> some View {
        self
            .overlay(alignment: .bottom) {
                Rectangle().fill(DaymarkPalette.rule).frame(height: 1)
            }
    }

    /// A control floating over a map: opaque paper with a one-point ink
    /// outline, like a button on an e-ink reader. No glass or shadow.
    func daymarkFloatingGlass<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(DaymarkPalette.paper, in: shape)
            .overlay { shape.strokeBorder(DaymarkPalette.ink, lineWidth: 1) }
    }
}

/// A hairline that separates a tile or photograph from the paper around it.
struct DaymarkHairline: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(DaymarkPalette.ink.opacity(0.18), lineWidth: 0.5)
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
                    Capsule().strokeBorder(color, lineWidth: 1)
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
            .background(Capsule().strokeBorder(DaymarkPalette.ink, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
    }
}

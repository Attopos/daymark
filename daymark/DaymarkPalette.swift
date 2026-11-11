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


/// Corner radii, from the smallest grid tile up to full-width panels. Every
/// rounded shape in the app uses one of these with the continuous corner style.
enum DaymarkRadius {
    /// Badges and small inline thumbnails.
    static let small: CGFloat = 10
    /// Photo tiles in the calendar and search grids (scaled down for dense grids).
    static let tile: CGFloat = 14
    /// Cards, list panels and the photo on the detail page.
    static let card: CGFloat = 24
    /// Sheets and other full-width surfaces.
    static let panel: CGFloat = 32

    /// A tile radius that stays in proportion when the grid is pinched to more columns.
    static func tile(for size: CGFloat) -> CGFloat {
        min(tile, max(6, size * 0.11))
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

    /// Paper, ink and accent for a whole screen. With `backdrop`, the screen
    /// sits on the palette's soft glow so frosted surfaces above it pick up colour.
    /// The navigation bar stays transparent so iOS draws its own scroll-edge glass.
    func daymarkScreen(backdrop: Bool = false) -> some View {
        self
            .foregroundStyle(DaymarkPalette.ink)
            .tint(DaymarkPalette.accent)
            .background {
                if backdrop {
                    DaymarkBackdrop()
                } else {
                    DaymarkPalette.paper.ignoresSafeArea()
                }
            }
    }

    /// A frosted card: material tinted with the palette surface, a light rim
    /// along the top edge and a soft, low shadow.
    func daymarkSurface(cornerRadius: CGFloat = DaymarkRadius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape.fill(.regularMaterial)
                shape.fill(DaymarkPalette.surface.opacity(0.5))
            }
            .overlay { DaymarkGlassRim(cornerRadius: cornerRadius) }
            .shadow(color: DaymarkSwatch.heiSeBlack.opacity(0.08), radius: 14, x: 0, y: 6)
    }

    /// Liquid Glass for controls that float over content, such as map buttons
    /// and counters. Content itself uses `daymarkSurface` instead.
    func daymarkFloatingGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}

/// The light catching a pane's top-leading edge and fading out, so a surface
/// reads as a thick sheet of frosted glass.
struct DaymarkGlassRim: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.6), .white.opacity(0.06), .white.opacity(0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
            .allowsHitTesting(false)
    }
}

/// Paper with soft strawberry, eggplant and Grauzone glows. It stays fixed
/// while content scrolls, so each frosted pane above it picks up a different tint.
struct DaymarkBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let strength = colorScheme == .dark ? 0.75 : 1.0
            ZStack {
                DaymarkPalette.paper

                RadialGradient(
                    colors: [DaymarkSwatch.stellarStrawberry.opacity(0.4 * strength), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: geometry.size.height * 0.6
                )
                RadialGradient(
                    colors: [DaymarkSwatch.picoEggplant.opacity(0.35 * strength), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: geometry.size.height * 0.65
                )
                RadialGradient(
                    colors: [DaymarkSwatch.grauzone.opacity(0.3 * strength), .clear],
                    center: UnitPoint(x: 0.2, y: 0.35),
                    startRadius: 0,
                    endRadius: geometry.size.width * 0.7
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A rounded-square symbol tile in the accent colour, used to lead settings rows.
struct DaymarkIconBadge: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(DaymarkPalette.buttonText)
            .frame(width: 36, height: 36)
            .background(
                DaymarkPalette.buttonFill.gradient,
                in: RoundedRectangle(cornerRadius: DaymarkRadius.small, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Section heading that floats as a small glass capsule when pinned over a grid.
struct DaymarkSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DaymarkTypography.sectionTitle)
            .foregroundStyle(DaymarkPalette.ink)
            .padding(.horizontal, DaymarkSpacing.s)
            .padding(.vertical, 6)
            .daymarkFloatingGlass(in: Capsule(), interactive: false)
            .padding(.vertical, DaymarkSpacing.xs)
            .accessibilityAddTraits(.isHeader)
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

struct DaymarkPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(DaymarkPalette.buttonText)
            .background(DaymarkPalette.buttonFill.gradient, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
    }
}

struct DaymarkSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(DaymarkPalette.accent)
            .background(DaymarkPalette.accent.opacity(configuration.isPressed ? 0.18 : 0.1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(DaymarkMotion.press, value: configuration.isPressed)
    }
}

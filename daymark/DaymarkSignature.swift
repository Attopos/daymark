import SwiftUI

// Daymark's signature elements. They add character without adding colour:
// everything here is ink or the mark colour.
//
// - `DaymarkPostmark`: the place-and-date stamp each day receives.
// - `DaymarkBeacon`: the dayboard shapes of a nautical daymark.
// - `DaymarkMonthHeader`: the oversized month numeral that opens each month.

// MARK: - Postmark

/// A round postmark for one day: the place around the rim, the date in the
/// middle. It makes "One day. One place." a visible ritual.
struct DaymarkPostmark: View {
    let date: Date
    /// Upper rim, usually the city. Falls back to "DAYMARK".
    var place: String?
    /// Lower rim, usually the country.
    var region: String?
    var diameter: CGFloat = 84
    var color: Color = DaymarkPalette.mark

    private var rimFont: CGFloat { diameter * 0.105 }
    private var textRadius: CGFloat { diameter * 0.385 }

    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: max(1, diameter * 0.022))
            Circle().strokeBorder(color, lineWidth: max(0.5, diameter * 0.009))
                .padding(diameter * 0.2)

            ArcText(text: Self.rimText(place) ?? "DAYMARK", radius: textRadius, fontSize: rimFont, onTop: true)
            if let region = Self.rimText(region) {
                ArcText(text: region, radius: textRadius, fontSize: rimFont, onTop: false)
            } else {
                // Two dots keep the lower rim from looking unfinished.
                ArcText(text: "· ·", radius: textRadius, fontSize: rimFont, onTop: false)
            }

            VStack(spacing: -diameter * 0.02) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: diameter * 0.27, weight: .semibold, design: .serif))
                Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.system(size: diameter * 0.095, weight: .semibold))
                    .tracking(diameter * 0.012)
                Text(date.formatted(.dateTime.year()))
                    .font(.system(size: diameter * 0.085, weight: .medium))
            }
            .monospacedDigit()
        }
        .foregroundStyle(color)
        .frame(width: diameter, height: diameter)
        .opacity(0.88)
        .rotationEffect(.degrees(-11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        ([place, region].compactMap { $0 } + [date.formatted(.dateTime.month(.wide).day().year())])
            .joined(separator: ", ")
    }

    /// Uppercased and shortened so the rim never wraps past the sides.
    private static func rimText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let upper = trimmed.uppercased()
        return upper.count > 16 ? String(upper.prefix(15)) + "…" : upper
    }
}

/// Sets text along the inside of a circle, upright at the top or the bottom.
private struct ArcText: View {
    let text: String
    let radius: CGFloat
    let fontSize: CGFloat
    let onTop: Bool

    var body: some View {
        let characters = Array(text)
        let widths = characters.map { Self.advance(of: $0) * fontSize }
        // Never let the text run past 150 degrees of the rim.
        let natural = widths.reduce(0, +) / radius
        let squeeze = min(1, (150 * .pi / 180) / max(natural, 0.001))
        var angles: [Double] = []
        var cursor = -natural * squeeze / 2
        for width in widths {
            let step = Double(width / radius) * squeeze
            angles.append(cursor + step / 2)
            cursor += step
        }

        return ZStack {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(size: fontSize * (squeeze < 0.8 ? 0.85 : 1), weight: .semibold))
                    .offset(y: onTop ? -radius : radius)
                    .rotationEffect(.radians(onTop ? angles[index] : -angles[index]))
            }
        }
        .accessibilityHidden(true)
    }

    /// Rough advance widths in ems; wide for CJK, narrow for spaces and dots.
    private static func advance(of character: Character) -> CGFloat {
        if character == " " { return 0.4 }
        if character == "·" || character == "." || character == "I" { return 0.45 }
        if character == "M" || character == "W" { return 0.95 }
        return character.isASCII ? 0.74 : 1.08
    }
}

// MARK: - Beacons

/// The dayboards of a nautical daymark: the shapes sailors read by daylight to
/// know where they are. Used for today, map pins, ornaments and empty states.
enum DaymarkBeacon: CaseIterable {
    case triangle, diamond, square

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch self {
        case .triangle:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        case .square:
            path.addRect(rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08))
        }
        path.closeSubpath()
        return path
    }
}

struct DaymarkBeaconShape: Shape {
    let beacon: DaymarkBeacon

    func path(in rect: CGRect) -> Path {
        beacon.path(in: rect)
    }
}

/// One beacon, filled or outlined.
struct DaymarkBeaconMark: View {
    var beacon: DaymarkBeacon = .diamond
    var size: CGFloat = 8
    var filled = true
    var color: Color = DaymarkPalette.mark

    var body: some View {
        Group {
            if filled {
                DaymarkBeaconShape(beacon: beacon).fill(color)
            } else {
                DaymarkBeaconShape(beacon: beacon)
                    .stroke(color, style: StrokeStyle(lineWidth: max(1, size * 0.09), lineJoin: .miter))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Triangle, diamond, square in a row: ink outlines with the diamond in the
/// mark colour. Daymark's ornament for empty and welcome screens.
struct DaymarkBeaconRow: View {
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: size * 0.7) {
            DaymarkBeaconMark(beacon: .triangle, size: size, filled: false, color: DaymarkPalette.ink)
            DaymarkBeaconMark(beacon: .diamond, size: size * 1.1)
            DaymarkBeaconMark(beacon: .square, size: size, filled: false, color: DaymarkPalette.ink)
        }
        .accessibilityHidden(true)
    }
}

/// An empty screen in Daymark's own voice: beacons, a serif title, one line.
struct DaymarkEmptyState: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: DaymarkSpacing.m) {
            DaymarkBeaconRow(size: 18)

            Text(title)
                .font(DaymarkTypography.sectionTitle)
                .foregroundStyle(DaymarkPalette.ink)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(DaymarkPalette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DaymarkSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Month header

/// Opens a month like a magazine section: a very large serif month numeral,
/// the month's name in small capitals and how many days are marked.
struct DaymarkMonthHeader: View {
    let month: Date
    let markedDays: Int

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: DaymarkSpacing.s) {
            Text(month.formatted(.dateTime.month(.defaultDigits)))
                .font(.system(size: 76, weight: .regular, design: .serif))
                .monospacedDigit()
                .foregroundStyle(DaymarkPalette.ink)

            VStack(alignment: .leading, spacing: 3) {
                Text(month.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(DaymarkPalette.ink)

                HStack(spacing: 5) {
                    DaymarkBeaconMark(size: 6)
                    Text(markedDays == 1 ? "1 day marked" : "\(markedDays) days marked")
                        .font(.caption)
                        .foregroundStyle(DaymarkPalette.secondaryInk)
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, DaymarkSpacing.l)
        .padding(.bottom, DaymarkSpacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(month.formatted(.dateTime.month(.wide).year())), \(markedDays) days marked")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Stamping

/// Plays once when a day is marked: the postmark drops onto the page with a thud.
struct DaymarkStampOverlay: View {
    let date: Date
    @State private var landed = false

    var body: some View {
        DaymarkPostmark(date: date, diameter: 190)
            .scaleEffect(landed ? 1 : 2.4)
            .opacity(landed ? 1 : 0)
            .rotationEffect(.degrees(landed ? 0 : -14))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DaymarkPalette.paper.opacity(landed ? 0.82 : 0))
            .allowsHitTesting(false)
            .sensoryFeedback(.impact(weight: .heavy), trigger: landed)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) {
                    landed = true
                }
            }
    }
}

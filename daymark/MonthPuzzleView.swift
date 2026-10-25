import PhotosUI
import SwiftUI

/// Regular grid cut of one month into square day pieces, centred in the page.
/// Leading leftover cells of the first row merge into a single title piece,
/// so every cell of the board is used and the board stays a clean rectangle.
/// Days run newest first: the last day of the month follows the title and
/// the 1st closes the board, matching the reverse-chronological feed.
struct MonthPuzzleLayout {
    let dayCount: Int
    let columns: Int
    let rows: Int
    /// Side of one square cell, gap included.
    let cellSide: CGFloat
    let boardRect: CGRect

    /// Cells taken by the title piece, always at least one.
    var titleSpan: Int { columns * rows - dayCount }

    init(dayCount: Int, availableSize: CGSize) {
        self.dayCount = dayCount

        // Pick the column count that gives the biggest square pieces while the
        // whole month still fits, and avoid a one-cell title piece when a
        // roomier cut is nearly as big.
        var best: (columns: Int, rows: Int, side: CGFloat, score: CGFloat) = (5, Int(ceil(Double(dayCount + 1) / 5)), 0, -.infinity)
        for columns in 4...8 {
            let rows = Int(ceil(Double(dayCount + 1) / Double(columns)))
            let side = min(availableSize.width / CGFloat(columns), availableSize.height / CGFloat(rows))
            guard side > 0 else { continue }
            let score = columns * rows - dayCount < 2 ? side * 0.92 : side
            if score > best.score {
                best = (columns, rows, side, score)
            }
        }

        columns = best.columns
        rows = best.rows
        cellSide = floor(best.side)
        let boardSize = CGSize(width: cellSide * CGFloat(columns), height: cellSide * CGFloat(rows))
        boardRect = CGRect(
            x: (availableSize.width - boardSize.width) / 2,
            y: (availableSize.height - boardSize.height) / 2,
            width: boardSize.width,
            height: boardSize.height
        )
    }

    var titleRect: CGRect {
        CGRect(x: boardRect.minX, y: boardRect.minY, width: cellSide * CGFloat(titleSpan), height: cellSide)
    }

    /// Frame of a 1-based day in page coordinates.
    func rect(forDay day: Int) -> CGRect {
        let index = titleSpan + dayCount - day
        return CGRect(
            x: boardRect.minX + CGFloat(index % columns) * cellSide,
            y: boardRect.minY + CGFloat(index / columns) * cellSide,
            width: cellSide,
            height: cellSide
        )
    }
}

/// One month as a single-screen puzzle of frosted-glass squares. A daymark
/// fills its square with the photo; an unmarked day stays an empty pane of
/// glass over a soft backdrop made from that month's own photos, so the
/// colours of marked days bleed into the blank ones around them.
struct MonthPuzzleView: View {
    let month: Date
    let entriesByDay: [Int: PhotoEntry]
    /// Binding the photo picker of an unmarked, non-future day writes into.
    let pickerSelection: (Date) -> Binding<PhotosPickerItem?>

    private let calendar = Calendar.current
    private let gap: CGFloat = 6
    private let pagePadding = EdgeInsets(top: 8, leading: 12, bottom: 14, trailing: 12)

    private var dayCount: Int {
        calendar.range(of: .day, in: .month, for: month)?.count ?? 30
    }

    /// Days that can hold a mark: the whole month, or up to today for the current one.
    private var markableDayCount: Int {
        let today = calendar.startOfDay(for: Date())
        return (1...dayCount).filter { date(forDay: $0) <= today }.count
    }

    private var isComplete: Bool {
        markableDayCount > 0 && (1...markableDayCount).allSatisfy { entriesByDay[$0] != nil }
    }

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(
                width: max(geometry.size.width - pagePadding.leading - pagePadding.trailing, 0),
                height: max(geometry.size.height - pagePadding.top - pagePadding.bottom, 0)
            )
            let layout = MonthPuzzleLayout(dayCount: dayCount, availableSize: available)

            ZStack(alignment: .topLeading) {
                backdrop(layout: layout, pageSize: geometry.size)

                ZStack(alignment: .topLeading) {
                    place(titlePiece(layout: layout), in: layout.titleRect)

                    ForEach(1...dayCount, id: \.self) { day in
                        let rect = layout.rect(forDay: day)
                        place(dayPiece(day: day, side: rect.width - gap), in: rect)
                    }
                }
                .offset(x: pagePadding.leading, y: pagePadding.top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    private func place(_ piece: some View, in rect: CGRect) -> some View {
        piece
            .frame(width: rect.width - gap, height: rect.height - gap)
            .offset(x: rect.minX + gap / 2, y: rect.minY + gap / 2)
    }

    private func cornerRadius(for side: CGFloat) -> CGFloat {
        min(max(side * 0.2, 8), 18)
    }

    // MARK: Backdrop

    /// What the glass blurs: a warm palette wash, the oversized month letters,
    /// and each photo blown up and blurred behind its own square.
    private func backdrop(layout: MonthPuzzleLayout, pageSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            DaymarkPalette.paper

            RadialGradient(
                colors: [DaymarkSwatch.stellarStrawberry.opacity(0.35), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: pageSize.height * 0.6
            )
            RadialGradient(
                colors: [DaymarkSwatch.picoEggplant.opacity(0.3), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: pageSize.height * 0.65
            )

            MonthLettering(month: month)
                .frame(width: pageSize.width, height: pageSize.height)

            ZStack(alignment: .topLeading) {
                ForEach(entriesByDay.keys.sorted(), id: \.self) { day in
                    if let entry = entriesByDay[day], (1...dayCount).contains(day) {
                        let rect = layout.rect(forDay: day)
                        EntryThumbnail(entry: entry) { Color.clear }
                            .frame(width: rect.width * 1.7, height: rect.height * 1.7)
                            .clipped()
                            .offset(
                                x: pagePadding.leading + rect.midX - rect.width * 0.85,
                                y: pagePadding.top + rect.midY - rect.height * 0.85
                            )
                    }
                }
            }
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            .blur(radius: 36)
            .opacity(0.85)
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    @ViewBuilder
    private func dayPiece(day: Int, side: CGFloat) -> some View {
        let date = date(forDay: day)

        if let entry = entriesByDay[day] {
            NavigationLink(value: entry) {
                photoPiece(entry: entry, day: day, side: side)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                [entry.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()), entry.countryName]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
        } else if date <= calendar.startOfDay(for: Date()) {
            PhotosPicker(selection: pickerSelection(date), matching: .images) {
                glassPiece(day: day, date: date, side: side)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add daymark for \(date.formatted(.dateTime.month(.wide).day()))")
        } else {
            glassPiece(day: day, date: date, side: side)
                .accessibilityHidden(true)
        }
    }

    private func photoPiece(entry: PhotoEntry, day: Int, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius(for: side), style: .continuous)

        return ZStack(alignment: .topLeading) {
            EntryThumbnail(entry: entry) {
                Rectangle().fill(.ultraThinMaterial)
            }
            .frame(width: side, height: side)
            .clipped()

            Text("\(day)")
                .font(.system(size: numberSize(for: side), weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                .padding(side * 0.1)

            if let flagEmoji = entry.flagEmoji {
                flagBadge(flagEmoji, side: side)
                    .padding(side * 0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { glassRim(shape) }
        .contentShape(shape)
        .shadow(color: DaymarkSwatch.heiSeBlack.opacity(0.18), radius: 6, x: 0, y: 3)
    }

    /// Same mounted-flag icon as `MarkCard`, scaled to the piece.
    private func flagBadge(_ flagEmoji: String, side: CGFloat) -> some View {
        let diameter = min(max(side * 0.26, 16), 26)

        return Text(flagEmoji)
            .font(.system(size: diameter * 0.55))
            .frame(width: diameter, height: diameter)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func glassPiece(day: Int, date: Date, side: CGFloat) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isFuture = date > calendar.startOfDay(for: Date())
        let shape = RoundedRectangle(cornerRadius: cornerRadius(for: side), style: .continuous)

        return ZStack(alignment: .topLeading) {
            Text("\(day)")
                .font(.system(size: numberSize(for: side), weight: isToday ? .bold : .medium, design: .serif))
                .foregroundStyle(isToday ? DaymarkPalette.highlight : DaymarkPalette.ink.opacity(0.7))
                .padding(side * 0.1)

            if isToday {
                Image(systemName: "plus")
                    .font(.system(size: side * 0.26, weight: .light))
                    .foregroundStyle(DaymarkPalette.highlight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: side, height: side)
        .background(.ultraThinMaterial, in: shape)
        .background(Color.white.opacity(0.08), in: shape)
        .overlay {
            if isToday {
                shape.strokeBorder(DaymarkPalette.highlight.opacity(0.9), lineWidth: 1.5)
            } else {
                glassRim(shape)
            }
        }
        .contentShape(shape)
        .opacity(isFuture ? 0.55 : 1)
    }

    /// A light catching the top-leading edge and fading out, the way the
    /// reference cards read as thick glass.
    private func glassRim(_ shape: RoundedRectangle) -> some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [.white.opacity(0.65), .white.opacity(0.08), .white.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 0.8
        )
    }

    private func titlePiece(layout: MonthPuzzleLayout) -> some View {
        let rect = layout.titleRect
        let height = rect.height - gap
        let shape = RoundedRectangle(cornerRadius: cornerRadius(for: height), style: .continuous)
        let filled = entriesByDay.keys.filter { (1...dayCount).contains($0) }.count

        return VStack(alignment: .leading, spacing: 1) {
            Spacer(minLength: 0)

            Text(month.formatted(.dateTime.month(layout.titleSpan > 1 ? .wide : .abbreviated)))
                .font(.system(size: height * 0.26, weight: .semibold, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            Text("\(month.formatted(.dateTime.year())) · \(filled)/\(dayCount)")
                .font(.system(size: max(height * 0.13, 9), weight: .medium).monospacedDigit())
                .opacity(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(isComplete ? Color.white : DaymarkPalette.ink)
        .padding(height * 0.1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background {
            if isComplete {
                shape.fill(DaymarkPalette.bloom)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .overlay { glassRim(shape) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func numberSize(for side: CGFloat) -> CGFloat {
        min(max(side * 0.2, 10), 18)
    }

    private func date(forDay day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: month) ?? month
    }
}

/// Oversized, condensed month letters stacked to fill the page behind the glass.
private struct MonthLettering: View {
    let month: Date

    private var glyphs: [String] {
        month.formatted(.dateTime.month(.abbreviated))
            .uppercased()
            .replacingOccurrences(of: ".", with: "")
            .map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Text(glyph)
                    .font(.system(size: 600, weight: .black))
                    .fontWidth(.compressed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.01)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(DaymarkPalette.accent.opacity(0.22))
        .accessibilityHidden(true)
    }
}

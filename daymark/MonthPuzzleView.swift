import PhotosUI
import SwiftUI

/// Regular grid cut of one month into day pieces that fills a fixed board.
/// Leading leftover cells of the first row merge into a single title piece,
/// so every cell of the board is used and the board stays a clean rectangle.
/// Days run newest first: the last day of the month follows the title and
/// the 1st closes the board, matching the reverse-chronological feed.
struct MonthPuzzleLayout {
    let dayCount: Int
    let columns: Int
    let rows: Int
    let boardSize: CGSize

    /// Cells taken by the title piece, always at least one.
    var titleSpan: Int { columns * rows - dayCount }

    var cellSize: CGSize {
        CGSize(width: boardSize.width / CGFloat(columns), height: boardSize.height / CGFloat(rows))
    }

    init(dayCount: Int, boardSize: CGSize) {
        self.dayCount = dayCount
        self.boardSize = boardSize

        // Pick the column count whose pieces come out closest to square, and
        // avoid a one-cell title piece when a roomier cut is nearly as square.
        var best: (columns: Int, rows: Int, score: Double) = (5, Int(ceil(Double(dayCount + 1) / 5)), -.infinity)
        for columns in 4...8 {
            let rows = Int(ceil(Double(dayCount + 1) / Double(columns)))
            let width = Double(boardSize.width) / Double(columns)
            let height = Double(boardSize.height) / Double(rows)
            guard width > 0, height > 0 else { continue }
            var score = min(width, height) / max(width, height)
            if columns * rows - dayCount < 2 {
                score -= 0.1
            }
            if score > best.score {
                best = (columns, rows, score)
            }
        }

        columns = best.columns
        rows = best.rows
    }

    var titleRect: CGRect {
        CGRect(x: 0, y: 0, width: cellSize.width * CGFloat(titleSpan), height: cellSize.height)
    }

    /// Frame of a 1-based day in board coordinates.
    func rect(forDay day: Int) -> CGRect {
        let index = titleSpan + dayCount - day
        let column = index % columns
        let row = index / columns
        return CGRect(
            x: CGFloat(column) * cellSize.width,
            y: CGFloat(row) * cellSize.height,
            width: cellSize.width,
            height: cellSize.height
        )
    }
}

/// One month as a single-screen puzzle. Each day is a piece; a daymark fills
/// its piece with the photo, and an unmarked day stays blank, showing its slice
/// of the oversized month lettering underneath. A fully marked month is a
/// complete personal picture.
struct MonthPuzzleView: View {
    let month: Date
    let entriesByDay: [Int: PhotoEntry]
    /// Binding the photo picker of an unmarked, non-future day writes into.
    let pickerSelection: (Date) -> Binding<PhotosPickerItem?>

    private let calendar = Calendar.current
    private let cutWidth: CGFloat = 3

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
            let layout = MonthPuzzleLayout(dayCount: dayCount, boardSize: geometry.size)

            ZStack(alignment: .topLeading) {
                titlePiece(layout: layout)
                    .frame(width: layout.titleRect.width - cutWidth, height: layout.titleRect.height - cutWidth)
                    .offset(x: layout.titleRect.minX + cutWidth / 2, y: layout.titleRect.minY + cutWidth / 2)

                ForEach(1...dayCount, id: \.self) { day in
                    let rect = layout.rect(forDay: day)
                    dayPiece(day: day, rect: rect, layout: layout)
                        .frame(width: rect.width - cutWidth, height: rect.height - cutWidth)
                        .clipShape(pieceShape)
                        .contentShape(pieceShape)
                        .offset(x: rect.minX + cutWidth / 2, y: rect.minY + cutWidth / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private var pieceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
    }

    // MARK: Pieces

    @ViewBuilder
    private func dayPiece(day: Int, rect: CGRect, layout: MonthPuzzleLayout) -> some View {
        let date = date(forDay: day)

        if let entry = entriesByDay[day] {
            NavigationLink(value: entry) {
                photoPiece(entry: entry, day: day, size: rect.size)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                [entry.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()), entry.countryName]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
        } else if date <= calendar.startOfDay(for: Date()) {
            PhotosPicker(selection: pickerSelection(date), matching: .images) {
                blankPiece(day: day, date: date, rect: rect, layout: layout)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add daymark for \(date.formatted(.dateTime.month(.wide).day()))")
        } else {
            blankPiece(day: day, date: date, rect: rect, layout: layout)
                .accessibilityHidden(true)
        }
    }

    private func photoPiece(entry: PhotoEntry, day: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            EntryThumbnail(entry: entry) {
                DaymarkPalette.recessed
            }
            .frame(width: size.width - cutWidth, height: size.height - cutWidth)
            .clipped()

            Text("\(day)")
                .font(.system(size: numberSize(for: size), weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                .padding(5)

            if let flagEmoji = entry.flagEmoji {
                flagBadge(flagEmoji, pieceSize: size)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    /// Same mounted-flag icon as `MarkCard`, scaled to the piece.
    private func flagBadge(_ flagEmoji: String, pieceSize: CGSize) -> some View {
        let diameter = min(max(min(pieceSize.width, pieceSize.height) * 0.26, 16), 26)

        return Text(flagEmoji)
            .font(.system(size: diameter * 0.55))
            .frame(width: diameter, height: diameter)
            .background(DaymarkPalette.photoMount, in: Circle())
            .shadow(color: .black.opacity(0.2), radius: 1.5, x: 0, y: 1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func blankPiece(day: Int, date: Date, rect: CGRect, layout: MonthPuzzleLayout) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isFuture = date > calendar.startOfDay(for: Date())

        return ZStack(alignment: .topLeading) {
            posterSlice(for: rect, layout: layout)

            Text("\(day)")
                .font(.system(size: numberSize(for: rect.size), weight: isToday ? .bold : .medium, design: .serif))
                .foregroundStyle(isToday ? DaymarkPalette.highlight : DaymarkPalette.secondaryInk)
                .opacity(isFuture ? 0.45 : 1)
                .padding(5)

            if isToday {
                Image(systemName: "plus")
                    .font(.system(size: min(rect.width, rect.height) * 0.28, weight: .medium))
                    .foregroundStyle(DaymarkPalette.highlight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                pieceShape
                    .strokeBorder(DaymarkPalette.highlight, lineWidth: 1.5)
            }
        }
    }

    private func titlePiece(layout: MonthPuzzleLayout) -> some View {
        let rect = layout.titleRect
        let filled = entriesByDay.keys.filter { (1...dayCount).contains($0) }.count
        let onAccent = isComplete

        return ZStack(alignment: .bottomLeading) {
            if isComplete {
                DaymarkPalette.bloom
            } else {
                posterSlice(for: rect, layout: layout)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(month.formatted(.dateTime.month(layout.titleSpan > 1 ? .wide : .abbreviated)))
                    .font(.system(size: rect.height * 0.26, weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)

                Text("\(month.formatted(.dateTime.year())) · \(filled)/\(dayCount)")
                    .font(.system(size: max(rect.height * 0.13, 9), weight: .medium).monospacedDigit())
                    .opacity(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .foregroundStyle(onAccent ? Color.white : DaymarkPalette.ink)
            .padding(6)
        }
        .clipShape(pieceShape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The part of the full-board lettering that sits under `rect`, so blank
    /// pieces read as fragments of one poster, like the reference print.
    private func posterSlice(for rect: CGRect, layout: MonthPuzzleLayout) -> some View {
        let inset = rect.insetBy(dx: cutWidth / 2, dy: cutWidth / 2)

        return ZStack(alignment: .topLeading) {
            DaymarkPalette.recessed

            MonthLettering(month: month)
                .frame(width: layout.boardSize.width, height: layout.boardSize.height)
                .offset(x: -inset.minX, y: -inset.minY)
        }
        .frame(width: inset.width, height: inset.height, alignment: .topLeading)
        .clipped()
    }

    private func numberSize(for size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.2, 10), 18)
    }

    private func date(forDay day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: month) ?? month
    }
}

/// Oversized, condensed month letters stacked to fill the board.
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
        .foregroundStyle(DaymarkPalette.accent.opacity(0.16))
        .accessibilityHidden(true)
    }
}

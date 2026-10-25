import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]

    private let photoStore = PhotoStore()
    @State private var errorMessage: String?
    @State private var showingAddSheet = false
    @State private var addSheetDate = Date()
    @State private var addSheetPhotoItem: PhotosPickerItem?
    @State private var displayedMonth = Calendar.current.startOfMonth(for: Date())
    @State private var pieceSelectedDate = Date()
    @State private var piecePhotoItem: PhotosPickerItem?
    @State private var pendingLocationImport: PendingPhotoImport?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let pageHeight = max(geometry.size.height, 1)

                // One month per screen; newest at the top, scroll down for earlier months.
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(puzzleMonths, id: \.self) { month in
                            MonthPuzzleView(
                                month: month,
                                entriesByDay: entriesByDay(in: month),
                                pickerSelection: pieceSelection(for:)
                            )
                            .frame(height: pageHeight)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollIndicators(.hidden)
            }
            .background(DaymarkPalette.paper)
            .daymarkNavigationTitle("Daymark", inline: true)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PhotoEntry.self) { entry in
                PhotoDetailView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addSheetDate = Date()
                        displayedMonth = calendar.startOfMonth(for: addSheetDate)
                        addSheetPhotoItem = nil
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Daymark")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SearchView(autoActivateSearch: true)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search Photos")
                }
            }
            .daymarkScreen()
        }
        .task(id: locationBackfillKey) {
            guard scenePhase == .active else { return }
            await photoStore.backfillLocationDetails(for: entries, in: modelContext)
        }
        .alert("Photo Import Failed", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Could not import that photo.")
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                VStack(spacing: 20) {
                    addDaymarkCalendar
                        .padding(.horizontal)

                    PhotosPicker(selection: $addSheetPhotoItem, matching: .images) {
                        Text(selectedDateHasEntry ? "Date Already Has Daymark" : "Choose Photo")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDateHasEntry)
                    .padding(.horizontal)

                    if selectedDateHasEntry {
                        Text("Pick a date without a daymark.")
                            .font(.footnote)
                            .foregroundStyle(DaymarkPalette.secondaryInk)
                    }
                }
                .daymarkNavigationTitle("Add Daymark", inline: true)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingAddSheet = false
                        }
                    }
                }
                .daymarkScreen()
            }
        }
        .sheet(item: $pendingLocationImport, onDismiss: {
            pendingLocationImport = nil
        }) { pendingImport in
            LocationPickerView { lat, lon, city, countryCode, countryName in
                let location = PhotoLocationOverride(
                    latitude: lat,
                    longitude: lon,
                    city: city,
                    countryCode: countryCode,
                    countryName: countryName
                )
                Task {
                    await savePendingLocationImport(pendingImport, location: location)
                }
            }
        }
        .onChange(of: addSheetPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importPickedPhoto(newItem, for: addSheetDate, dismissAddSheetOnSave: true)
                addSheetPhotoItem = nil
            }
        }
        .onChange(of: piecePhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importPickedPhoto(newItem, for: pieceSelectedDate)
                piecePhotoItem = nil
            }
        }
    }

    private var addDaymarkCalendar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    displayedMonth = calendar.date(byAdding: .year, value: -1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .frame(minWidth: 44, minHeight: 44)

                Spacer()

                Text(displayedMonth.formatted(.dateTime.year()))
                    .font(DaymarkTypography.sectionTitle)

                Spacer()

                Button {
                    let nextYear = calendar.date(byAdding: .year, value: 1, to: displayedMonth) ?? displayedMonth
                    displayedMonth = min(nextYear, calendar.startOfMonth(for: Date()))
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isDisplayingCurrentYear)
            }
            .padding(.horizontal, 4)

            HStack {
                Button {
                    displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .frame(minWidth: 44, minHeight: 44)

                Spacer()

                Text(displayedMonth.formatted(.dateTime.month(.wide)))
                    .font(DaymarkTypography.sectionTitle)

                Spacer()

                Button {
                    let nextMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                    displayedMonth = min(nextMonth, calendar.startOfMonth(for: Date()))
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(isDisplayingCurrentMonth)
            }
            .padding(.horizontal, 4)

            let symbols = calendar.veryShortWeekdaySymbols
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(symbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DaymarkPalette.secondaryInk)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthDays(for: displayedMonth)) { day in
                    if let date = day.date {
                        let isSelected = calendar.isDate(date, inSameDayAs: addSheetDate)
                        let isToday = calendar.isDateInToday(date)
                        let hasEntry = hasEntry(on: date)

                        Button {
                            addSheetDate = date
                        } label: {
                            ZStack {
                                if hasEntry {
                                    Rectangle()
                                        .fill((isSelected ? Color.white : DaymarkPalette.ink).opacity(isSelected ? 0.95 : 0.75))
                                        .frame(width: 24, height: 2.5)
                                        .rotationEffect(.degrees(-18))
                                }

                                Text(dayNumberText(for: date))
                                    .font(.system(.body, design: .serif, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(dayForegroundStyle(isSelected: isSelected, isToday: isToday, hasEntry: hasEntry))
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background {
                                Circle()
                                    .fill(isSelected ? DaymarkPalette.accent : .clear)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Every month from the earliest daymark through the current month, newest
    /// first. Months without any mark still get a (blank) puzzle.
    private var puzzleMonths: [Date] {
        let currentMonth = calendar.startOfMonth(for: Date())
        let newest = entries.first.map { calendar.startOfMonth(for: $0.day) } ?? currentMonth
        let oldest = entries.last.map { calendar.startOfMonth(for: $0.day) } ?? currentMonth
        var month = max(newest, currentMonth)
        let end = min(oldest, currentMonth)
        var months: [Date] = []
        while month >= end {
            months.append(month)
            guard let previous = calendar.date(byAdding: .month, value: -1, to: month) else { break }
            month = previous
        }
        return months
    }

    private func entriesByDay(in month: Date) -> [Int: PhotoEntry] {
        Dictionary(
            entries(in: month).map { (calendar.component(.day, from: $0.day), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func pieceSelection(for date: Date) -> Binding<PhotosPickerItem?> {
        Binding(
            get: { piecePhotoItem },
            set: { newItem in
                pieceSelectedDate = date
                piecePhotoItem = newItem
            }
        )
    }

    private func entries(in month: Date) -> [PhotoEntry] {
        entries.filter { calendar.isDate($0.day, equalTo: month, toGranularity: .month) }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var selectedDateHasEntry: Bool {
        hasEntry(on: addSheetDate)
    }

    private var isDisplayingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month)
    }

    private var isDisplayingCurrentYear: Bool {
        calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .year)
    }

    // New imports/cloud arrivals and returning to the app retry missing locations.
    // Exclude resolved names/codes so repairs do not restart their own task.
    private var locationBackfillKey: String {
        "\(scenePhase)-" + entries.map {
            "\($0.id):\($0.latitude?.description ?? ""):\($0.longitude?.description ?? "")"
        }.sorted().joined(separator: "|")
    }

    private func hasEntry(on date: Date) -> Bool {
        entries.contains(where: { calendar.isDate($0.day, inSameDayAs: date) })
    }

    @MainActor
    private func importPickedPhoto(
        _ item: PhotosPickerItem,
        for date: Date,
        dismissAddSheetOnSave: Bool = false
    ) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not import that photo."
                return
            }

            if photoStore.hasEmbeddedLocation(in: data) {
                try await photoStore.savePhotoData(data, for: date, in: modelContext)
                if dismissAddSheetOnSave {
                    showingAddSheet = false
                }
            } else {
                if dismissAddSheetOnSave {
                    showingAddSheet = false
                }
                pendingLocationImport = PendingPhotoImport(data: data, date: date)
            }
        } catch {
            errorMessage = "Could not import that photo."
        }
    }

    @MainActor
    private func savePendingLocationImport(_ importItem: PendingPhotoImport, location: PhotoLocationOverride) async {
        do {
            try await photoStore.savePhotoData(
                importItem.data,
                for: importItem.date,
                in: modelContext,
                locationOverride: location
            )
            pendingLocationImport = nil
        } catch {
            errorMessage = "Could not import that photo."
        }
    }

    private func monthDays(for month: Date) -> [CalendarDay] {
        guard
            let monthInterval = calendar.dateInterval(of: .month, for: month),
            let firstWeekInterval = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start),
            let lastDay = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
            let lastWeekInterval = calendar.dateInterval(of: .weekOfMonth, for: lastDay)
        else {
            return []
        }

        let visibleInterval = DateInterval(start: firstWeekInterval.start, end: lastWeekInterval.end)
        var days: [CalendarDay] = []
        var date = visibleInterval.start
        var index = 0

        while date < visibleInterval.end {
            let isInDisplayedMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
            days.append(CalendarDay(id: index, date: isInDisplayedMonth ? date : nil))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? visibleInterval.end
            index += 1
        }

        return days
    }

    private func dayNumberText(for date: Date) -> String {
        String(calendar.component(.day, from: date))
    }

    private func dayForegroundStyle(isSelected: Bool, isToday: Bool, hasEntry: Bool) -> Color {
        if isSelected {
            return .white
        }

        if hasEntry {
            return DaymarkPalette.secondaryInk
        }

        return isToday ? DaymarkPalette.accent : DaymarkPalette.ink
    }
}

private struct CalendarDay: Identifiable {
    let id: Int
    let date: Date?
}

private struct PendingPhotoImport: Identifiable {
    let id = UUID()
    let data: Data
    let date: Date
}

private extension Calendar {
    func startOfMonth(for value: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: value)) ?? value
    }
}

struct MarkCard: View {
    let entry: PhotoEntry
    let dayText: String
    let subtitleText: String?
    let flagEmoji: String?
    let size: CGFloat
    @ScaledMetric(relativeTo: .headline) private var dayFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var metadataFontSize: CGFloat = 10

    private var overlayScale: CGFloat {
        min(size / 120, 1)
    }

    private var accessibilityDescription: String {
        [
            entry.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
            subtitleText,
            flagEmoji
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    var body: some View {
        if size > 0 {
            ZStack {
                EntryThumbnail(entry: entry) {
                    ZStack {
                        LinearGradient(
                            colors: [DaymarkPalette.paper, DaymarkPalette.recessed],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        Image(systemName: "photo")
                            .font(.system(size: 20 * overlayScale, weight: .medium))
                            .foregroundStyle(DaymarkPalette.secondaryInk)
                    }
                }
                .frame(width: size, height: size)
                .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.42), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(width: size, height: size)

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8 * overlayScale) {
                        VStack(alignment: .leading, spacing: overlayScale) {
                            Text(dayText)
                                .font(.system(size: dayFontSize * overlayScale, weight: .semibold, design: .serif))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .allowsTightening(true)

                            if let subtitleText {
                                Text(subtitleText)
                                    .font(.system(size: metadataFontSize * overlayScale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .allowsTightening(true)
                            }
                        }

                        Spacer(minLength: 0)

                        if let flagEmoji {
                            Text(flagEmoji)
                                .font(.system(size: 14 * overlayScale))
                                .frame(width: 28 * overlayScale, height: 28 * overlayScale)
                                .background(DaymarkPalette.photoMount, in: Circle())
                                .fixedSize()
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(8 * overlayScale)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
        }
    }
}

#Preview {
    CalendarView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}

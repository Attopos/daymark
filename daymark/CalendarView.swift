import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]

    private let photoStore = PhotoStore()
    @State private var selectedItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var showingAddSheet = false
    @State private var addSheetDate = Date()
    @State private var addSheetPhotoItem: PhotosPickerItem?
    @State private var displayedMonth = Calendar.current.startOfMonth(for: Date())
    @State private var showPastDays = false
    @State private var pastDaysMonthCount = 12
    @State private var pastDaysSelectedDate = Date()
    @State private var pastDaysPhotoItem: PhotosPickerItem?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let metrics = layoutMetrics(for: geometry.size.width, safeAreaInsets: geometry.safeAreaInsets)

                if metrics.cellSize > 0 {
                    ScrollView {
                        if showPastDays {
                            pastDaysGrid(metrics: metrics)
                                .padding(.horizontal, metrics.horizontalPadding)
                                .padding(.top, metrics.topPadding)
                                .padding(.bottom, metrics.bottomPadding)
                        } else {
                            photoGrid(metrics: metrics)
                                .padding(.horizontal, metrics.horizontalPadding)
                                .padding(.top, metrics.topPadding)
                                .padding(.bottom, metrics.bottomPadding)
                        }
                    }
                }
            }
            .navigationTitle("Daymark")
            .toolbarTitleDisplayMode(.inlineLarge)
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
                    Menu {
                        Button {
                            withAnimation {
                                showPastDays.toggle()
                                if showPastDays {
                                    pastDaysMonthCount = 12
                                }
                            }
                        } label: {
                            Label(
                                showPastDays ? "Show Daymarks" : "Show Past Days",
                                systemImage: showPastDays ? "photo.on.rectangle" : "calendar"
                            )
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Filter")
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
        }
        .task {
            await photoStore.backfillLocationDetails(for: entries, in: modelContext)
        }
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }

            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        errorMessage = "Could not import that photo."
                        selectedItem = nil
                        return
                    }

                    try await photoStore.savePhotoData(data, for: Date(), in: modelContext)
                } catch {
                    errorMessage = "Could not import that photo."
                }

                selectedItem = nil
            }
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
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Add Daymark")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingAddSheet = false
                        }
                    }
                }
            }
        }
        .onChange(of: addSheetPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        errorMessage = "Could not import that photo."
                        addSheetPhotoItem = nil
                        return
                    }
                    try await photoStore.savePhotoData(data, for: addSheetDate, in: modelContext)
                    showingAddSheet = false
                } catch {
                    errorMessage = "Could not import that photo."
                }
                addSheetPhotoItem = nil
            }
        }
        .onChange(of: pastDaysPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        errorMessage = "Could not import that photo."
                        pastDaysPhotoItem = nil
                        return
                    }
                    try await photoStore.savePhotoData(data, for: pastDaysSelectedDate, in: modelContext)
                } catch {
                    errorMessage = "Could not import that photo."
                }
                pastDaysPhotoItem = nil
            }
        }
    }

    private var addDaymarkCalendar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }

                Spacer()

                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)

                Spacer()

                Button {
                    let nextMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                    displayedMonth = min(nextMonth, calendar.startOfMonth(for: Date()))
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                }
                .disabled(isDisplayingCurrentMonth)
            }

            let symbols = calendar.veryShortWeekdaySymbols
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(symbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                                        .fill((isSelected ? Color.white : Color.primary).opacity(isSelected ? 0.95 : 0.75))
                                        .frame(width: 24, height: 2.5)
                                        .rotationEffect(.degrees(-18))
                                }

                                Text(dayNumberText(for: date))
                                    .font(.body.weight(isSelected ? .bold : .regular))
                                    .foregroundStyle(dayForegroundStyle(isSelected: isSelected, isToday: isToday, hasEntry: hasEntry))
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background {
                                Circle()
                                    .fill(isSelected ? Color.accentColor : .clear)
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

    private func photoGrid(metrics: LayoutMetrics) -> some View {
        LazyVGrid(columns: columns(for: metrics), spacing: metrics.gridSpacing) {
            if canCreateTodayMark {
                addMarkTile(size: metrics.cellSize)
            }

            ForEach(entries) { entry in
                NavigationLink(value: entry) {
                    photoTile(for: entry, size: metrics.cellSize)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addMarkTile(size: CGFloat) -> some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(Color.primary.opacity(0.18))

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Today")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)

                            Text("Create mark")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .padding(8)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func photoTile(for entry: PhotoEntry, size: CGFloat) -> some View {
        MarkCard(
            image: photoStore.thumbnail(for: entry),
            dayText: dayLabel(for: entry.day),
            subtitleText: monthLabel(for: entry.day),
            flagEmoji: entry.flagEmoji,
            size: size
        )
    }

    private var pastMonths: [Date] {
        (0..<pastDaysMonthCount).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: calendar.startOfMonth(for: Date()))
        }
    }

    private func pastDaysGrid(metrics: LayoutMetrics) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(pastMonths, id: \.self) { month in
                Section {
                    LazyVGrid(columns: columns(for: metrics), spacing: metrics.gridSpacing) {
                        ForEach(daysInMonth(month), id: \.self) { date in
                            if let entry = entry(for: date) {
                                NavigationLink(value: entry) {
                                    photoTile(for: entry, size: metrics.cellSize)
                                }
                                .buttonStyle(.plain)
                            } else {
                                emptyDayTile(date: date, size: metrics.cellSize)
                            }
                        }
                    }
                } header: {
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.title3.bold())
                        .padding(.top, 8)
                }
            }

            Color.clear
                .frame(height: 1)
                .onAppear {
                    pastDaysMonthCount += 12
                }
        }
    }

    private func emptyDayTile(date: Date, size: CGFloat) -> some View {
        PhotosPicker(selection: Binding(
            get: { pastDaysPhotoItem },
            set: { newItem in
                pastDaysSelectedDate = date
                pastDaysPhotoItem = newItem
            }
        ), matching: .images) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(Color.primary.opacity(0.18))

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(dayLabel(for: date))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)

                        Text(monthLabel(for: date))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Spacer(minLength: 0)
                }
                .padding(8)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func daysInMonth(_ month: Date) -> [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let today = calendar.startOfDay(for: Date())
        return range.compactMap { dayNumber -> Date? in
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = dayNumber
            guard let date = calendar.date(from: components) else { return nil }
            let startOfDate = calendar.startOfDay(for: date)
            return startOfDate <= today ? startOfDate : nil
        }.reversed()
    }

    private func entry(for date: Date) -> PhotoEntry? {
        entries.first(where: { calendar.isDate($0.day, inSameDayAs: date) })
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var canCreateTodayMark: Bool {
        !entries.contains(where: { calendar.isDateInToday($0.day) })
    }

    private var selectedDateHasEntry: Bool {
        hasEntry(on: addSheetDate)
    }

    private var isDisplayingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month)
    }

    private func columns(for metrics: LayoutMetrics) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cellSize), spacing: metrics.gridSpacing), count: 3)
    }

    private func layoutMetrics(for width: CGFloat, safeAreaInsets: EdgeInsets) -> LayoutMetrics {
        let horizontalPadding = 8.0
        let gridSpacing = 2.0
        let topPadding = 10.0
        let bottomPadding = max(safeAreaInsets.bottom + 20, 28)
        let safeWidth = width.isFinite ? max(width, 0) : 0
        let availableWidth = max(safeWidth - (horizontalPadding * 2) - (gridSpacing * 2), 0)
        let cellSize = max(floor(availableWidth / 3), 0)

        return LayoutMetrics(
            horizontalPadding: horizontalPadding,
            gridSpacing: gridSpacing,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            cellSize: cellSize
        )
    }

    private func dayLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day())
    }

    private func monthLabel(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    private func hasEntry(on date: Date) -> Bool {
        entries.contains(where: { calendar.isDate($0.day, inSameDayAs: date) })
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
            return .primary.opacity(0.55)
        }

        return isToday ? .accentColor : .primary
    }
}

private struct LayoutMetrics {
    let horizontalPadding: CGFloat
    let gridSpacing: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let cellSize: CGFloat
}

private struct CalendarDay: Identifiable {
    let id: Int
    let date: Date?
}

private extension Calendar {
    func startOfMonth(for value: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: value)) ?? value
    }
}

struct MarkCard: View {
    let image: UIImage?
    let dayText: String
    let subtitleText: String
    let flagEmoji: String?
    let size: CGFloat

    var body: some View {
        if size > 0 {
            ZStack {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color(.secondarySystemBackground), Color(.systemGray6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary)
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
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dayText)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text(subtitleText)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        Spacer(minLength: 0)

                        if let flagEmoji {
                            Text(flagEmoji)
                                .font(.system(size: 14))
                                .frame(width: 28, height: 28)
                                .background(.white, in: Circle())
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(8)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

#Preview {
    CalendarView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}

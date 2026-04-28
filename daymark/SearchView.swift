import SwiftData
import SwiftUI
import UIKit

struct SearchView: View {
    @Query(sort: \PhotoEntry.day, order: .reverse) private var allEntries: [PhotoEntry]
    private let photoStore = PhotoStore()
    private let calendar = Calendar.current

    @State private var searchText = ""
    @State private var selectedCountryCode: String?
    @State private var selectedCity: String?
    @State private var filterByDateRange = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var showingDatePicker = false

    private var availableCountries: [CountryFilter] {
        let countries = allEntries.reduce(into: [String: CountryFilter]()) { partialResult, entry in
            guard let code = entry.countryCode?.uppercased(), !code.isEmpty else { return }
            let name = entry.countryName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = Locale.current.localizedString(forRegionCode: code) ?? code
            let resolvedName = (name?.isEmpty == false ? name! : fallbackName)
            partialResult[code] = CountryFilter(code: code, name: resolvedName)
        }

        return countries.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var filteredCities: [String] {
        let relevant = selectedCountryCode != nil
            ? allEntries.filter { $0.countryCode == selectedCountryCode }
            : allEntries
        return Set(relevant.compactMap(\.city)).sorted()
    }

    private var selectedCountryLabel: String? {
        availableCountries.first(where: { $0.code == selectedCountryCode })?.label
    }

    private var filteredEntries: [PhotoEntry] {
        allEntries.filter { entry in
            if !searchText.isEmpty {
                let matches = [entry.city, entry.countryName, entry.countryCode, entry.caption]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(searchText) }
                if !matches { return false }
            }
            if let selectedCountryCode, entry.countryCode != selectedCountryCode { return false }
            if let selectedCity, entry.city != selectedCity { return false }
            if filterByDateRange {
                let dayStart = calendar.startOfDay(for: startDate)
                let dayEnd = calendar.startOfDay(for: endDate).addingTimeInterval(86399)
                if entry.day < dayStart || entry.day > dayEnd { return false }
            }
            return true
        }
    }

    private var hasActiveFilters: Bool {
        selectedCountryCode != nil || selectedCity != nil || filterByDateRange
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let metrics = layoutMetrics(for: geometry.size.width, safeAreaInsets: geometry.safeAreaInsets)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        filterSection

                        Text("\(filteredEntries.count) photo\(filteredEntries.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: columns(for: metrics), spacing: metrics.gridSpacing) {
                            ForEach(filteredEntries) { entry in
                                NavigationLink(value: entry) {
                                    MarkCard(
                                        image: photoStore.thumbnail(for: entry),
                                        dayText: dayLabel(for: entry.day),
                                        subtitleText: entry.city ?? entry.day.formatted(.dateTime.month(.abbreviated).year()),
                                        flagEmoji: entry.flagEmoji,
                                        size: metrics.cellSize
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, metrics.horizontalPadding)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, metrics.bottomPadding)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "City, country, or caption")
            .navigationDestination(for: PhotoEntry.self) { entry in
                PhotoDetailView(entry: entry)
            }
            .sheet(isPresented: $showingDatePicker) {
                datePickerSheet
            }
        }
    }

    // MARK: - Filters

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterPickerRow(
                title: "Country",
                selectionText: selectedCountryLabel ?? "All countries"
            ) {
                Menu {
                    Button("All countries") {
                        withAnimation {
                            selectedCountryCode = nil
                            selectedCity = nil
                        }
                    }

                    ForEach(availableCountries) { country in
                        Button(country.label) {
                            withAnimation {
                                selectedCountryCode = country.code
                                selectedCity = nil
                            }
                        }
                    }
                } label: {
                    FilterChipLabel(
                        label: selectedCountryLabel ?? "Country",
                        systemImage: "globe.europe.africa",
                        isSelected: selectedCountryCode != nil
                    )
                }
                .buttonStyle(.plain)
            }

            filterPickerRow(
                title: "City",
                selectionText: selectedCity ?? "All cities"
            ) {
                Menu {
                    Button("All cities") {
                        withAnimation {
                            selectedCity = nil
                        }
                    }

                    ForEach(filteredCities, id: \.self) { city in
                        Button(city) {
                            withAnimation {
                                selectedCity = city
                            }
                        }
                    }
                } label: {
                    FilterChipLabel(
                        label: selectedCity ?? "City",
                        systemImage: "building.2",
                        isSelected: selectedCity != nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(filteredCities.isEmpty)
            }

            HStack(spacing: 8) {
                FilterChip(
                    label: filterByDateRange
                        ? "\(startDate.formatted(.dateTime.month(.abbreviated).day())) – \(endDate.formatted(.dateTime.month(.abbreviated).day().year()))"
                        : "Date Range",
                    systemImage: "calendar",
                    isSelected: filterByDateRange
                ) {
                    if filterByDateRange {
                        withAnimation { filterByDateRange = false }
                    } else {
                        showingDatePicker = true
                    }
                }

                if hasActiveFilters {
                    Spacer()
                    Button("Clear All") {
                        withAnimation {
                            selectedCountryCode = nil
                            selectedCity = nil
                            filterByDateRange = false
                        }
                    }
                    .font(.caption.weight(.medium))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func filterPickerRow<Content: View>(title: String, selectionText: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(selectionText)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            content()
        }
        .padding(.horizontal, 16)
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
            .padding(24)
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        filterByDateRange = true
                        showingDatePicker = false
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingDatePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Layout

    private func dayLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day())
    }

    private func columns(for metrics: SearchLayoutMetrics) -> [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cellSize), spacing: metrics.gridSpacing), count: 3)
    }

    private func layoutMetrics(for width: CGFloat, safeAreaInsets: EdgeInsets) -> SearchLayoutMetrics {
        let horizontalPadding = 8.0
        let gridSpacing = 2.0
        let bottomPadding = max(safeAreaInsets.bottom + 20, 28)
        let availableWidth = width - (horizontalPadding * 2) - (gridSpacing * 2)
        let cellSize = floor(availableWidth / 3)
        return SearchLayoutMetrics(
            horizontalPadding: horizontalPadding,
            gridSpacing: gridSpacing,
            bottomPadding: bottomPadding,
            cellSize: cellSize
        )
    }
}

// MARK: - Supporting Types

private struct SearchLayoutMetrics {
    let horizontalPadding: CGFloat
    let gridSpacing: CGFloat
    let bottomPadding: CGFloat
    let cellSize: CGFloat
}

private struct CountryFilter: Identifiable {
    let code: String
    let name: String

    var id: String { code }

    var label: String {
        if let flag {
            return "\(flag) \(name)"
        }
        return name
    }

    private var flag: String? {
        let scalars = code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(scalars.map { Character($0) })
    }
}

private struct FilterChip: View {
    let label: String
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FilterChipLabel(label: label, systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterChipLabel: View {
    let label: String
    var systemImage: String? = nil
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.primary.opacity(0.12) : Color(.tertiarySystemBackground),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(isSelected ? Color.primary.opacity(0.2) : Color.clear, lineWidth: 1)
        )
    }
}

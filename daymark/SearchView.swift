import SwiftData
import SwiftUI
import UIKit

struct SearchView: View {
    @Query(sort: \PhotoEntry.day, order: .reverse) private var allEntries: [PhotoEntry]
    private let photoStore = PhotoStore()
    private let calendar = Calendar.current
    private let autoActivateSearch: Bool

    @State private var searchText = ""
    @State private var isSearchPresented = false

    init(autoActivateSearch: Bool = false) {
        self.autoActivateSearch = autoActivateSearch
    }

    private var filteredEntries: [PhotoEntry] {
        allEntries.filter { entry in
            guard !searchText.isEmpty else { return true }

            let matches = [entry.city, entry.countryName, entry.countryCode, entry.caption]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
            if matches {
                return true
            }

            return entry.day.formatted(.dateTime.month(.abbreviated).day().year())
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let metrics = layoutMetrics(for: geometry.size.width, safeAreaInsets: geometry.safeAreaInsets)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
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
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "City, country, caption, or date"
            )
            .navigationDestination(for: PhotoEntry.self) { entry in
                PhotoDetailView(entry: entry)
            }
            .onAppear {
                guard autoActivateSearch else { return }
                isSearchPresented = true
            }
        }
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

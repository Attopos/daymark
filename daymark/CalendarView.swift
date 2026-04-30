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

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let metrics = layoutMetrics(for: geometry.size.width, safeAreaInsets: geometry.safeAreaInsets)

                ScrollView {
                    photoGrid(metrics: metrics)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, metrics.topPadding)
                        .padding(.bottom, metrics.bottomPadding)
                }
            }
            .navigationTitle("Daymark")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PhotoEntry.self) { entry in
                PhotoDetailView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SignInAvatarButton()
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

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var canCreateTodayMark: Bool {
        !entries.contains(where: { calendar.isDateInToday($0.day) })
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
}

private struct LayoutMetrics {
    let horizontalPadding: CGFloat
    let gridSpacing: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let cellSize: CGFloat
}

struct MarkCard: View {
    let image: UIImage?
    let dayText: String
    let subtitleText: String
    let flagEmoji: String?
    let size: CGFloat

    var body: some View {
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

#Preview {
    CalendarView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}

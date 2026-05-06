import SwiftData
import SwiftUI
import UIKit

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoEntry.day, order: .reverse) private var entries: [PhotoEntry]

    private let photoStore = PhotoStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        NavigationLink(value: entry) {
                            TimelineCardRow(
                                entry: entry,
                                image: photoStore.thumbnail(for: entry),
                                isFirst: index == 0,
                                isLast: index == entries.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle("Timeline")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: PhotoEntry.self) { entry in
                PhotoDetailView(entry: entry)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Daymarks Yet",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                        description: Text("Your timeline will appear here as you add daymarks.")
                    )
                }
            }
        }
    }
}

private struct TimelineCardRow: View {
    let entry: PhotoEntry
    let image: UIImage?
    let isFirst: Bool
    let isLast: Bool

    private let calendar = Calendar.current
    private let dotSize: CGFloat = 14
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            dateLabel
            timelineIndicator
            timelineCard
                .padding(.vertical, 8)
        }
    }

    private var dateLabel: some View {
        VStack(spacing: 3) {
            Text(entry.day.formatted(.dateTime.day()))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(entry.day.formatted(.dateTime.month(.abbreviated)))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if !calendar.isDate(entry.day, equalTo: .now, toGranularity: .year) {
                Text(entry.day.formatted(.dateTime.year()))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 50)
        .padding(.top, 14)
    }

    private var timelineIndicator: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? .clear : Color.primary.opacity(0.12))
                .frame(width: lineWidth, height: 22)

            Circle()
                .fill(calendar.isDateInToday(entry.day) ? Color.accentColor : Color.primary.opacity(0.28))
                .frame(width: dotSize, height: dotSize)

            Rectangle()
                .fill(isLast ? .clear : Color.primary.opacity(0.12))
                .frame(width: lineWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 24)
    }

    private var timelineCard: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                if let city = entry.city {
                    Text(city)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                if let countryName = entry.countryName {
                    Text(countryName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let flagEmoji = entry.flagEmoji {
                Text(flagEmoji)
                    .font(.system(size: 32))
                    .frame(width: 48, height: 48)
                    .background(Color(.tertiarySystemBackground), in: Circle())
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    TimelineView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}

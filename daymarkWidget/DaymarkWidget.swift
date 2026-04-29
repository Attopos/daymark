import SwiftUI
import UIKit
import WidgetKit

private struct TodayPhotoEntry: TimelineEntry {
    let date: Date
    let day: Date?
    let city: String?
    let countryName: String?
    let image: UIImage?
}

private struct TodayPhotoPayload: Codable {
    let day: Date
    let city: String?
    let countryName: String?
}

private struct TodayPhotoProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayPhotoEntry {
        TodayPhotoEntry(
            date: .now,
            day: .now,
            city: "Today",
            countryName: "Daymark",
            image: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayPhotoEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayPhotoEntry>) -> Void) {
        let entry = loadEntry()
        let nextRefresh = Calendar.current.nextDate(
            after: .now,
            matching: DateComponents(hour: 0, minute: 5),
            matchingPolicy: .nextTime
        ) ?? .now.addingTimeInterval(3600)

        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadEntry() -> TodayPhotoEntry {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DaymarkWidgetShared.appGroupIdentifier
        )
        let imageURL = containerURL?.appendingPathComponent(DaymarkWidgetShared.imageFilename)
        let metadataURL = containerURL?.appendingPathComponent(DaymarkWidgetShared.metadataFilename)

        let payload: TodayPhotoPayload? = {
            guard let metadataURL,
                  let data = try? Data(contentsOf: metadataURL) else {
                return nil
            }
            return try? JSONDecoder().decode(TodayPhotoPayload.self, from: data)
        }()

        let image: UIImage? = {
            guard let imageURL,
                  let data = try? Data(contentsOf: imageURL) else {
                return nil
            }
            return UIImage(data: data)
        }()

        let today = Calendar.current.startOfDay(for: .now)
        if let payload, Calendar.current.isDate(payload.day, inSameDayAs: today) {
            return TodayPhotoEntry(
                date: .now,
                day: payload.day,
                city: payload.city,
                countryName: payload.countryName,
                image: image
            )
        }

        return TodayPhotoEntry(date: .now, day: nil, city: nil, countryName: nil, image: nil)
    }
}

struct DaymarkTodayPhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DaymarkWidgetShared.widgetKind, provider: TodayPhotoProvider()) { entry in
            DaymarkTodayPhotoWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Photo")
        .description("Shows today's Daymark photo on your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct DaymarkTodayPhotoWidgetView: View {
    let entry: TodayPhotoEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.05), .black.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    Spacer()

                    Text(locationLine)
                        .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(family == .systemSmall ? 2 : 1)

                    if let day = entry.day {
                        Text(day.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: family == .systemSmall ? 28 : 34, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Add today's photo")
                        .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .containerBackground(for: .widget) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(entry.image == nil ? Color(.systemGray6) : Color.black)
        }
        .clipped()
    }

    private var locationLine: String {
        switch (entry.city, entry.countryName) {
        case let (city?, country?) where !city.isEmpty && !country.isEmpty:
            return "\(city), \(country)"
        case let (city?, _):
            return city
        case let (_, country?) where !country.isEmpty:
            return country
        default:
            return "Today's Memory"
        }
    }
}

@main
struct DaymarkWidgetBundle: WidgetBundle {
    var body: some Widget {
        DaymarkTodayPhotoWidget()
    }
}

private enum DaymarkWidgetShared {
    static let appGroupIdentifier = "group.com.aaroncao.daymark"
    static let widgetKind = "DaymarkTodayPhotoWidget"
    static let imageFilename = "today-photo.jpg"
    static let metadataFilename = "today-photo.json"
}

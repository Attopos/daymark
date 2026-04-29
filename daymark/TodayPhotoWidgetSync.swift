import Foundation
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

enum DaymarkWidgetShared {
    static let appGroupIdentifier = "group.com.aaroncao.daymark"
    static let widgetKind = "DaymarkTodayPhotoWidget"
    static let imageFilename = "today-photo.jpg"
    static let metadataFilename = "today-photo.json"
}

struct DaymarkTodayPhotoPayload: Codable {
    let day: Date
    let city: String?
    let countryName: String?
}

extension PhotoStore {
    func refreshTodayWidgetContent(in modelContext: ModelContext) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DaymarkWidgetShared.appGroupIdentifier
        ) else {
            return
        }

        let today = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<PhotoEntry>(
            predicate: #Predicate<PhotoEntry> { entry in
                entry.day == today
            }
        )

        let imageURL = containerURL.appendingPathComponent(DaymarkWidgetShared.imageFilename)
        let metadataURL = containerURL.appendingPathComponent(DaymarkWidgetShared.metadataFilename)
        let entry = try? modelContext.fetch(descriptor).first

        if let entry, let imageData = entry.imageData {
            try? imageData.write(to: imageURL, options: .atomic)

            let payload = DaymarkTodayPhotoPayload(
                day: entry.day,
                city: entry.city,
                countryName: entry.countryName
            )
            if let metadata = try? JSONEncoder().encode(payload) {
                try? metadata.write(to: metadataURL, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: DaymarkWidgetShared.widgetKind)
        #endif
    }
}

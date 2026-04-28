import Foundation
import SwiftData
import UIKit

struct PhotoStore {
    private let cache = NSCache<NSURL, UIImage>()
    private let calendar = Calendar.current
    private let fileManager = FileManager.default

    func normalizedDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func image(for entry: PhotoEntry) -> UIImage? {
        let url = fileURL(for: entry)

        if let cachedImage = cache.object(forKey: url as NSURL) {
            return cachedImage
        }

        guard let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }

        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func savePhotoData(_ data: Data, for date: Date, in modelContext: ModelContext) throws {
        let normalizedDate = normalizedDay(for: date)
        let entry = try existingEntry(for: normalizedDate, in: modelContext) ?? PhotoEntry(
            day: normalizedDate,
            imageFilename: filename(for: normalizedDate)
        )
        let filename = filename(for: normalizedDate)
        let destinationURL = photosDirectoryURL.appendingPathComponent(filename)

        try ensurePhotosDirectoryExists()
        try data.write(to: destinationURL, options: .atomic)

        if entry.modelContext == nil {
            modelContext.insert(entry)
        }

        entry.day = normalizedDate
        entry.imageFilename = filename

        try modelContext.save()
        cache.removeObject(forKey: destinationURL as NSURL)
    }

    private func existingEntry(for date: Date, in modelContext: ModelContext) throws -> PhotoEntry? {
        let descriptor = FetchDescriptor<PhotoEntry>()
        return try modelContext.fetch(descriptor).first(where: { $0.day == date })
    }

    private var photosDirectoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayPhotos", isDirectory: true)
    }

    private func ensurePhotosDirectoryExists() throws {
        try fileManager.createDirectory(at: photosDirectoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for entry: PhotoEntry) -> URL {
        photosDirectoryURL.appendingPathComponent(entry.imageFilename)
    }

    private func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: date)).photo"
    }
}

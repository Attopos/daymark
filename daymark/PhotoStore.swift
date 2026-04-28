import Foundation
import ImageIO
import CoreLocation
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
        let location = locationCoordinate(from: data)
        let entry = try existingEntry(for: normalizedDate, in: modelContext) ?? PhotoEntry(
            day: normalizedDate,
            imageFilename: filename(for: normalizedDate),
            latitude: location?.latitude,
            longitude: location?.longitude
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
        entry.latitude = location?.latitude
        entry.longitude = location?.longitude

        try modelContext.save()
        cache.removeObject(forKey: destinationURL as NSURL)
    }

    func deleteAllEntries(in modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<PhotoEntry>()
        let entries = try modelContext.fetch(descriptor)

        for entry in entries {
            let url = fileURL(for: entry)

            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }

            cache.removeObject(forKey: url as NSURL)
            modelContext.delete(entry)
        }

        if fileManager.fileExists(atPath: photosDirectoryURL.path) {
            try fileManager.removeItem(at: photosDirectoryURL)
        }

        try modelContext.save()
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

    func locationCoordinate(from data: Data) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }

        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String

        return CLLocationCoordinate2D(
            latitude: signedCoordinate(latitude, reference: latitudeRef, negativeReference: "S"),
            longitude: signedCoordinate(longitude, reference: longitudeRef, negativeReference: "W")
        )
    }

    private func signedCoordinate(_ value: Double, reference: String?, negativeReference: String) -> Double {
        guard let reference else {
            return value
        }

        return reference.caseInsensitiveCompare(negativeReference) == .orderedSame ? -abs(value) : abs(value)
    }
}

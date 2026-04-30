import Foundation
import ImageIO
import CoreTransferable
import CoreLocation
import MapKit
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct PhotoStore {
    private let imageCache = NSCache<NSString, UIImage>()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let calendar = Calendar.current
    private let fileManager = FileManager.default
    private let exifDateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private enum Thumbnail {
        static let maxPixelSize = 300.0
        static let compressionQuality = 0.82
    }

    private func normalizedDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func image(for entry: PhotoEntry) -> UIImage? {
        image(from: entry.imageData, cache: imageCache, cacheKey: cacheKey(for: entry, suffix: "full"))
    }

    func thumbnail(for entry: PhotoEntry) -> UIImage? {
        image(from: entry.thumbnailData ?? entry.imageData, cache: thumbnailCache, cacheKey: cacheKey(for: entry, suffix: "thumb"))
    }

    func makeBackupExportItem(from entries: [PhotoEntry]) throws -> DaymarkBackupExportItem {
        let backupEntries = entries.map { entry in
            DaymarkBackupEntry(
                day: entry.day,
                captureDate: entry.captureDate,
                imageData: entry.imageData,
                thumbnailData: entry.thumbnailData,
                latitude: entry.latitude,
                longitude: entry.longitude,
                countryCode: entry.countryCode,
                countryName: entry.countryName,
                city: entry.city,
                caption: entry.caption
            )
        }

        let payload = DaymarkBackupPayload(version: 1, exportedAt: Date(), entries: backupEntries)
        return try DaymarkBackupExportItem(data: encodedBackupData(for: payload))
    }

    func savePhotoData(_ data: Data, for date: Date, in modelContext: ModelContext) async throws {
        let normalizedDate = normalizedDay(for: date)
        let embeddedLocation = locationCoordinate(from: data)
        let location = if let embeddedLocation {
            embeddedLocation
        } else {
            await CurrentLocationProvider.requestLocation()
        }
        let captureDate = captureDate(from: data) ?? date
        let thumbnailData = try thumbnailData(from: data)
        let entry = try existingEntry(for: normalizedDate, in: modelContext) ?? PhotoEntry(day: normalizedDate)

        if entry.modelContext == nil {
            modelContext.insert(entry)
        }

        entry.day = normalizedDate
        entry.imageData = data
        entry.thumbnailData = thumbnailData
        entry.captureDate = captureDate
        entry.imageFilename = nil
        entry.latitude = location?.latitude
        entry.longitude = location?.longitude

        if let location {
            let details = await reverseGeocodeDetails(for: location)
            entry.countryCode = details.countryCode
            entry.countryName = details.countryName
            entry.city = details.city
        } else {
            entry.countryCode = nil
            entry.countryName = nil
            entry.city = nil
        }

        try modelContext.save()
        invalidateCaches(for: entry)
    }

    func saveEditedImage(_ image: UIImage, for entry: PhotoEntry, in modelContext: ModelContext) throws {
        let normalizedImage = image.normalizedImage()
        guard let imageData = normalizedImage.jpegData(compressionQuality: 0.92) else {
            throw PhotoStoreError.invalidImageData
        }

        entry.imageData = imageData
        entry.thumbnailData = try thumbnailData(from: imageData)
        entry.imageFilename = nil

        try modelContext.save()
        invalidateCaches(for: entry)
    }

    func deleteEntry(_ entry: PhotoEntry, in modelContext: ModelContext) throws {
        invalidateCaches(for: entry)
        modelContext.delete(entry)
        try modelContext.save()
    }

    func importBackup(from url: URL, into modelContext: ModelContext) throws {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let payload = try decodedBackupPayload(from: data)

        for backupEntry in payload.entries {
            let normalizedDate = normalizedDay(for: backupEntry.day)
            let entry = try existingEntry(for: normalizedDate, in: modelContext) ?? PhotoEntry(day: normalizedDate)

            if entry.modelContext == nil {
                modelContext.insert(entry)
            }

            entry.day = normalizedDate
            entry.captureDate = backupEntry.captureDate
            entry.imageData = backupEntry.imageData
            entry.thumbnailData = backupEntry.thumbnailData
            entry.imageFilename = nil
            entry.latitude = backupEntry.latitude
            entry.longitude = backupEntry.longitude
            entry.countryCode = backupEntry.countryCode
            entry.countryName = backupEntry.countryName
            entry.city = backupEntry.city
            entry.caption = backupEntry.caption

            invalidateCaches(for: entry)
        }

        try modelContext.save()
    }

    func backfillLocationDetails(for entries: [PhotoEntry], in modelContext: ModelContext) async {
        var didUpdate = false
        for entry in entries {
            guard (entry.countryCode == nil || entry.countryName == nil || entry.city == nil),
                  let lat = entry.latitude,
                  let lon = entry.longitude else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let details = await reverseGeocodeDetails(for: coordinate)
            if entry.countryCode != details.countryCode || entry.countryName != details.countryName || entry.city != details.city {
                entry.countryCode = details.countryCode
                entry.countryName = details.countryName
                entry.city = details.city
                didUpdate = true
            }
        }
        if didUpdate {
            try? modelContext.save()
        }
    }

    func migrateLegacyLibraryIfNeeded(in modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<PhotoEntry>()
        guard let entries = try? modelContext.fetch(descriptor) else { return }

        var migratedAnyEntries = false
        var allLegacyFilesWereMigrated = true

        for entry in entries where entry.imageData == nil {
            guard let filename = entry.imageFilename else { continue }
            let fileURL = legacyFileURL(filename: filename)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                allLegacyFilesWereMigrated = false
                continue
            }

            do {
                let data = try Data(contentsOf: fileURL)
                entry.imageData = data
                entry.thumbnailData = try thumbnailData(from: data)
                entry.captureDate = entry.captureDate ?? captureDate(from: data) ?? entry.day

                if let coordinate = locationCoordinate(from: data) {
                    entry.latitude = coordinate.latitude
                    entry.longitude = coordinate.longitude

                    if entry.countryCode == nil || entry.countryName == nil || entry.city == nil {
                        let details = await reverseGeocodeDetails(for: coordinate)
                        entry.countryCode = entry.countryCode ?? details.countryCode
                        entry.countryName = entry.countryName ?? details.countryName
                        entry.city = entry.city ?? details.city
                    }
                }

                entry.imageFilename = nil
                invalidateCaches(for: entry)
                migratedAnyEntries = true
            } catch {
                allLegacyFilesWereMigrated = false
            }
        }

        if migratedAnyEntries {
            try? modelContext.save()
        }

        if migratedAnyEntries && allLegacyFilesWereMigrated {
            removeLegacyPhotosDirectoryIfPossible()
        }
    }

    private func existingEntry(for date: Date, in modelContext: ModelContext) throws -> PhotoEntry? {
        let predicate = #Predicate<PhotoEntry> { entry in
            entry.day == date
        }
        let descriptor = FetchDescriptor<PhotoEntry>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    private var legacyPhotosDirectoryURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayPhotos", isDirectory: true)
    }

    private func image(from data: Data?, cache: NSCache<NSString, UIImage>, cacheKey: NSString) -> UIImage? {
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let data, let image = UIImage(data: data) else {
            return nil
        }

        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private func cacheKey(for entry: PhotoEntry, suffix: String) -> NSString {
        "\(entry.day.timeIntervalSinceReferenceDate)-\(suffix)" as NSString
    }

    private func invalidateCaches(for entry: PhotoEntry) {
        imageCache.removeObject(forKey: cacheKey(for: entry, suffix: "full"))
        thumbnailCache.removeObject(forKey: cacheKey(for: entry, suffix: "thumb"))
    }

    private func legacyFileURL(filename: String) -> URL {
        legacyPhotosDirectoryURL.appendingPathComponent(filename)
    }

    private func removeLegacyPhotosDirectoryIfPossible() {
        guard fileManager.fileExists(atPath: legacyPhotosDirectoryURL.path) else { return }
        try? fileManager.removeItem(at: legacyPhotosDirectoryURL)
    }

    private func thumbnailData(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoStoreError.invalidImageData
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Thumbnail.maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoStoreError.invalidImageData
        }

        let image = UIImage(cgImage: cgImage)
        guard let thumbnailData = image.jpegData(compressionQuality: Thumbnail.compressionQuality) else {
            throw PhotoStoreError.invalidImageData
        }

        return thumbnailData
    }

    private func locationCoordinate(from data: Data) -> CLLocationCoordinate2D? {
        guard let properties = imageProperties(from: data),
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

    private func captureDate(from data: Data) -> Date? {
        guard let properties = imageProperties(from: data) else { return nil }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            return exifDateFormatter.date(from: value)
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFDateTime] as? String {
            return exifDateFormatter.date(from: value)
        }

        return nil
    }

    private func imageProperties(from data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private func reverseGeocodeDetails(for coordinate: CLLocationCoordinate2D) async -> (countryCode: String?, countryName: String?, city: String?) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItem = try? await request.mapItems.first else {
            return (nil, nil, nil)
        }

        let address = mapItem.addressRepresentations
        let city = address?.cityName ?? mapItem.name
        let countryCode = address?.region?.identifier.uppercased()
        let countryName = address?.regionName
        return (countryCode, countryName, city)
    }

    private func encodedBackupData(for payload: DaymarkBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func decodedBackupPayload(from data: Data) throws -> DaymarkBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DaymarkBackupPayload.self, from: data)
    }

    private func signedCoordinate(_ value: Double, reference: String?, negativeReference: String) -> Double {
        guard let reference else {
            return value
        }

        return reference.caseInsensitiveCompare(negativeReference) == .orderedSame ? -abs(value) : abs(value)
    }
}

enum PhotoStoreError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "The selected file is not a valid image."
        }
    }
}

@MainActor
private final class CurrentLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    static func requestLocation() async -> CLLocationCoordinate2D? {
        let provider = CurrentLocationProvider()
        return await provider.requestLocation()
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private func requestLocation() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .restricted, .denied:
                finish(with: nil)
            @unknown default:
                finish(with: nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .restricted, .denied:
            finish(with: nil)
        case .notDetermined:
            break
        @unknown default:
            finish(with: nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    private func finish(with coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }
}

struct DaymarkBackupEntry: Codable {
    let day: Date
    let captureDate: Date?
    let imageData: Data?
    let thumbnailData: Data?
    let latitude: Double?
    let longitude: Double?
    let countryCode: String?
    let countryName: String?
    let city: String?
    let caption: String?
}

struct DaymarkBackupPayload: Codable {
    let version: Int
    let exportedAt: Date
    let entries: [DaymarkBackupEntry]
}

struct DaymarkBackupExportItem: Transferable {
    init(data: Data) throws {
        self.data = data
    }

    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { item in
            item.data
        }
    }
}

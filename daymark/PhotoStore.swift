import Foundation
import ImageIO
import CoreTransferable
import CoreLocation
import MapKit
import SwiftData
import UniformTypeIdentifiers
import UIKit

enum BackupImportMode {
    case merge
    case overwrite
}

struct BackupContents {
    let payload: DaymarkBackupPayload
    let imageFiles: [String: Data]
}

enum BackupError: LocalizedError {
    case invalidArchive
    case missingEntriesJSON
    case invalidEntriesJSON

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The file is not a valid backup archive."
        case .missingEntriesJSON: return "The archive does not contain entries.json."
        case .invalidEntriesJSON: return "Could not read backup metadata."
        }
    }
}

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
                id: entry.id,
                day: entry.day,
                captureDate: entry.captureDate,
                imageFilename: entry.imageData != nil ? "\(entry.id).jpg" : nil,
                latitude: entry.latitude,
                longitude: entry.longitude,
                timezone: entry.timezone,
                countryCode: entry.countryCode,
                countryName: entry.countryName,
                city: entry.city,
                caption: entry.caption
            )
        }

        let payload = DaymarkBackupPayload(version: 2, exportedAt: Date(), entries: backupEntries)
        let jsonData = try encodedBackupData(for: payload)

        var zipEntries = [ZipArchive.Entry(path: "entries.json", data: jsonData)]
        for entry in entries {
            guard let imageData = entry.imageData else { continue }
            zipEntries.append(ZipArchive.Entry(path: "images/\(entry.id).jpg", data: imageData))
        }

        return DaymarkBackupExportItem(data: ZipArchive.create(entries: zipEntries))
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
        entry.timezone = TimeZone.current.identifier

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

    func parseBackup(from url: URL) throws -> BackupContents {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)

        if data.count >= 2 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B {
            let zipEntries = try ZipArchive.read(from: data)

            guard let jsonEntry = zipEntries.first(where: { $0.path == "entries.json" }) else {
                throw BackupError.missingEntriesJSON
            }

            let payload: DaymarkBackupPayload
            do {
                payload = try decodedBackupPayload(from: jsonEntry.data)
            } catch {
                throw BackupError.invalidEntriesJSON
            }

            var imageFiles: [String: Data] = [:]
            for entry in zipEntries where entry.path.hasPrefix("images/") {
                let filename = String(entry.path.dropFirst("images/".count))
                guard !filename.isEmpty else { continue }
                imageFiles[filename] = entry.data
            }

            return BackupContents(payload: payload, imageFiles: imageFiles)
        }

        let payload: DaymarkBackupPayload
        do {
            payload = try decodedBackupPayload(from: data)
        } catch {
            throw BackupError.invalidEntriesJSON
        }
        return BackupContents(payload: payload, imageFiles: [:])
    }

    func importBackup(from contents: BackupContents, mode: BackupImportMode, into modelContext: ModelContext) throws {
        for backupEntry in contents.payload.entries {
            let normalizedDate = normalizedDay(for: backupEntry.day)
            let existing = try existingEntry(for: normalizedDate, in: modelContext)

            if mode == .merge && existing != nil {
                continue
            }

            let entry = existing ?? PhotoEntry(day: normalizedDate)
            if entry.modelContext == nil {
                modelContext.insert(entry)
            }

            if let backupID = backupEntry.id {
                entry.id = backupID
            }
            entry.day = normalizedDate
            entry.captureDate = backupEntry.captureDate
            entry.imageFilename = nil
            entry.latitude = backupEntry.latitude
            entry.longitude = backupEntry.longitude
            entry.timezone = backupEntry.timezone ?? entry.timezone
            entry.countryCode = backupEntry.countryCode
            entry.countryName = backupEntry.countryName
            entry.city = backupEntry.city
            entry.caption = backupEntry.caption

            if let filename = backupEntry.imageFilename,
               let imageData = contents.imageFiles[filename] {
                entry.imageData = imageData
                entry.thumbnailData = try? thumbnailData(from: imageData)
            } else if let legacyImageData = backupEntry.legacyImageData {
                entry.imageData = legacyImageData
                entry.thumbnailData = backupEntry.legacyThumbnailData ?? (try? thumbnailData(from: legacyImageData))
            }

            invalidateCaches(for: entry)
        }

        try modelContext.save()
    }

    func backfillMetadata(for entries: [PhotoEntry], in modelContext: ModelContext) {
        var seenIDs = Set<String>()
        var didUpdate = false
        for entry in entries {
            if entry.id.isEmpty || seenIDs.contains(entry.id) {
                entry.id = UUID().uuidString
                didUpdate = true
            }
            seenIDs.insert(entry.id)

            if entry.timezone == nil {
                entry.timezone = TimeZone.current.identifier
                didUpdate = true
            }
        }
        if didUpdate {
            try? modelContext.save()
        }
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
    let id: String?
    let day: Date
    let captureDate: Date?
    let imageFilename: String?
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
    let countryCode: String?
    let countryName: String?
    let city: String?
    let caption: String?

    var legacyImageData: Data? = nil
    var legacyThumbnailData: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id, day, captureDate, imageFilename
        case latitude, longitude, timezone
        case countryCode, countryName, city, caption
        case legacyImageData = "imageData"
        case legacyThumbnailData = "thumbnailData"
    }
}

struct DaymarkBackupPayload: Codable {
    let version: Int
    let exportedAt: Date
    let entries: [DaymarkBackupEntry]
}

struct DaymarkBackupExportItem: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .zip) { item in
            item.data
        }
    }
}

// MARK: - Zip Archive

enum ZipArchive {
    struct Entry {
        let path: String
        let data: Data
    }

    static func create(entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = crc32Checksum(entry.data)
            let offset = UInt32(archive.count)
            let size = UInt32(entry.data.count)

            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(crc)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(nameData.count))
            archive.appendUInt16(0)
            archive.append(nameData)
            archive.append(entry.data)

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt16(UInt16(nameData.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(offset)
            centralDirectory.append(nameData)

            entryCount += 1
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(entryCount)
        archive.appendUInt16(entryCount)
        archive.appendUInt32(UInt32(centralDirectory.count))
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)

        return archive
    }

    static func read(from data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw BackupError.invalidArchive }

        var eocdOffset = data.count - 22
        while eocdOffset >= 0 {
            if data.readZipUInt32(at: eocdOffset) == 0x06054b50 { break }
            eocdOffset -= 1
        }
        guard eocdOffset >= 0 else { throw BackupError.invalidArchive }

        let entryCount = Int(data.readZipUInt16(at: eocdOffset + 10))
        let centralDirOffset = Int(data.readZipUInt32(at: eocdOffset + 16))

        var entries: [Entry] = []
        var offset = centralDirOffset

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  data.readZipUInt32(at: offset) == 0x02014b50 else {
                throw BackupError.invalidArchive
            }

            let compressedSize = Int(data.readZipUInt32(at: offset + 20))
            let nameLength = Int(data.readZipUInt16(at: offset + 28))
            let extraLength = Int(data.readZipUInt16(at: offset + 30))
            let commentLength = Int(data.readZipUInt16(at: offset + 32))
            let localOffset = Int(data.readZipUInt32(at: offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { throw BackupError.invalidArchive }
            let name = String(data: data[nameStart..<nameStart + nameLength], encoding: .utf8) ?? ""

            guard localOffset + 30 <= data.count else { throw BackupError.invalidArchive }
            let localNameLength = Int(data.readZipUInt16(at: localOffset + 26))
            let localExtraLength = Int(data.readZipUInt16(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count else { throw BackupError.invalidArchive }

            entries.append(Entry(path: name, data: Data(data[dataStart..<dataStart + compressedSize])))
            offset = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    func readZipUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readZipUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) |
        (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}

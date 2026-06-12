import Foundation
import ImageIO
import CoreTransferable
import CoreLocation
import CryptoKit
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
    fileprivate let archiveData: Data?
    fileprivate let imageRanges: [String: Range<Int>]

    init(
        payload: DaymarkBackupPayload,
        archiveData: Data? = nil,
        imageRanges: [String: Range<Int>] = [:]
    ) {
        self.payload = payload
        self.archiveData = archiveData
        self.imageRanges = imageRanges
    }

    func imageData(named filename: String) -> Data? {
        guard let archiveData, let range = imageRanges[filename] else { return nil }
        return archiveData.subdata(in: range)
    }
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
    private static let sharedImageCache = NSCache<NSString, UIImage>()
    private static let sharedThumbnailCache = NSCache<NSString, UIImage>()

    private var imageCache: NSCache<NSString, UIImage> {
        Self.sharedImageCache
    }

    private var thumbnailCache: NSCache<NSString, UIImage> {
        Self.sharedThumbnailCache
    }
    private let calendar = Calendar.current
    private let fileManager = FileManager.default
    private let originalFileStore: OriginalPhotoFileStore
    private let thumbnailFileStore: ThumbnailPhotoFileStore
    private let viewPhotoFileStore: ViewPhotoFileStore
    private let conflictPhotoFileStore: ConflictPhotoFileStore
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

    private enum ViewPhoto {
        static let maxPixelSize = 2_048.0
        static let compressionQuality = 0.88
    }

    init(
        originalsDirectoryURL: URL? = nil,
        thumbnailsDirectoryURL: URL? = nil,
        viewPhotosDirectoryURL: URL? = nil,
        conflictPhotosDirectoryURL: URL? = nil
    ) {
        originalFileStore = OriginalPhotoFileStore(directoryURL: originalsDirectoryURL)
        thumbnailFileStore = ThumbnailPhotoFileStore(directoryURL: thumbnailsDirectoryURL)
        viewPhotoFileStore = ViewPhotoFileStore(directoryURL: viewPhotosDirectoryURL)
        conflictPhotoFileStore = ConflictPhotoFileStore(directoryURL: conflictPhotosDirectoryURL)
    }

    private func normalizedDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func image(for entry: PhotoEntry) -> UIImage? {
        image(from: originalData(for: entry), cache: imageCache, cacheKey: cacheKey(for: entry, suffix: "full"))
    }

    func viewImage(for entry: PhotoEntry) -> UIImage? {
        image(
            from: viewPhotoData(for: entry) ?? originalData(for: entry) ?? thumbnailData(for: entry),
            cache: imageCache,
            cacheKey: cacheKey(for: entry, suffix: "view")
        )
    }

    func thumbnail(for entry: PhotoEntry) -> UIImage? {
        image(
            from: thumbnailData(for: entry) ?? originalData(for: entry),
            cache: thumbnailCache,
            cacheKey: cacheKey(for: entry, suffix: "thumb")
        )
    }

    func thumbnailData(for entry: PhotoEntry) -> Data? {
        if let filename = entry.localThumbnailFilename,
           let data = try? thumbnailFileStore.read(filename: filename) {
            return data
        }
        return entry.thumbnailData
    }

    func viewPhotoData(for entry: PhotoEntry) -> Data? {
        guard let filename = entry.localViewPhotoFilename else { return nil }
        return try? viewPhotoFileStore.read(filename: filename)
    }

    func originalData(for entry: PhotoEntry) -> Data? {
        if let filename = entry.localOriginalFilename,
           let data = try? originalFileStore.read(filename: filename) {
            return data
        }
        return entry.imageData
    }

    func conflictOriginalData(for entry: PhotoEntry) -> Data? {
        guard let filename = entry.originalConflictRemoteFilename else { return nil }
        return try? conflictPhotoFileStore.read(filename: filename)
    }

    func conflictOriginalImage(for entry: PhotoEntry) -> UIImage? {
        image(
            from: conflictOriginalData(for: entry),
            cache: imageCache,
            cacheKey: cacheKey(for: entry, suffix: "conflict")
        )
    }

    func storeDownloadedOriginal(_ data: Data, for entry: PhotoEntry) throws {
        let storedOriginal = try originalFileStore.write(data, ownerID: entry.id)
        entry.imageData = nil
        entry.localOriginalFilename = storedOriginal.filename
        entry.originalByteCount = storedOriginal.byteCount
        entry.originalContentHash = storedOriginal.contentHash
        invalidateCaches(for: entry)
    }

    func storeDownloadedThumbnail(
        _ data: Data,
        remote: RemoteThumbnailPhoto,
        for entry: PhotoEntry
    ) throws {
        let storedThumbnail = try thumbnailFileStore.write(data, ownerID: entry.id)
        entry.thumbnailData = nil
        entry.localThumbnailFilename = storedThumbnail.filename
        entry.thumbnailByteCount = storedThumbnail.byteCount
        entry.thumbnailContentHash = storedThumbnail.contentHash
        entry.thumbnailModifiedAt = remote.modifiedAt
        invalidateCaches(for: entry)
    }

    func storeDownloadedViewPhoto(
        _ data: Data,
        remote: RemoteViewPhoto,
        for entry: PhotoEntry
    ) throws {
        let stored = try viewPhotoFileStore.write(data, ownerID: entry.id)
        entry.localViewPhotoFilename = stored.filename
        entry.viewPhotoByteCount = stored.byteCount
        entry.viewPhotoContentHash = stored.contentHash
        entry.viewPhotoModifiedAt = remote.modifiedAt
        invalidateCaches(for: entry)
    }

    func removeLocalViewPhoto(for entry: PhotoEntry) {
        try? viewPhotoFileStore.remove(filename: entry.localViewPhotoFilename)
        entry.localViewPhotoFilename = nil
        invalidateCaches(for: entry)
    }

    func storeConflictOriginal(_ data: Data, for entry: PhotoEntry) throws -> StoredOriginalPhoto {
        let stored = try conflictPhotoFileStore.write(data, ownerID: entry.id)
        invalidateCaches(for: entry)
        return stored
    }

    func removeConflictOriginal(for entry: PhotoEntry) {
        try? conflictPhotoFileStore.remove(filename: entry.originalConflictRemoteFilename)
        entry.originalConflictRemoteFilename = nil
        invalidateCaches(for: entry)
    }

    func makeBackupExportItem(from entries: [PhotoEntry]) throws -> DaymarkBackupExportItem {
        let backupEntries = entries.map { entry in
            DaymarkBackupEntry(
                id: entry.id,
                day: entry.day,
                captureDate: entry.captureDate,
                imageFilename: originalData(for: entry) != nil ? "\(entry.id).jpg" : nil,
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
            guard let imageData = originalData(for: entry) else { continue }
            zipEntries.append(ZipArchive.Entry(path: "images/\(entry.id).jpg", data: imageData))
        }

        return DaymarkBackupExportItem(data: ZipArchive.create(entries: zipEntries))
    }

    func hasEmbeddedLocation(in data: Data) -> Bool {
        locationCoordinate(from: data) != nil
    }

    func savePhotoData(
        _ data: Data,
        for date: Date,
        in modelContext: ModelContext,
        locationOverride: PhotoLocationOverride? = nil
    ) async throws {
        let normalizedDate = normalizedDay(for: date)
        let embeddedLocation = locationCoordinate(from: data)
        let location: CLLocationCoordinate2D? = if let embeddedLocation {
            embeddedLocation
        } else if let locationOverride {
            CLLocationCoordinate2D(latitude: locationOverride.latitude, longitude: locationOverride.longitude)
        } else {
            nil
        }
        let captureDate = captureDate(from: data) ?? date
        let thumbnailData = try thumbnailData(from: data)
        let viewPhotoData = try viewPhotoData(from: data)
        let entry = try existingEntry(for: normalizedDate, in: modelContext) ?? PhotoEntry(day: normalizedDate)
        let oldImageData = entry.imageData
        let oldThumbnailData = entry.thumbnailData
        let oldThumbnailFilename = entry.localThumbnailFilename
        let oldThumbnailByteCount = entry.thumbnailByteCount
        let oldThumbnailContentHash = entry.thumbnailContentHash
        let oldThumbnailModifiedAt = entry.thumbnailModifiedAt
        let oldThumbnailSyncState = entry.thumbnailSyncState
        let oldViewPhotoFilename = entry.localViewPhotoFilename
        let oldViewPhotoByteCount = entry.viewPhotoByteCount
        let oldViewPhotoContentHash = entry.viewPhotoContentHash
        let oldViewPhotoModifiedAt = entry.viewPhotoModifiedAt
        let oldViewPhotoSyncState = entry.viewPhotoSyncState
        let oldImageFilename = entry.imageFilename
        let oldOriginalFilename = entry.localOriginalFilename
        let oldOriginalByteCount = entry.originalByteCount
        let oldOriginalContentHash = entry.originalContentHash
        let oldOriginalSyncState = entry.originalSyncState
        let storedOriginal = try originalFileStore.write(data, ownerID: entry.id)
        let storedThumbnail = try thumbnailFileStore.write(thumbnailData, ownerID: entry.id)
        let storedViewPhoto = try viewPhotoFileStore.write(viewPhotoData, ownerID: entry.id)

        if entry.modelContext == nil {
            modelContext.insert(entry)
        }

        entry.day = normalizedDate
        entry.imageData = nil
        entry.thumbnailData = nil
        entry.localThumbnailFilename = storedThumbnail.filename
        entry.thumbnailByteCount = storedThumbnail.byteCount
        entry.thumbnailContentHash = storedThumbnail.contentHash
        entry.thumbnailModifiedAt = .now
        entry.thumbnailSyncState = .localOnly
        entry.localViewPhotoFilename = storedViewPhoto.filename
        entry.viewPhotoByteCount = storedViewPhoto.byteCount
        entry.viewPhotoContentHash = storedViewPhoto.contentHash
        entry.viewPhotoModifiedAt = .now
        entry.viewPhotoSyncState = .localOnly
        entry.captureDate = captureDate
        entry.imageFilename = nil
        entry.localOriginalFilename = storedOriginal.filename
        entry.originalByteCount = storedOriginal.byteCount
        entry.originalContentHash = storedOriginal.contentHash
        entry.originalSyncState = .localOnly
        entry.latitude = location?.latitude
        entry.longitude = location?.longitude
        entry.timezone = TimeZone.current.identifier
        entry.metadataSyncState = .localOnly

        if let locationOverride, embeddedLocation == nil {
            entry.countryCode = locationOverride.countryCode
            entry.countryName = locationOverride.countryName
            entry.city = locationOverride.city
        } else if let location {
            let details = await reverseGeocodeDetails(for: location)
            entry.countryCode = details.countryCode
            entry.countryName = details.countryName
            entry.city = details.city
        } else {
            entry.countryCode = nil
            entry.countryName = nil
            entry.city = nil
        }

        do {
            try modelContext.save()
        } catch {
            if oldOriginalFilename != storedOriginal.filename {
                try? originalFileStore.remove(filename: storedOriginal.filename)
            }
            if oldThumbnailFilename != storedThumbnail.filename {
                try? thumbnailFileStore.remove(filename: storedThumbnail.filename)
            }
            if oldViewPhotoFilename != storedViewPhoto.filename {
                try? viewPhotoFileStore.remove(filename: storedViewPhoto.filename)
            }
            entry.imageData = oldImageData
            entry.thumbnailData = oldThumbnailData
            entry.localThumbnailFilename = oldThumbnailFilename
            entry.thumbnailByteCount = oldThumbnailByteCount
            entry.thumbnailContentHash = oldThumbnailContentHash
            entry.thumbnailModifiedAt = oldThumbnailModifiedAt
            entry.thumbnailSyncState = oldThumbnailSyncState
            entry.localViewPhotoFilename = oldViewPhotoFilename
            entry.viewPhotoByteCount = oldViewPhotoByteCount
            entry.viewPhotoContentHash = oldViewPhotoContentHash
            entry.viewPhotoModifiedAt = oldViewPhotoModifiedAt
            entry.viewPhotoSyncState = oldViewPhotoSyncState
            entry.imageFilename = oldImageFilename
            entry.localOriginalFilename = oldOriginalFilename
            entry.originalByteCount = oldOriginalByteCount
            entry.originalContentHash = oldOriginalContentHash
            entry.originalSyncState = oldOriginalSyncState
            throw error
        }

        if oldOriginalFilename != storedOriginal.filename {
            try? originalFileStore.remove(filename: oldOriginalFilename)
        }
        if oldThumbnailFilename != storedThumbnail.filename {
            try? thumbnailFileStore.remove(filename: oldThumbnailFilename)
        }
        if oldViewPhotoFilename != storedViewPhoto.filename {
            try? viewPhotoFileStore.remove(filename: oldViewPhotoFilename)
        }
        invalidateCaches(for: entry)
    }

    func saveEditedImage(_ image: UIImage, for entry: PhotoEntry, in modelContext: ModelContext) throws {
        let normalizedImage = image.normalizedImage()
        guard let imageData = normalizedImage.jpegData(compressionQuality: 0.92) else {
            throw PhotoStoreError.invalidImageData
        }
        let newThumbnailData = try thumbnailData(from: imageData)
        let newViewPhotoData = try viewPhotoData(from: imageData)

        let oldImageData = entry.imageData
        let oldThumbnailData = entry.thumbnailData
        let oldThumbnailFilename = entry.localThumbnailFilename
        let oldThumbnailByteCount = entry.thumbnailByteCount
        let oldThumbnailContentHash = entry.thumbnailContentHash
        let oldThumbnailModifiedAt = entry.thumbnailModifiedAt
        let oldThumbnailSyncState = entry.thumbnailSyncState
        let oldViewPhotoFilename = entry.localViewPhotoFilename
        let oldViewPhotoByteCount = entry.viewPhotoByteCount
        let oldViewPhotoContentHash = entry.viewPhotoContentHash
        let oldViewPhotoModifiedAt = entry.viewPhotoModifiedAt
        let oldViewPhotoSyncState = entry.viewPhotoSyncState
        let oldImageFilename = entry.imageFilename
        let oldOriginalFilename = entry.localOriginalFilename
        let oldOriginalByteCount = entry.originalByteCount
        let oldOriginalContentHash = entry.originalContentHash
        let oldOriginalSyncState = entry.originalSyncState
        let storedOriginal = try originalFileStore.write(imageData, ownerID: entry.id)
        let storedThumbnail = try thumbnailFileStore.write(newThumbnailData, ownerID: entry.id)
        let storedViewPhoto = try viewPhotoFileStore.write(newViewPhotoData, ownerID: entry.id)

        entry.imageData = nil
        entry.thumbnailData = nil
        entry.localThumbnailFilename = storedThumbnail.filename
        entry.thumbnailByteCount = storedThumbnail.byteCount
        entry.thumbnailContentHash = storedThumbnail.contentHash
        entry.thumbnailModifiedAt = .now
        entry.thumbnailSyncState = .localOnly
        entry.localViewPhotoFilename = storedViewPhoto.filename
        entry.viewPhotoByteCount = storedViewPhoto.byteCount
        entry.viewPhotoContentHash = storedViewPhoto.contentHash
        entry.viewPhotoModifiedAt = .now
        entry.viewPhotoSyncState = .localOnly
        entry.imageFilename = nil
        entry.localOriginalFilename = storedOriginal.filename
        entry.originalByteCount = storedOriginal.byteCount
        entry.originalContentHash = storedOriginal.contentHash
        entry.originalSyncState = .localOnly

        do {
            try modelContext.save()
        } catch {
            if oldOriginalFilename != storedOriginal.filename {
                try? originalFileStore.remove(filename: storedOriginal.filename)
            }
            if oldThumbnailFilename != storedThumbnail.filename {
                try? thumbnailFileStore.remove(filename: storedThumbnail.filename)
            }
            if oldViewPhotoFilename != storedViewPhoto.filename {
                try? viewPhotoFileStore.remove(filename: storedViewPhoto.filename)
            }
            entry.imageData = oldImageData
            entry.thumbnailData = oldThumbnailData
            entry.localThumbnailFilename = oldThumbnailFilename
            entry.thumbnailByteCount = oldThumbnailByteCount
            entry.thumbnailContentHash = oldThumbnailContentHash
            entry.thumbnailModifiedAt = oldThumbnailModifiedAt
            entry.thumbnailSyncState = oldThumbnailSyncState
            entry.localViewPhotoFilename = oldViewPhotoFilename
            entry.viewPhotoByteCount = oldViewPhotoByteCount
            entry.viewPhotoContentHash = oldViewPhotoContentHash
            entry.viewPhotoModifiedAt = oldViewPhotoModifiedAt
            entry.viewPhotoSyncState = oldViewPhotoSyncState
            entry.imageFilename = oldImageFilename
            entry.localOriginalFilename = oldOriginalFilename
            entry.originalByteCount = oldOriginalByteCount
            entry.originalContentHash = oldOriginalContentHash
            entry.originalSyncState = oldOriginalSyncState
            throw error
        }

        if oldOriginalFilename != storedOriginal.filename {
            try? originalFileStore.remove(filename: oldOriginalFilename)
        }
        if oldThumbnailFilename != storedThumbnail.filename {
            try? thumbnailFileStore.remove(filename: oldThumbnailFilename)
        }
        if oldViewPhotoFilename != storedViewPhoto.filename {
            try? viewPhotoFileStore.remove(filename: oldViewPhotoFilename)
        }
        invalidateCaches(for: entry)
    }

    func deleteEntry(_ entry: PhotoEntry, in modelContext: ModelContext) throws {
        let originalFilename = entry.localOriginalFilename
        let thumbnailFilename = entry.localThumbnailFilename
        let viewPhotoFilename = entry.localViewPhotoFilename
        let conflictPhotoFilename = entry.originalConflictRemoteFilename
        invalidateCaches(for: entry)
        PendingSyncDeletionStore.add(entryID: entry.id)
        modelContext.delete(entry)
        try modelContext.save()
        try? originalFileStore.remove(filename: originalFilename)
        try? thumbnailFileStore.remove(filename: thumbnailFilename)
        try? viewPhotoFileStore.remove(filename: viewPhotoFilename)
        try? conflictPhotoFileStore.remove(filename: conflictPhotoFilename)
        Task.detached(priority: .utility) {
            await SyncDeletionCoordinator().flush()
        }
    }

    func parseBackup(from url: URL) throws -> BackupContents {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        if data.count >= 2 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B {
            let zipEntries = try ZipArchive.index(from: data)

            guard let jsonEntry = zipEntries.first(where: { $0.path == "entries.json" }) else {
                throw BackupError.missingEntriesJSON
            }

            let payload: DaymarkBackupPayload
            do {
                payload = try decodedBackupPayload(from: data.subdata(in: jsonEntry.dataRange))
            } catch {
                throw BackupError.invalidEntriesJSON
            }

            var imageRanges: [String: Range<Int>] = [:]
            for entry in zipEntries where entry.path.hasPrefix("images/") {
                let filename = String(entry.path.dropFirst("images/".count))
                guard !filename.isEmpty else { continue }
                imageRanges[filename] = entry.dataRange
            }

            return BackupContents(
                payload: payload,
                archiveData: data,
                imageRanges: imageRanges
            )
        }

        let payload: DaymarkBackupPayload
        do {
            payload = try decodedBackupPayload(from: data)
        } catch {
            throw BackupError.invalidEntriesJSON
        }
        return BackupContents(payload: payload)
    }

    func importBackup(
        from contents: BackupContents,
        mode: BackupImportMode,
        into modelContext: ModelContext
    ) async throws {
        var replacedOriginalFilenames: [String] = []

        do {
            for (index, backupEntry) in contents.payload.entries.enumerated() {
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
                entry.metadataSyncState = .localOnly

                if let filename = backupEntry.imageFilename,
                   let imageData = contents.imageData(named: filename) {
                    let storedPhotos = try autoreleasepool {
                        let original = try originalFileStore.write(imageData, ownerID: entry.id)
                        let generatedThumbnail = try thumbnailData(from: imageData)
                        let thumbnail = try thumbnailFileStore.write(generatedThumbnail, ownerID: entry.id)
                        let generatedViewPhoto = try viewPhotoData(from: imageData)
                        let viewPhoto = try viewPhotoFileStore.write(generatedViewPhoto, ownerID: entry.id)
                        return (original, thumbnail, viewPhoto)
                    }
                    trackReplacement(
                        oldFilename: entry.localOriginalFilename,
                        newFilename: storedPhotos.0.filename,
                        replaced: &replacedOriginalFilenames
                    )
                    entry.imageData = nil
                    try? thumbnailFileStore.remove(filename: entry.localThumbnailFilename)
                    entry.thumbnailData = nil
                    entry.localThumbnailFilename = storedPhotos.1.filename
                    entry.thumbnailByteCount = storedPhotos.1.byteCount
                    entry.thumbnailContentHash = storedPhotos.1.contentHash
                    entry.thumbnailModifiedAt = .now
                    entry.thumbnailSyncState = .localOnly
                    try? viewPhotoFileStore.remove(filename: entry.localViewPhotoFilename)
                    entry.localViewPhotoFilename = storedPhotos.2.filename
                    entry.viewPhotoByteCount = storedPhotos.2.byteCount
                    entry.viewPhotoContentHash = storedPhotos.2.contentHash
                    entry.viewPhotoModifiedAt = .now
                    entry.viewPhotoSyncState = .localOnly
                    entry.localOriginalFilename = storedPhotos.0.filename
                    entry.originalByteCount = storedPhotos.0.byteCount
                    entry.originalContentHash = storedPhotos.0.contentHash
                    entry.originalSyncState = .localOnly
                } else if let legacyImageData = backupEntry.legacyImageData {
                    let storedOriginal = try originalFileStore.write(legacyImageData, ownerID: entry.id)
                    let generatedThumbnailData = try (
                        backupEntry.legacyThumbnailData
                            ?? thumbnailData(from: legacyImageData)
                    )
                    let storedThumbnail = try thumbnailFileStore.write(generatedThumbnailData, ownerID: entry.id)
                    let generatedViewPhotoData = try viewPhotoData(from: legacyImageData)
                    let storedViewPhoto = try viewPhotoFileStore.write(generatedViewPhotoData, ownerID: entry.id)
                    trackReplacement(
                        oldFilename: entry.localOriginalFilename,
                        newFilename: storedOriginal.filename,
                        replaced: &replacedOriginalFilenames
                    )
                    entry.imageData = nil
                    try? thumbnailFileStore.remove(filename: entry.localThumbnailFilename)
                    entry.thumbnailData = nil
                    entry.localThumbnailFilename = storedThumbnail.filename
                    entry.thumbnailByteCount = storedThumbnail.byteCount
                    entry.thumbnailContentHash = storedThumbnail.contentHash
                    entry.thumbnailModifiedAt = .now
                    entry.thumbnailSyncState = .localOnly
                    try? viewPhotoFileStore.remove(filename: entry.localViewPhotoFilename)
                    entry.localViewPhotoFilename = storedViewPhoto.filename
                    entry.viewPhotoByteCount = storedViewPhoto.byteCount
                    entry.viewPhotoContentHash = storedViewPhoto.contentHash
                    entry.viewPhotoModifiedAt = .now
                    entry.viewPhotoSyncState = .localOnly
                    entry.localOriginalFilename = storedOriginal.filename
                    entry.originalByteCount = storedOriginal.byteCount
                    entry.originalContentHash = storedOriginal.contentHash
                    entry.originalSyncState = .localOnly
                }

                invalidateCaches(for: entry)

                if (index + 1).isMultiple(of: 5) {
                    try modelContext.save()
                }
                await Task.yield()
            }

            try modelContext.save()
        } catch {
            throw error
        }

        for filename in replacedOriginalFilenames {
            try? originalFileStore.remove(filename: filename)
        }
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

    @discardableResult
    func consolidateDuplicateDays(
        for entries: [PhotoEntry],
        in modelContext: ModelContext
    ) throws -> Int {
        let groups = Dictionary(grouping: entries) { normalizedDay(for: $0.day) }
        var removedCount = 0

        for (day, duplicates) in groups where duplicates.count > 1 {
            let ordered = duplicates.sorted {
                duplicateRetentionScore(for: $0) > duplicateRetentionScore(for: $1)
            }
            guard let keeper = ordered.first else { continue }

            keeper.day = day
            for duplicate in ordered.dropFirst() {
                mergeMissingValues(from: duplicate, into: keeper)
                modelContext.delete(duplicate)
                removedCount += 1
            }
            keeper.metadataSyncState = .localOnly
        }

        if removedCount > 0 {
            try modelContext.save()
        }
        return removedCount
    }

    private func duplicateRetentionScore(for entry: PhotoEntry) -> Int {
        var score = 0
        if entry.localOriginalFilename != nil { score += 1_000 }
        if entry.originalContentHash != nil { score += 100 }
        if entry.localViewPhotoFilename != nil { score += 50 }
        if entry.localThumbnailFilename != nil { score += 20 }
        if entry.imageData != nil { score += 10 }
        if entry.thumbnailData != nil { score += 5 }
        if entry.captureDate != nil { score += 1 }
        if entry.latitude != nil { score += 1 }
        if entry.longitude != nil { score += 1 }
        if entry.timezone != nil { score += 1 }
        if entry.countryCode != nil { score += 1 }
        if entry.countryName != nil { score += 1 }
        if entry.city != nil { score += 1 }
        if entry.caption != nil { score += 1 }
        return score
    }

    private func mergeMissingValues(from source: PhotoEntry, into destination: PhotoEntry) {
        destination.imageData = destination.imageData ?? source.imageData
        destination.thumbnailData = destination.thumbnailData ?? source.thumbnailData
        destination.captureDate = destination.captureDate ?? source.captureDate
        destination.imageFilename = destination.imageFilename ?? source.imageFilename
        destination.localOriginalFilename =
            destination.localOriginalFilename ?? source.localOriginalFilename
        destination.localThumbnailFilename =
            destination.localThumbnailFilename ?? source.localThumbnailFilename
        destination.localViewPhotoFilename =
            destination.localViewPhotoFilename ?? source.localViewPhotoFilename
        destination.originalByteCount =
            destination.originalByteCount ?? source.originalByteCount
        destination.originalContentHash =
            destination.originalContentHash ?? source.originalContentHash
        destination.originalLastSyncedHash =
            destination.originalLastSyncedHash ?? source.originalLastSyncedHash
        destination.thumbnailByteCount =
            destination.thumbnailByteCount ?? source.thumbnailByteCount
        destination.thumbnailContentHash =
            destination.thumbnailContentHash ?? source.thumbnailContentHash
        destination.thumbnailModifiedAt =
            destination.thumbnailModifiedAt ?? source.thumbnailModifiedAt
        destination.viewPhotoByteCount =
            destination.viewPhotoByteCount ?? source.viewPhotoByteCount
        destination.viewPhotoContentHash =
            destination.viewPhotoContentHash ?? source.viewPhotoContentHash
        destination.viewPhotoModifiedAt =
            destination.viewPhotoModifiedAt ?? source.viewPhotoModifiedAt
        destination.latitude = destination.latitude ?? source.latitude
        destination.longitude = destination.longitude ?? source.longitude
        destination.timezone = destination.timezone ?? source.timezone
        destination.countryCode = destination.countryCode ?? source.countryCode
        destination.countryName = destination.countryName ?? source.countryName
        destination.city = destination.city ?? source.city
        destination.caption = destination.caption ?? source.caption
        destination.metadataVersionData =
            destination.metadataVersionData ?? source.metadataVersionData
        destination.metadataBaselineData =
            destination.metadataBaselineData ?? source.metadataBaselineData

        if destination.thumbnailSyncState == .untracked {
            destination.thumbnailSyncState = source.thumbnailSyncState
        }
        if destination.viewPhotoSyncState == .untracked {
            destination.viewPhotoSyncState = source.viewPhotoSyncState
        }
        if destination.originalSyncState == .untracked {
            destination.originalSyncState = source.originalSyncState
        }
    }

    func migrateEmbeddedThumbnails(
        for entries: [PhotoEntry],
        in modelContext: ModelContext
    ) {
        var didUpdate = false

        for entry in entries {
            if let embeddedData = entry.thumbnailData {
                guard let stored = try? thumbnailFileStore.write(embeddedData, ownerID: entry.id) else {
                    continue
                }
                entry.thumbnailData = nil
                entry.localThumbnailFilename = stored.filename
                entry.thumbnailByteCount = stored.byteCount
                entry.thumbnailContentHash = stored.contentHash
                entry.thumbnailModifiedAt = entry.thumbnailModifiedAt ?? .now
                if entry.thumbnailSyncState == .untracked {
                    entry.thumbnailSyncState = .localOnly
                }
                didUpdate = true
                invalidateCaches(for: entry)
                continue
            }

            guard thumbnailData(for: entry) == nil,
                  let originalData = originalData(for: entry),
                  let generatedData = try? thumbnailData(from: originalData),
                  let stored = try? thumbnailFileStore.write(generatedData, ownerID: entry.id) else {
                continue
            }
            entry.localThumbnailFilename = stored.filename
            entry.thumbnailByteCount = stored.byteCount
            entry.thumbnailContentHash = stored.contentHash
            entry.thumbnailModifiedAt = entry.thumbnailModifiedAt ?? .now
            entry.thumbnailSyncState = .localOnly
            didUpdate = true
            invalidateCaches(for: entry)
        }

        if didUpdate {
            try? modelContext.save()
        }
    }

    func backfillViewPhotos(
        for entries: [PhotoEntry],
        in modelContext: ModelContext
    ) async {
        var didUpdate = false
        var generatedCount = 0

        #if DEBUG
        print("DAYMARK_VIEW_BACKFILL_START entries=\(entries.count)")
        #endif

        for entry in entries {
            if let data = viewPhotoData(for: entry) {
                if entry.viewPhotoByteCount == nil {
                    entry.viewPhotoByteCount = Int64(data.count)
                    didUpdate = true
                }
                continue
            }

            guard let originalData = originalData(for: entry) else {
                continue
            }
            let stored: StoredViewPhoto? = autoreleasepool {
                guard let generatedData = try? viewPhotoData(from: originalData) else {
                    return nil
                }
                return try? viewPhotoFileStore.write(generatedData, ownerID: entry.id)
            }
            guard let stored else { continue }

            entry.localViewPhotoFilename = stored.filename
            entry.viewPhotoByteCount = stored.byteCount
            entry.viewPhotoContentHash = stored.contentHash
            entry.viewPhotoModifiedAt = entry.viewPhotoModifiedAt ?? .now
            entry.viewPhotoSyncState = .localOnly
            didUpdate = true
            generatedCount += 1
            invalidateCaches(for: entry)

            if generatedCount.isMultiple(of: 10) {
                try? modelContext.save()
            }
            #if DEBUG
            if generatedCount.isMultiple(of: 25) {
                print("DAYMARK_VIEW_BACKFILL_PROGRESS generated=\(generatedCount)")
            }
            #endif
            await Task.yield()
        }

        if didUpdate {
            try? modelContext.save()
        }
        #if DEBUG
        print("DAYMARK_VIEW_BACKFILL_DONE generated=\(generatedCount)")
        #endif
    }

    func backfillLocationDetails(for entries: [PhotoEntry], in modelContext: ModelContext) async {
        let needsNormalization = !UserDefaults.standard.bool(forKey: "locationNamesNormalizedToEnglish")
        var didUpdate = false
        for entry in entries {
            guard let lat = entry.latitude, let lon = entry.longitude else { continue }

            let needsBackfill = entry.countryCode == nil || entry.countryName == nil || entry.city == nil
            guard needsBackfill || needsNormalization else { continue }

            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let details = await reverseGeocodeDetails(for: coordinate)
            if entry.countryCode != details.countryCode || entry.countryName != details.countryName || entry.city != details.city {
                entry.countryCode = details.countryCode ?? entry.countryCode
                entry.countryName = details.countryName ?? entry.countryName
                entry.city = details.city ?? entry.city
                didUpdate = true
            }
        }
        if needsNormalization {
            UserDefaults.standard.set(true, forKey: "locationNamesNormalizedToEnglish")
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

        for entry in entries where entry.imageData == nil && entry.localOriginalFilename == nil {
            guard let filename = entry.imageFilename else { continue }
            let fileURL = legacyFileURL(filename: filename)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                allLegacyFilesWereMigrated = false
                continue
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let storedOriginal = try originalFileStore.write(data, ownerID: entry.id)
                let generatedThumbnailData = try thumbnailData(from: data)
                let storedThumbnail = try thumbnailFileStore.write(generatedThumbnailData, ownerID: entry.id)
                let generatedViewPhotoData = try viewPhotoData(from: data)
                let storedViewPhoto = try viewPhotoFileStore.write(generatedViewPhotoData, ownerID: entry.id)
                entry.imageData = nil
                entry.thumbnailData = nil
                entry.localThumbnailFilename = storedThumbnail.filename
                entry.thumbnailByteCount = storedThumbnail.byteCount
                entry.thumbnailContentHash = storedThumbnail.contentHash
                entry.thumbnailModifiedAt = .now
                entry.thumbnailSyncState = .localOnly
                entry.localViewPhotoFilename = storedViewPhoto.filename
                entry.viewPhotoByteCount = storedViewPhoto.byteCount
                entry.viewPhotoContentHash = storedViewPhoto.contentHash
                entry.viewPhotoModifiedAt = .now
                entry.viewPhotoSyncState = .localOnly
                entry.captureDate = entry.captureDate ?? captureDate(from: data) ?? entry.day
                entry.localOriginalFilename = storedOriginal.filename
                entry.originalByteCount = storedOriginal.byteCount
                entry.originalContentHash = storedOriginal.contentHash
                entry.originalSyncState = .localOnly

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
            do {
                try modelContext.save()
            } catch {
                allLegacyFilesWereMigrated = false
            }
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
        let filename: String
        switch suffix {
        case "thumb":
            filename = entry.localThumbnailFilename ?? "legacy"
        case "view":
            filename = entry.localViewPhotoFilename ?? entry.localOriginalFilename ?? "legacy"
        default:
            filename = entry.localOriginalFilename ?? "legacy"
        }
        return "\(entry.id)-\(filename)-\(suffix)" as NSString
    }

    private func invalidateCaches(for entry: PhotoEntry) {
        imageCache.removeObject(forKey: cacheKey(for: entry, suffix: "full"))
        imageCache.removeObject(forKey: cacheKey(for: entry, suffix: "view"))
        thumbnailCache.removeObject(forKey: cacheKey(for: entry, suffix: "thumb"))
    }

    private func legacyFileURL(filename: String) -> URL {
        legacyPhotosDirectoryURL.appendingPathComponent(filename)
    }

    private func removeLegacyPhotosDirectoryIfPossible() {
        guard fileManager.fileExists(atPath: legacyPhotosDirectoryURL.path) else { return }
        try? fileManager.removeItem(at: legacyPhotosDirectoryURL)
    }

    private func trackReplacement(
        oldFilename: String?,
        newFilename: String,
        replaced: inout [String]
    ) {
        guard oldFilename != newFilename else { return }
        if let oldFilename {
            replaced.append(oldFilename)
        }
    }

    private func thumbnailData(from data: Data) throws -> Data {
        try renditionData(
            from: data,
            maxPixelSize: Thumbnail.maxPixelSize,
            compressionQuality: Thumbnail.compressionQuality
        )
    }

    private func viewPhotoData(from data: Data) throws -> Data {
        try renditionData(
            from: data,
            maxPixelSize: ViewPhoto.maxPixelSize,
            compressionQuality: ViewPhoto.compressionQuality
        )
    }

    private func renditionData(
        from data: Data,
        maxPixelSize: Double,
        compressionQuality: CGFloat
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoStoreError.invalidImageData
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoStoreError.invalidImageData
        }

        let image = UIImage(cgImage: cgImage)
        guard let thumbnailData = image.jpegData(compressionQuality: compressionQuality) else {
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
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return (nil, nil, nil)
        }
        request.preferredLocale = Locale(identifier: "en")
        guard let mapItem = try? await request.mapItems.first else {
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

struct StoredOriginalPhoto {
    let filename: String
    let byteCount: Int64
    let contentHash: String
}

typealias StoredThumbnailPhoto = StoredOriginalPhoto
typealias StoredViewPhoto = StoredOriginalPhoto
typealias StoredConflictPhoto = StoredOriginalPhoto

struct OriginalPhotoFileStore {
    private let fileManager: FileManager
    let directoryURL: URL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Daymark", isDirectory: true)
        .appendingPathComponent("Originals", isDirectory: true)
    }

    func write(_ data: Data, ownerID: String) throws -> StoredOriginalPhoto {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        let contentHash = Self.hash(data)
        let ownerHash = Self.hash(Data(ownerID.utf8))
        let filename = "\(ownerHash.prefix(16))-\(contentHash).image"
        let fileURL = try url(for: filename)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        return StoredOriginalPhoto(
            filename: filename,
            byteCount: Int64(data.count),
            contentHash: contentHash
        )
    }

    func read(filename: String) throws -> Data {
        try Data(contentsOf: url(for: filename), options: [.mappedIfSafe])
    }

    func remove(filename: String?) throws {
        guard let filename else { return }
        let fileURL = try url(for: filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func url(for filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".image") else {
            throw OriginalPhotoFileStoreError.invalidFilename
        }
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ThumbnailPhotoFileStore {
    private let fileManager: FileManager
    let directoryURL: URL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Daymark", isDirectory: true)
        .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    func write(_ data: Data, ownerID: String) throws -> StoredThumbnailPhoto {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        let contentHash = hash(data)
        let ownerHash = hash(Data(ownerID.utf8))
        let filename = "\(ownerHash.prefix(16))-\(contentHash).thumb"
        let fileURL = try url(for: filename)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return StoredThumbnailPhoto(
            filename: filename,
            byteCount: Int64(data.count),
            contentHash: contentHash
        )
    }

    func read(filename: String) throws -> Data {
        try Data(contentsOf: url(for: filename), options: [.mappedIfSafe])
    }

    func remove(filename: String?) throws {
        guard let filename else { return }
        let fileURL = try url(for: filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func url(for filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".thumb") else {
            throw OriginalPhotoFileStoreError.invalidFilename
        }
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ViewPhotoFileStore {
    private let fileManager: FileManager
    let directoryURL: URL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Daymark", isDirectory: true)
        .appendingPathComponent("ViewPhotos", isDirectory: true)
    }

    func write(_ data: Data, ownerID: String) throws -> StoredViewPhoto {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        let contentHash = hash(data)
        let ownerHash = hash(Data(ownerID.utf8))
        let filename = "\(ownerHash.prefix(16))-\(contentHash).view"
        let fileURL = try url(for: filename)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return StoredViewPhoto(
            filename: filename,
            byteCount: Int64(data.count),
            contentHash: contentHash
        )
    }

    func read(filename: String) throws -> Data {
        try Data(contentsOf: url(for: filename), options: [.mappedIfSafe])
    }

    func remove(filename: String?) throws {
        guard let filename else { return }
        let fileURL = try url(for: filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func url(for filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".view") else {
            throw OriginalPhotoFileStoreError.invalidFilename
        }
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ConflictPhotoFileStore {
    private let fileManager: FileManager
    let directoryURL: URL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Daymark", isDirectory: true)
        .appendingPathComponent("ConflictPhotos", isDirectory: true)
    }

    func write(_ data: Data, ownerID: String) throws -> StoredConflictPhoto {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let contentHash = hash(data)
        let ownerHash = hash(Data(ownerID.utf8))
        let filename = "\(ownerHash.prefix(16))-\(contentHash).conflict"
        let fileURL = try url(for: filename)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        return StoredConflictPhoto(
            filename: filename,
            byteCount: Int64(data.count),
            contentHash: contentHash
        )
    }

    func read(filename: String) throws -> Data {
        try Data(contentsOf: url(for: filename), options: [.mappedIfSafe])
    }

    func remove(filename: String?) throws {
        guard let filename else { return }
        let fileURL = try url(for: filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func url(for filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".conflict") else {
            throw OriginalPhotoFileStoreError.invalidFilename
        }
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum OriginalPhotoFileStoreError: Error {
    case invalidFilename
}

struct PhotoLocationOverride {
    let latitude: Double
    let longitude: Double
    let city: String?
    let countryCode: String?
    let countryName: String?
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

    struct IndexedEntry {
        let path: String
        let dataRange: Range<Int>
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

    static func index(from data: Data) throws -> [IndexedEntry] {
        guard data.count >= 22 else { throw BackupError.invalidArchive }

        var eocdOffset = data.count - 22
        while eocdOffset >= 0 {
            if data.readZipUInt32(at: eocdOffset) == 0x06054b50 { break }
            eocdOffset -= 1
        }
        guard eocdOffset >= 0 else { throw BackupError.invalidArchive }

        let entryCount = Int(data.readZipUInt16(at: eocdOffset + 10))
        let centralDirOffset = Int(data.readZipUInt32(at: eocdOffset + 16))

        var entries: [IndexedEntry] = []
        var offset = centralDirOffset

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  data.readZipUInt32(at: offset) == 0x02014b50 else {
                throw BackupError.invalidArchive
            }

            // Only "stored" (method 0) entries are supported; re-zipped archives use deflate.
            guard data.readZipUInt16(at: offset + 10) == 0 else {
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

            entries.append(
                IndexedEntry(
                    path: name,
                    dataRange: dataStart..<(dataStart + compressedSize)
                )
            )
            offset = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    static func read(from data: Data) throws -> [Entry] {
        try index(from: data).map {
            Entry(path: $0.path, data: data.subdata(in: $0.dataRange))
        }
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

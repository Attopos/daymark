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

nonisolated struct BackupContents: Sendable {
    let payload: DaymarkBackupPayload
    fileprivate let archiveData: Data?
    fileprivate let imageRanges: [String: Range<Int>]
    var workingDirectory: URL? = nil
    var legacyReport = LegacyRestoreReport()

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
        if let workingDirectory, BackupArchiveReader.isSafeFilename(filename) {
            return try? Data(contentsOf: workingDirectory.appendingPathComponent("images").appendingPathComponent(filename), options: .mappedIfSafe)
        }
        guard let archiveData, let range = imageRanges[filename] else { return nil }
        return archiveData.subdata(in: range)
    }

    func cleanUp() {
        if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
    }
}

nonisolated enum BackupError: LocalizedError {
    case invalidArchive
    case missingEntriesJSON
    case invalidEntriesJSON
    case unsupportedVersion(Int)
    case missingOriginal(String)
    case damagedPhoto(String)
    case duplicateDay
    case libraryChanged
    case insufficientSpace
    case unresolvedConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The file is not a valid backup archive."
        case .missingEntriesJSON: return "The archive does not contain entries.json."
        case .invalidEntriesJSON: return "Could not read backup metadata."
        case .unsupportedVersion(let version): return "Backup version \(version) is not supported. Update Daymark before importing it."
        case .missingOriginal(let day): return "The original photo for \(day) is unavailable. Connect to iCloud and retry. No incomplete backup was exported."
        case .damagedPhoto(let name): return "The photo \(name) is missing or failed verification. Your library has not been replaced."
        case .duplicateDay: return "More than one record has the same day. Resolve the duplicate days before continuing."
        case .libraryChanged: return "The library changed during this operation. Please retry."
        case .insufficientSpace: return "There is not enough free space to prepare this backup. Free up storage and retry."
        case .unresolvedConflict(let day): return "Resolve the original-photo conflict for \(day) in iCloud Sync before exporting."
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
    private let legacyDirectoryOverride: URL?
    private let flushPendingDeletions: @Sendable () async -> Void
    private let exifDateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private nonisolated enum Thumbnail {
        static let maxPixelSize = 300.0
        static let compressionQuality = 0.82
    }

    private nonisolated enum ViewPhoto {
        static let maxPixelSize = 2_048.0
        static let compressionQuality = 0.88
    }

    init(
        originalsDirectoryURL: URL? = nil,
        thumbnailsDirectoryURL: URL? = nil,
        viewPhotosDirectoryURL: URL? = nil,
        conflictPhotosDirectoryURL: URL? = nil,
        legacyPhotosDirectoryURL: URL? = nil,
        flushPendingDeletions: @escaping @Sendable () async -> Void = {
            await SyncDeletionCoordinator().flush()
        }
    ) {
        originalFileStore = OriginalPhotoFileStore(directoryURL: originalsDirectoryURL)
        thumbnailFileStore = ThumbnailPhotoFileStore(directoryURL: thumbnailsDirectoryURL)
        viewPhotoFileStore = ViewPhotoFileStore(directoryURL: viewPhotosDirectoryURL)
        conflictPhotoFileStore = ConflictPhotoFileStore(directoryURL: conflictPhotosDirectoryURL)
        legacyDirectoryOverride = legacyPhotosDirectoryURL
        self.flushPendingDeletions = flushPendingDeletions
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
        if let data = entry.imageData { return data }
        if let filename = entry.imageFilename,
           BackupArchiveReader.isSafeFilename(filename) {
            return try? Data(contentsOf: legacyFileURL(filename: filename), options: .mappedIfSafe)
        }
        return nil
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

    /// Reads all historical storage forms directly; exporting never depends on
    /// the launch migration having finished and never uploads to iCloud.
    func makeBackupExportItem(
        from entries: [PhotoEntry],
        in modelContext: ModelContext,
        allowCloudDownload: Bool,
        remoteStore: (any OriginalPhotoRemoteStore)? = nil,
        progress: @escaping (Int, Int, String) -> Void = { _, _, _ in }
    ) async throws -> DaymarkBackupExportItem {
        try modelContext.save()
        let snapshots = entries.map(backupEntry)
        var sourceRevisions = entries.map(originalRevision)
        try BackupArchiveReader.validateMetadata(DaymarkBackupPayload(version: 3, exportedAt: .now, entries: snapshots))
        let writer = try BackupArchiveWriter()
        var cloud = remoteStore
        var inventory: [String: RemoteOriginalPhoto]?
        var exportedEntries: [DaymarkBackupEntry] = []
        do {
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard entry.modelContext != nil, !entry.isDeleted,
                      backupEntry(entry) == snapshots[index], originalRevision(entry) == sourceRevisions[index] else { throw BackupError.libraryChanged }
                let day = snapshots[index].dayKey ?? entry.day.formatted(date: .abbreviated, time: .omitted)
                if entry.originalSyncState == .conflict {
                    throw BackupError.unresolvedConflict(day)
                }
                progress(index, entries.count, "Preparing \(index + 1) of \(entries.count)…")
                var data = originalData(for: entry)
                if data == nil && allowCloudDownload {
                    progress(index, entries.count, "Downloading original for \(day) from iCloud…")
                    if cloud == nil { cloud = CloudKitOriginalPhotoStore() }
                    if inventory == nil { inventory = try await cloud?.inventory() }
                    if let remote = inventory?[entry.id], let cloud {
                        if let expectedHash = entry.originalContentHash, expectedHash != remote.contentHash {
                            throw BackupError.unresolvedConflict(day)
                        }
                        let downloaded = try await cloud.download(entryID: entry.id)
                        try Task.checkCancellation()
                        guard entry.modelContext != nil, !entry.isDeleted,
                              backupEntry(entry) == snapshots[index], originalRevision(entry) == sourceRevisions[index], originalData(for: entry) == nil else {
                            throw BackupError.libraryChanged
                        }
                        guard BackupArchiveReader.hash(downloaded) == remote.contentHash,
                              Int64(downloaded.count) == remote.byteCount else {
                            throw BackupError.damagedPhoto(day)
                        }
                        try storeDownloadedOriginal(downloaded, for: entry)
                        entry.originalLastSyncedHash = remote.contentHash
                        entry.originalSyncState = .synced
                        try modelContext.save()
                        data = downloaded
                        sourceRevisions[index] = originalRevision(entry)
                    }
                }
                guard let data else { throw BackupError.missingOriginal(day) }
                var metadata = snapshots[index]
                metadata = try await writer.addPhoto(data, metadata: metadata, index: index)
                if let expected = entry.originalContentHash, expected != metadata.imageSHA256 {
                    throw BackupError.damagedPhoto(day)
                }
                exportedEntries.append(metadata)
                progress(index + 1, entries.count, "Prepared \(index + 1) of \(entries.count) photos")
            }
            try Task.checkCancellation()
            let currentEntries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
            guard Set(currentEntries.map(\.id)) == Set(entries.map(\.id)),
                  entries.enumerated().allSatisfy({ !$0.element.isDeleted && backupEntry($0.element) == snapshots[$0.offset] && originalRevision($0.element) == sourceRevisions[$0.offset] }) else {
                throw BackupError.libraryChanged
            }
            progress(entries.count, entries.count, "Verifying backup…")
            let result = try await writer.finish(entries: exportedEntries)
            return DaymarkBackupExportItem(url: result.url, entryCount: entries.count, byteCount: result.byteCount)
        } catch {
            await writer.cancel()
            throw error
        }
    }

    private func backupEntry(_ entry: PhotoEntry) -> DaymarkBackupEntry {
        var snapshot = DaymarkBackupEntry(
            id: entry.id, day: entry.day, captureDate: entry.captureDate, imageFilename: nil,
            latitude: entry.latitude, longitude: entry.longitude, timezone: entry.timezone,
            countryCode: entry.countryCode, countryName: entry.countryName, city: entry.city, caption: entry.caption
        )
        snapshot.dayKey = BackupCalendar.dayKey(for: entry.day)
        return snapshot
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
        let (thumbnailData, viewPhotoData) = try await renditions(from: data)
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
        Task.detached(priority: .utility) { [flushPendingDeletions] in
            await flushPendingDeletions()
        }
    }

    /// Removes leaked debug/test sentinel entries (dated year 2100+). They are
    /// deleted through the normal path so the deletion propagates to CloudKit
    /// and is tombstoned, preventing the sync systems from resurrecting them.
    /// Returns the number purged so callers can skip redundant work.
    @discardableResult
    func purgeSentinelEntries(in modelContext: ModelContext) -> Int {
        let cutoff = PhotoEntry.sentinelDayCutoff
        let descriptor = FetchDescriptor<PhotoEntry>(
            predicate: #Predicate { $0.day >= cutoff }
        )
        guard let sentinels = try? modelContext.fetch(descriptor), !sentinels.isEmpty else {
            return 0
        }
        for entry in sentinels {
            try? deleteEntry(entry, in: modelContext)
        }
        return sentinels.count
    }

    func deleteAllEntries(in modelContext: ModelContext) throws {
        let entries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
        guard !entries.isEmpty else { return }

        var originalFilenames: [String] = []
        var thumbnailFilenames: [String] = []
        var viewPhotoFilenames: [String] = []
        var conflictPhotoFilenames: [String] = []

        for entry in entries {
            if let filename = entry.localOriginalFilename {
                originalFilenames.append(filename)
            }
            if let filename = entry.localThumbnailFilename {
                thumbnailFilenames.append(filename)
            }
            if let filename = entry.localViewPhotoFilename {
                viewPhotoFilenames.append(filename)
            }
            if let filename = entry.originalConflictRemoteFilename {
                conflictPhotoFilenames.append(filename)
            }

            invalidateCaches(for: entry)
            PendingSyncDeletionStore.add(entryID: entry.id)
            modelContext.delete(entry)
        }

        try modelContext.save()

        for filename in originalFilenames {
            try? originalFileStore.remove(filename: filename)
        }
        for filename in thumbnailFilenames {
            try? thumbnailFileStore.remove(filename: filename)
        }
        for filename in viewPhotoFilenames {
            try? viewPhotoFileStore.remove(filename: filename)
        }
        for filename in conflictPhotoFilenames {
            try? conflictPhotoFileStore.remove(filename: filename)
        }

        Task.detached(priority: .utility) { [flushPendingDeletions] in
            await flushPendingDeletions()
        }
    }

    func parseBackup(from url: URL) throws -> BackupContents {
        try BackupArchiveReader.read(from: url)
    }

    @discardableResult
    func importBackup(
        from contents: BackupContents,
        mode: BackupImportMode,
        into modelContext: ModelContext,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> BackupImportSummary {
        try BackupArchiveReader.validateMetadata(contents.payload)
        try modelContext.save()
        let initialEntries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
        let initialMetadata = initialEntries.map(backupEntry)
        let initialSources = initialEntries.map(originalRevision)
        var byDay: [Date: PhotoEntry] = [:]
        for entry in initialEntries { byDay[normalizedDay(for: entry.day)] = entry }
        // An old identity can still be targeted by an in-flight cloud delete.
        // Give a newly restored entry a fresh identity until that delete ends.
        var usedIDs = Set(initialEntries.map(\.id)).union(PendingSyncDeletionStore.pendingEntryIDs())
        let oldOriginals = Set(initialEntries.compactMap(\.localOriginalFilename))
        let oldThumbnails = Set(initialEntries.compactMap(\.localThumbnailFilename))
        let oldViews = Set(initialEntries.compactMap(\.localViewPhotoFilename))
        var newOriginals = Set<String>(), newThumbnails = Set<String>(), newViews = Set<String>()
        var replacedOriginals = Set<String>(), replacedThumbnails = Set<String>(), replacedViews = Set<String>()
        struct PreparedPhoto {
            let metadata: DaymarkBackupEntry
            let day: Date
            let id: String
            let existing: PhotoEntry?
            let original: StoredOriginalPhoto
            let thumbnail: StoredThumbnailPhoto
            let view: StoredViewPhoto
        }
        var prepared: [PreparedPhoto] = []
        var skipped = 0
        var didStartApplying = false
        let autosave = modelContext.autosaveEnabled
        defer { modelContext.autosaveEnabled = autosave }
        do {
            // Generate and validate every asset before replacing any library entry.
            for (index, metadata) in contents.payload.entries.enumerated() {
                try Task.checkCancellation()
                let day = try BackupCalendar.restoredDay(metadata)
                let existing = byDay[day]
                if mode == .merge && existing != nil {
                    skipped += 1
                    progress(index + 1, contents.payload.entries.count)
                    continue
                }
                let id: String
                if let existing { id = existing.id }
                else if let backupID = metadata.id, !usedIDs.contains(backupID) { id = backupID }
                else { id = UUID().uuidString }
                usedIDs.insert(id)
                try autoreleasepool {
                    guard let data = metadata.imageFilename.flatMap({ contents.imageData(named: $0) }) ?? metadata.legacyImageData else {
                        throw BackupError.damagedPhoto(metadata.dayKey ?? metadata.day.description)
                    }
                    if let expected = metadata.imageSHA256, BackupArchiveReader.hash(data) != expected {
                        throw BackupError.damagedPhoto(metadata.imageFilename ?? id)
                    }
                    let thumbnailData = try thumbnailData(from: data)
                    let viewData = try viewPhotoData(from: data)
                    let original = try originalFileStore.write(data, ownerID: id)
                    newOriginals.insert(original.filename)
                    let thumbnail = try thumbnailFileStore.write(thumbnailData, ownerID: id)
                    newThumbnails.insert(thumbnail.filename)
                    let view = try viewPhotoFileStore.write(viewData, ownerID: id)
                    newViews.insert(view.filename)
                    prepared.append(PreparedPhoto(metadata: metadata, day: day, id: id, existing: existing,
                                                  original: original, thumbnail: thumbnail, view: view))
                }
                progress(index + 1, contents.payload.entries.count)
                await Task.yield()
            }
            try Task.checkCancellation()
            let currentEntries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
            guard Set(currentEntries.map(\.id)) == Set(initialEntries.map(\.id)),
                  initialEntries.enumerated().allSatisfy({ !$0.element.isDeleted && backupEntry($0.element) == initialMetadata[$0.offset] && originalRevision($0.element) == initialSources[$0.offset] }) else {
                throw BackupError.libraryChanged
            }
            modelContext.autosaveEnabled = false
            didStartApplying = true
            // This section does not suspend: commit all metadata in one save.
            for photo in prepared {
                let entry = photo.existing ?? PhotoEntry(id: photo.id, day: photo.day)
                if entry.modelContext == nil { modelContext.insert(entry) }
                if let filename = entry.localOriginalFilename { replacedOriginals.insert(filename) }
                if let filename = entry.localThumbnailFilename { replacedThumbnails.insert(filename) }
                if let filename = entry.localViewPhotoFilename { replacedViews.insert(filename) }
                let metadata = photo.metadata
                entry.day = photo.day
                entry.captureDate = metadata.captureDate
                entry.latitude = metadata.latitude
                entry.longitude = metadata.longitude
                entry.timezone = metadata.timezone
                entry.countryCode = metadata.countryCode
                entry.countryName = metadata.countryName
                entry.city = metadata.city
                entry.caption = metadata.caption
                entry.imageFilename = nil
                entry.imageData = nil
                entry.thumbnailData = nil
                entry.localOriginalFilename = photo.original.filename
                entry.originalContentHash = photo.original.contentHash
                entry.originalByteCount = photo.original.byteCount
                entry.originalSyncState = .localOnly
                entry.localThumbnailFilename = photo.thumbnail.filename
                entry.thumbnailContentHash = photo.thumbnail.contentHash
                entry.thumbnailByteCount = photo.thumbnail.byteCount
                entry.thumbnailModifiedAt = .now
                entry.thumbnailSyncState = .localOnly
                entry.localViewPhotoFilename = photo.view.filename
                entry.viewPhotoContentHash = photo.view.contentHash
                entry.viewPhotoByteCount = photo.view.byteCount
                entry.viewPhotoModifiedAt = .now
                entry.viewPhotoSyncState = .localOnly
                entry.metadataSyncState = .localOnly
                try MetadataSyncCoordinator.recordRestoredMetadata(for: entry)
                invalidateCaches(for: entry)
            }
            try modelContext.save()
        } catch {
            if didStartApplying { modelContext.rollback() }
            let liveEntries = (try? modelContext.fetch(FetchDescriptor<PhotoEntry>())) ?? initialEntries
            let protectedOriginals = oldOriginals.union(liveEntries.compactMap(\.localOriginalFilename))
            let protectedThumbnails = oldThumbnails.union(liveEntries.compactMap(\.localThumbnailFilename))
            let protectedViews = oldViews.union(liveEntries.compactMap(\.localViewPhotoFilename))
            for filename in newOriginals.subtracting(protectedOriginals) { try? originalFileStore.remove(filename: filename) }
            for filename in newThumbnails.subtracting(protectedThumbnails) { try? thumbnailFileStore.remove(filename: filename) }
            for filename in newViews.subtracting(protectedViews) { try? viewPhotoFileStore.remove(filename: filename) }
            throw error
        }
        // Old files are only removed once the entire restore has committed.
        let finalEntries = try modelContext.fetch(FetchDescriptor<PhotoEntry>())
        for filename in replacedOriginals.subtracting(finalEntries.compactMap(\.localOriginalFilename)) {
            try? originalFileStore.remove(filename: filename)
        }
        for filename in replacedThumbnails.subtracting(finalEntries.compactMap(\.localThumbnailFilename)) {
            try? thumbnailFileStore.remove(filename: filename)
        }
        for filename in replacedViews.subtracting(finalEntries.compactMap(\.localViewPhotoFilename)) {
            try? viewPhotoFileStore.remove(filename: filename)
        }
        return BackupImportSummary(imported: prepared.count, skipped: skipped)
    }

    private func originalRevision(_ entry: PhotoEntry) -> String {
        [entry.localOriginalFilename, entry.originalContentHash, entry.imageFilename,
         entry.imageData.map(BackupArchiveReader.hash)].map { $0 ?? "" }.joined(separator: "|")
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
                // Tombstone the loser so its records are removed from the custom
                // CloudKit zones and the metadata coordinator does not resurrect
                // it on the next sync, which would recreate the duplicate.
                PendingSyncDeletionStore.add(entryID: duplicate.id)
                modelContext.delete(duplicate)
                removedCount += 1
            }
            keeper.metadataSyncState = .localOnly
        }

        if removedCount > 0 {
            try modelContext.save()
            Task.detached(priority: .utility) { [flushPendingDeletions] in
                await flushPendingDeletions()
            }
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
            // The entry may be edited or deleted while the rendition is built.
            let filenameBeforeRendition = entry.localViewPhotoFilename
            guard let generatedData = await viewPhotoRendition(from: originalData),
                  entry.modelContext != nil, !entry.isDeleted,
                  entry.localViewPhotoFilename == filenameBeforeRendition,
                  let stored = try? viewPhotoFileStore.write(generatedData, ownerID: entry.id) else {
                continue
            }

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

    func backfillLocationDetails(
        for entries: [PhotoEntry],
        in modelContext: ModelContext,
        geocode: (Double, Double) async -> GeocodedLocation = { latitude, longitude in
            await LocationGeocoder.reverseGeocode(
                latitude: latitude,
                longitude: longitude,
                preferredLocale: Locale(identifier: "en")
            )
        }
    ) async {
        let needsNormalization = !UserDefaults.standard.bool(forKey: "locationNamesNormalizedToEnglish")
        var completedNormalization = true
        for entry in entries {
            guard !Task.isCancelled else { return }
            guard let lat = entry.latitude, let lon = entry.longitude else { continue }

            let hasValidCountryCode = LocationGeocoder.normalizedCountryCode(entry.countryCode) != nil
            let needsBackfill = !hasValidCountryCode || entry.countryName == nil || entry.city == nil
            guard needsBackfill || needsNormalization else { continue }

            let details = await geocode(lat, lon)
            guard !Task.isCancelled else { return }
            // A user may edit or delete the entry while the network request runs.
            guard entry.modelContext != nil, !entry.isDeleted,
                  entry.latitude == lat, entry.longitude == lon else { continue }
            let code = LocationGeocoder.normalizedCountryCode(details.countryCode) ?? entry.countryCode
            let name = details.countryName ?? entry.countryName
            let city = details.city ?? entry.city
            if details.countryCode == nil && details.countryName == nil && details.city == nil {
                completedNormalization = false
            }
            if entry.countryCode != code || entry.countryName != name || entry.city != city {
                entry.countryCode = code
                entry.countryName = name
                entry.city = city
                // Persist each result so cancellation cannot discard earlier repairs.
                do { try modelContext.save() } catch { return }
            }
        }
        if needsNormalization && completedNormalization {
            UserDefaults.standard.set(true, forKey: "locationNamesNormalizedToEnglish")
        }
    }

    func migrateLegacyLibraryIfNeeded(in modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<PhotoEntry>()
        guard let entries = try? modelContext.fetch(descriptor) else { return }

        var migratedAnyEntries = false

        for entry in entries where entry.imageData == nil && entry.localOriginalFilename == nil {
            guard let filename = entry.imageFilename, BackupArchiveReader.isSafeFilename(filename) else { continue }
            let fileURL = legacyFileURL(filename: filename)
            guard fileManager.fileExists(atPath: fileURL.path) else {
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

                // Retain the historical filename as a read-only fallback.
                invalidateCaches(for: entry)
                migratedAnyEntries = true
            } catch {
                continue // Leave legacy bytes available for a later retry/export.
            }
        }

        if migratedAnyEntries {
            try? modelContext.save()
        }

        // Keep the historical originals through upgrades. A missing/stale modern
        // file can still fall back to them, and export does not require migration.
        // Cleanup must be a separate, verified operation, never a launch side effect.
    }

    private func existingEntry(for date: Date, in modelContext: ModelContext) throws -> PhotoEntry? {
        let predicate = #Predicate<PhotoEntry> { entry in
            entry.day == date
        }
        let descriptor = FetchDescriptor<PhotoEntry>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    private var legacyPhotosDirectoryURL: URL {
        legacyDirectoryOverride ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        try Self.renditionData(
            from: data,
            maxPixelSize: Thumbnail.maxPixelSize,
            compressionQuality: Thumbnail.compressionQuality
        )
    }

    private func viewPhotoData(from data: Data) throws -> Data {
        try Self.renditionData(
            from: data,
            maxPixelSize: ViewPhoto.maxPixelSize,
            compressionQuality: ViewPhoto.compressionQuality
        )
    }

    /// Thumbnail and view-photo renditions for one original, decoded and
    /// re-encoded off the main thread. Downsampling a 12-48 MP photo twice is
    /// the slowest part of an import, and on the main actor it froze the UI.
    private func renditions(from data: Data) async throws -> (thumbnail: Data, viewPhoto: Data) {
        try await Task.detached(priority: .userInitiated) {
            let thumbnail = try Self.renditionData(
                from: data,
                maxPixelSize: Thumbnail.maxPixelSize,
                compressionQuality: Thumbnail.compressionQuality
            )
            let viewPhoto = try Self.renditionData(
                from: data,
                maxPixelSize: ViewPhoto.maxPixelSize,
                compressionQuality: ViewPhoto.compressionQuality
            )
            return (thumbnail, viewPhoto)
        }.value
    }

    private func viewPhotoRendition(from data: Data) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Self.renditionData(
                from: data,
                maxPixelSize: ViewPhoto.maxPixelSize,
                compressionQuality: ViewPhoto.compressionQuality
            )
        }.value
    }

    private nonisolated static func renditionData(
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
        let details = await LocationGeocoder.reverseGeocode(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            preferredLocale: Locale(identifier: "en")
        )
        return (details.countryCode, details.countryName, details.city)
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

nonisolated enum PhotoStoreError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "The selected file is not a valid image."
        }
    }
}

nonisolated struct DaymarkBackupEntry: Codable, Sendable, Equatable {
    let id: String?
    let day: Date
    let captureDate: Date?
    var imageFilename: String?
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
    let countryCode: String?
    let countryName: String?
    let city: String?
    let caption: String?

    var legacyImageData: Data? = nil
    var legacyThumbnailData: Data? = nil
    var imageByteCount: Int64? = nil
    var imageSHA256: String? = nil
    var dayKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, day, captureDate, imageFilename
        case latitude, longitude, timezone
        case countryCode, countryName, city, caption
        case imageByteCount, imageSHA256, dayKey
        case legacyImageData = "imageData"
        case legacyThumbnailData = "thumbnailData"
    }
}

nonisolated struct DaymarkBackupPayload: Codable, Sendable {
    let version: Int
    let exportedAt: Date
    let entries: [DaymarkBackupEntry]
}

// SwiftUI asks for the transfer representation off the main thread while
// presenting fileExporter. Under the target's MainActor default isolation this
// type (and its Transferable conformance) would otherwise be main-actor bound,
// and that off-main access traps at runtime.
nonisolated struct DaymarkBackupExportItem: Transferable, Sendable {
    let url: URL
    let entryCount: Int
    let byteCount: Int64

    func cleanUp() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            SentTransferredFile(item.url)
        }
    }
}

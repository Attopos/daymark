import XCTest
import CryptoKit
import SwiftData
import UIKit
@testable import Daymark_Journal

@MainActor
final class daymarkTests: XCTestCase {
    func testNewEntriesStartUntracked() {
        let entry = PhotoEntry(day: Date())

        XCTAssertEqual(entry.metadataSyncState, .untracked)
        XCTAssertEqual(entry.thumbnailSyncState, .untracked)
        XCTAssertEqual(entry.viewPhotoSyncState, .untracked)
        XCTAssertEqual(entry.originalSyncState, .untracked)
        XCTAssertEqual(entry.overallSyncState, .untracked)
    }

    func testOverallStateUsesMostActionableComponent() {
        XCTAssertEqual(
            SyncStateMachine.overallState(
                metadata: .synced,
                thumbnail: .pendingDownload,
                viewPhoto: .synced,
                original: .uploading
            ),
            .uploading
        )
        XCTAssertEqual(
            SyncStateMachine.overallState(
                metadata: .failed,
                thumbnail: .conflict,
                viewPhoto: .synced,
                original: .uploading
            ),
            .conflict
        )
    }

    func testTransitionRecordsAndClearsComponentError() {
        let entry = PhotoEntry(day: Date(), metadataSyncState: .pendingUpload)
        let failureDate = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            entry.transitionSyncState(
                for: .metadata,
                to: .failed,
                at: failureDate,
                errorMessage: "Network unavailable"
            )
        )
        XCTAssertEqual(entry.metadataSyncState, .failed)
        XCTAssertEqual(entry.syncStateUpdatedAt, failureDate)
        XCTAssertEqual(entry.lastSyncErrorComponentRaw, SyncComponent.metadata.rawValue)
        XCTAssertEqual(entry.lastSyncErrorMessage, "Network unavailable")

        XCTAssertTrue(entry.transitionSyncState(for: .metadata, to: .pendingUpload))
        XCTAssertNil(entry.lastSyncErrorComponentRaw)
        XCTAssertNil(entry.lastSyncErrorMessage)
    }

    func testInvalidTransitionDoesNotMutateEntry() {
        let entry = PhotoEntry(day: Date(), originalSyncState: .untracked)

        XCTAssertFalse(entry.transitionSyncState(for: .original, to: .uploading))
        XCTAssertEqual(entry.originalSyncState, .untracked)
        XCTAssertNil(entry.syncStateUpdatedAt)
    }

    func testOriginalPhotoFileStoreWritesReadsAndRemovesData() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = OriginalPhotoFileStore(directoryURL: directoryURL)
        let data = Data("daymark-original".utf8)
        let stored = try store.write(data, ownerID: "entry-1")

        XCTAssertEqual(stored.byteCount, Int64(data.count))
        XCTAssertEqual(stored.contentHash.count, 64)
        XCTAssertTrue(stored.filename.hasSuffix(".image"))
        XCTAssertEqual(try store.read(filename: stored.filename), data)

        let duplicate = try store.write(data, ownerID: "entry-1")
        XCTAssertEqual(duplicate.filename, stored.filename)

        try store.remove(filename: stored.filename)
        XCTAssertThrowsError(try store.read(filename: stored.filename))
    }

    func testOriginalPhotoFileStoreRejectsUnsafeFilename() {
        let store = OriginalPhotoFileStore(
            directoryURL: FileManager.default.temporaryDirectory
        )

        XCTAssertThrowsError(try store.read(filename: "../outside.image"))
    }

    func testComponentSyncStatesPersistIndependently() throws {
        let container = try makeInMemoryContainer()
        let writeContext = ModelContext(container)
        let entry = PhotoEntry(
            day: Date(timeIntervalSince1970: 1_000),
            metadataSyncState: .synced,
            thumbnailSyncState: .pendingDownload,
            viewPhotoSyncState: .synced,
            originalSyncState: .localOnly
        )
        writeContext.insert(entry)
        try writeContext.save()

        let readContext = ModelContext(container)
        let entries = try readContext.fetch(FetchDescriptor<PhotoEntry>())
        let persistedEntry = try XCTUnwrap(entries.first)

        XCTAssertEqual(persistedEntry.metadataSyncState, .synced)
        XCTAssertEqual(persistedEntry.thumbnailSyncState, .pendingDownload)
        XCTAssertEqual(persistedEntry.viewPhotoSyncState, .synced)
        XCTAssertEqual(persistedEntry.originalSyncState, .localOnly)
        XCTAssertEqual(persistedEntry.overallSyncState, .pendingDownload)
    }

    func testPhotoStoreKeepsOriginalOutsideSwiftDataAndRemovesItOnDelete() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let thumbnailDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let viewPhotoDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
            try? FileManager.default.removeItem(at: thumbnailDirectoryURL)
            try? FileManager.default.removeItem(at: viewPhotoDirectoryURL)
        }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let store = PhotoStore(
            originalsDirectoryURL: directoryURL,
            thumbnailsDirectoryURL: thumbnailDirectoryURL,
            viewPhotosDirectoryURL: viewPhotoDirectoryURL
        )
        let imageData = try makeJPEGData()

        try await store.savePhotoData(
            imageData,
            for: Date(timeIntervalSince1970: 2_000),
            in: context
        )

        let entries = try context.fetch(FetchDescriptor<PhotoEntry>())
        let entry = try XCTUnwrap(entries.first)
        let filename = try XCTUnwrap(entry.localOriginalFilename)
        let thumbnailFilename = try XCTUnwrap(entry.localThumbnailFilename)
        let viewPhotoFilename = try XCTUnwrap(entry.localViewPhotoFilename)

        XCTAssertNil(entry.imageData)
        XCTAssertNil(entry.thumbnailData)
        XCTAssertNotNil(store.thumbnailData(for: entry))
        XCTAssertEqual(entry.thumbnailSyncState, .localOnly)
        XCTAssertEqual(entry.thumbnailContentHash?.count, 64)
        XCTAssertNotNil(store.viewPhotoData(for: entry))
        XCTAssertEqual(entry.viewPhotoSyncState, .localOnly)
        XCTAssertEqual(entry.viewPhotoContentHash?.count, 64)
        XCTAssertGreaterThan(try XCTUnwrap(entry.viewPhotoByteCount), 0)
        XCTAssertEqual(entry.originalByteCount, Int64(imageData.count))
        XCTAssertEqual(entry.originalContentHash?.count, 64)
        XCTAssertEqual(entry.originalSyncState, .localOnly)
        XCTAssertEqual(store.originalData(for: entry), imageData)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent(filename).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: thumbnailDirectoryURL.appendingPathComponent(thumbnailFilename).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: viewPhotoDirectoryURL.appendingPathComponent(viewPhotoFilename).path
        ))

        try store.deleteEntry(entry, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<PhotoEntry>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent(filename).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: thumbnailDirectoryURL.appendingPathComponent(thumbnailFilename).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: viewPhotoDirectoryURL.appendingPathComponent(viewPhotoFilename).path
        ))
    }

    func testBackupParserIndexesImagesWithoutEagerCopies() throws {
        let imageData = try makeJPEGData()
        let payload = DaymarkBackupPayload(
            version: 2,
            exportedAt: Date(timeIntervalSince1970: 100),
            entries: [
                DaymarkBackupEntry(
                    id: "backup-entry",
                    day: Date(timeIntervalSince1970: 200),
                    captureDate: nil,
                    imageFilename: "backup-entry.jpg",
                    latitude: nil,
                    longitude: nil,
                    timezone: nil,
                    countryCode: nil,
                    countryName: nil,
                    city: nil,
                    caption: "Imported"
                )
            ]
        )
        let jsonData = try JSONEncoder().encode(payload)
        let archive = ZipArchive.create(entries: [
            .init(path: "entries.json", data: jsonData),
            .init(path: "images/backup-entry.jpg", data: imageData),
        ])
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).zip")
        try archive.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let contents = try PhotoStore().parseBackup(from: archiveURL)

        XCTAssertEqual(contents.payload.entries.count, 1)
        XCTAssertEqual(contents.imageData(named: "backup-entry.jpg"), imageData)
        XCTAssertNil(contents.imageData(named: "missing.jpg"))
    }

    func testBackupImportRestoresIndexedPhotoAssets() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PhotoStore(
            originalsDirectoryURL: rootURL.appendingPathComponent("originals"),
            thumbnailsDirectoryURL: rootURL.appendingPathComponent("thumbnails"),
            viewPhotosDirectoryURL: rootURL.appendingPathComponent("views"),
            conflictPhotosDirectoryURL: rootURL.appendingPathComponent("conflicts")
        )
        let imageData = try makeJPEGData()
        let day = Date(timeIntervalSince1970: 300)
        let payload = DaymarkBackupPayload(
            version: 2,
            exportedAt: Date(timeIntervalSince1970: 100),
            entries: [
                DaymarkBackupEntry(
                    id: "backup-entry",
                    day: day,
                    captureDate: nil,
                    imageFilename: "backup-entry.jpg",
                    latitude: nil,
                    longitude: nil,
                    timezone: "Asia/Shanghai",
                    countryCode: "CN",
                    countryName: "China",
                    city: "Shanghai",
                    caption: "Imported"
                )
            ]
        )
        let archive = ZipArchive.create(entries: [
            .init(path: "entries.json", data: try JSONEncoder().encode(payload)),
            .init(path: "images/backup-entry.jpg", data: imageData),
        ])
        let archiveURL = rootURL.appendingPathComponent("backup.zip")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try archive.write(to: archiveURL)
        let contents = try store.parseBackup(from: archiveURL)
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        try await store.importBackup(from: contents, mode: .overwrite, into: context)

        let entries = try context.fetch(FetchDescriptor<PhotoEntry>())
        let imported = try XCTUnwrap(entries.first)
        XCTAssertEqual(imported.id, "backup-entry")
        XCTAssertEqual(imported.caption, "Imported")
        XCTAssertEqual(imported.originalSyncState, .localOnly)
        XCTAssertEqual(store.originalData(for: imported), imageData)
        XCTAssertNotNil(store.thumbnailData(for: imported))
        XCTAssertNotNil(store.viewPhotoData(for: imported))
    }

    func testEmbeddedThumbnailMigrationMovesDataOutsideSwiftData() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let thumbnailDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: thumbnailDirectoryURL) }
        let embeddedData = Data("legacy-thumbnail".utf8)
        let entry = PhotoEntry(day: .now, thumbnailData: embeddedData)
        context.insert(entry)
        try context.save()
        let store = PhotoStore(thumbnailsDirectoryURL: thumbnailDirectoryURL)

        store.migrateEmbeddedThumbnails(for: [entry], in: context)

        XCTAssertNil(entry.thumbnailData)
        XCTAssertNotNil(entry.localThumbnailFilename)
        XCTAssertEqual(entry.thumbnailByteCount, Int64(embeddedData.count))
        XCTAssertEqual(entry.thumbnailContentHash?.count, 64)
        XCTAssertEqual(entry.thumbnailSyncState, .localOnly)
        XCTAssertEqual(store.thumbnailData(for: entry), embeddedData)
    }

    func testThumbnailSyncCoordinatorUploadsLocalThumbnail() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let thumbnailDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: thumbnailDirectoryURL) }
        let fileStore = ThumbnailPhotoFileStore(directoryURL: thumbnailDirectoryURL)
        let data = Data("thumbnail-upload".utf8)
        let stored = try fileStore.write(data, ownerID: "thumbnail-entry")
        let entry = PhotoEntry(
            id: "thumbnail-entry",
            day: .now,
            localThumbnailFilename: stored.filename,
            thumbnailByteCount: stored.byteCount,
            thumbnailContentHash: stored.contentHash,
            thumbnailModifiedAt: Date(timeIntervalSince1970: 100),
            thumbnailSyncState: .localOnly
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingThumbnailRemoteStore()

        let summary = try await ThumbnailPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: PhotoStore(thumbnailsDirectoryURL: thumbnailDirectoryURL)
        ).syncThumbnails(entries: [entry], in: context)

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(entry.thumbnailSyncState, .synced)
        XCTAssertEqual(remoteStore.uploadRequests.first?.request.data, data)
        XCTAssertEqual(remoteStore.uploadRequests.first?.overwrite, false)
        XCTAssertEqual(remoteStore.batchUploadSizes, [1])
    }

    func testThumbnailSyncCoordinatorDownloadsWhenSyncedFilenameIsNotLocal() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let thumbnailDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: thumbnailDirectoryURL) }
        let data = Data("thumbnail-download".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let remote = RemoteThumbnailPhoto(
            entryID: "remote-thumbnail-entry",
            contentHash: hash,
            byteCount: Int64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        let entry = PhotoEntry(
            id: remote.entryID,
            day: .now,
            localThumbnailFilename: "filename-from-another-device.thumb",
            thumbnailByteCount: remote.byteCount,
            thumbnailContentHash: remote.contentHash,
            thumbnailModifiedAt: remote.modifiedAt,
            thumbnailSyncState: .synced
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingThumbnailRemoteStore(
            inventory: [entry.id: remote],
            downloads: [entry.id: data]
        )
        let photoStore = PhotoStore(thumbnailsDirectoryURL: thumbnailDirectoryURL)

        let summary = try await ThumbnailPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: photoStore
        ).syncThumbnails(entries: [entry], in: context)

        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(entry.thumbnailSyncState, .synced)
        XCTAssertNotEqual(entry.localThumbnailFilename, "filename-from-another-device.thumb")
        XCTAssertEqual(photoStore.thumbnailData(for: entry), data)
    }

    func testViewPhotoReconcileUploadsLocalAssetAndCountsBytes() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = Data("view-photo-upload".utf8)
        let stored = try ViewPhotoFileStore(directoryURL: directoryURL)
            .write(data, ownerID: "view-upload")
        let entry = PhotoEntry(
            id: "view-upload",
            day: .now,
            localViewPhotoFilename: stored.filename,
            viewPhotoByteCount: stored.byteCount,
            viewPhotoContentHash: stored.contentHash,
            viewPhotoModifiedAt: Date(timeIntervalSince1970: 100),
            viewPhotoSyncState: .localOnly
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingViewPhotoRemoteStore()

        let summary = try await ViewPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: PhotoStore(viewPhotosDirectoryURL: directoryURL)
        ).reconcile(entries: [entry], in: context)

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.transferredBytes, Int64(data.count))
        XCTAssertEqual(summary.pendingDownloadCount, 0)
        XCTAssertEqual(entry.viewPhotoSyncState, .synced)
        XCTAssertEqual(remoteStore.uploadRequests.first?.requests.first?.data, data)
        XCTAssertEqual(remoteStore.downloadRequests, [])
    }

    func testViewPhotoReconcileMarksRemoteAssetPendingWithoutDownloading() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = Data("view-photo-remote".utf8)
        let remote = makeRemoteViewPhoto(entryID: "view-remote", data: data)
        let entry = PhotoEntry(id: remote.entryID, day: .now)
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingViewPhotoRemoteStore(
            inventory: [entry.id: remote],
            downloads: [entry.id: data]
        )

        let summary = try await ViewPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: PhotoStore(viewPhotosDirectoryURL: directoryURL)
        ).reconcile(entries: [entry], in: context)

        XCTAssertEqual(summary.pendingDownloadCount, 1)
        XCTAssertEqual(summary.pendingDownloadBytes, Int64(data.count))
        XCTAssertEqual(summary.transferredBytes, 0)
        XCTAssertEqual(entry.viewPhotoSyncState, .pendingDownload)
        XCTAssertNil(entry.localViewPhotoFilename)
        XCTAssertEqual(remoteStore.downloadRequests, [])
    }

    func testViewPhotoDownloadOnDemandStoresVerifiedAsset() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = Data("view-photo-demand".utf8)
        let remote = makeRemoteViewPhoto(entryID: "view-demand", data: data)
        let entry = PhotoEntry(
            id: remote.entryID,
            day: .now,
            viewPhotoByteCount: remote.byteCount,
            viewPhotoContentHash: remote.contentHash,
            viewPhotoModifiedAt: remote.modifiedAt,
            viewPhotoSyncState: .pendingDownload
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingViewPhotoRemoteStore(
            inventory: [entry.id: remote],
            downloads: [entry.id: data]
        )
        let photoStore = PhotoStore(viewPhotosDirectoryURL: directoryURL)

        let downloadedBytes = try await ViewPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: photoStore
        ).downloadOnDemand(entry: entry, in: context)

        XCTAssertEqual(downloadedBytes, Int64(data.count))
        XCTAssertEqual(remoteStore.downloadRequests, [entry.id])
        XCTAssertEqual(entry.viewPhotoSyncState, .synced)
        XCTAssertEqual(photoStore.viewPhotoData(for: entry), data)
        XCTAssertNotNil(entry.localViewPhotoFilename)
    }

    func testOriginalSyncCoordinatorUploadsPendingOriginal() async throws {
        let fixture = try makeOriginalSyncFixture()
        let remoteStore = RecordingOriginalRemoteStore()
        let coordinator = OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        )

        let summary = try await coordinator.syncOriginals(
            entries: [fixture.entry],
            in: fixture.context,
            limits: .unlimited
        )

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertEqual(fixture.entry.originalSyncState, .synced)
        XCTAssertNil(fixture.entry.lastSyncErrorMessage)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(remoteStore.uploadRequests.first?.request.entryID, fixture.entry.id)
        XCTAssertEqual(remoteStore.uploadRequests.first?.request.data, fixture.data)
    }

    func testOriginalSyncCoordinatorRecordsUploadFailure() async throws {
        let fixture = try makeOriginalSyncFixture()
        let remoteStore = RecordingOriginalRemoteStore(uploadError: TestUploadError.offline)
        let coordinator = OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        )

        let summary = try await coordinator.syncOriginals(
            entries: [fixture.entry],
            in: fixture.context,
            limits: .unlimited
        )

        XCTAssertEqual(summary.uploadedCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(fixture.entry.originalSyncState, .failed)
        XCTAssertEqual(fixture.entry.lastSyncErrorComponentRaw, SyncComponent.original.rawValue)
        XCTAssertEqual(fixture.entry.lastSyncErrorMessage, TestUploadError.offline.localizedDescription)
    }

    func testOriginalSyncCoordinatorRejectsMissingLocalFile() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(
            day: .now,
            localOriginalFilename: "missing.image",
            originalByteCount: 100,
            originalContentHash: String(repeating: "a", count: 64),
            originalSyncState: .localOnly
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingOriginalRemoteStore()

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: PhotoStore(
                originalsDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        ).syncOriginals(entries: [entry], in: context, limits: .unlimited)

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(entry.originalSyncState, .failed)
        XCTAssertEqual(entry.lastSyncErrorMessage, "The local original photo is missing.")
        XCTAssertTrue(remoteStore.uploadRequests.isEmpty)
    }

    func testOriginalSyncCoordinatorDownloadsRemoteOnlyOriginal() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let data = Data("remote-original".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = PhotoEntry(
            id: "remote-entry",
            day: .now,
            localOriginalFilename: "other-device.image",
            originalByteCount: Int64(data.count),
            originalContentHash: hash,
            originalSyncState: .synced
        )
        context.insert(entry)
        try context.save()
        let remoteStore = RecordingOriginalRemoteStore(
            inventory: [
                entry.id: RemoteOriginalPhoto(
                    entryID: entry.id,
                    contentHash: hash,
                    byteCount: Int64(data.count),
                    modifiedAt: .now
                )
            ],
            downloads: [entry.id: data]
        )
        let store = PhotoStore(originalsDirectoryURL: directoryURL)

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: store
        ).syncOriginals(entries: [entry], in: context, limits: .unlimited)

        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(entry.originalSyncState, .synced)
        XCTAssertEqual(store.originalData(for: entry), data)
        XCTAssertNotEqual(entry.localOriginalFilename, "other-device.image")
    }

    func testOriginalSyncCoordinatorMarksDifferentHashesAsConflict() async throws {
        let fixture = try makeOriginalSyncFixture()
        let remoteData = Data("remote-conflict-original".utf8)
        let remoteHash = SHA256.hash(data: remoteData)
            .map { String(format: "%02x", $0) }
            .joined()
        let remoteStore = RecordingOriginalRemoteStore(
            inventory: [
                fixture.entry.id: RemoteOriginalPhoto(
                    entryID: fixture.entry.id,
                    contentHash: remoteHash,
                    byteCount: Int64(remoteData.count),
                    modifiedAt: .now
                )
            ],
            downloads: [fixture.entry.id: remoteData]
        )

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).syncOriginals(entries: [fixture.entry], in: fixture.context, limits: .unlimited)

        XCTAssertEqual(summary.conflictCount, 1)
        XCTAssertEqual(fixture.entry.originalSyncState, .conflict)
        XCTAssertEqual(
            fixture.entry.lastSyncErrorMessage,
            "This device and iCloud contain different original photos."
        )
        XCTAssertEqual(fixture.entry.originalConflictRemoteHash, remoteHash)
        XCTAssertEqual(fixture.entry.originalConflictRemoteByteCount, Int64(remoteData.count))
        XCTAssertNotNil(fixture.entry.originalConflictDetectedAt)
        XCTAssertNotNil(fixture.entry.originalConflictRemoteFilename)
        XCTAssertEqual(fixture.store.conflictOriginalData(for: fixture.entry), remoteData)
        XCTAssertTrue(remoteStore.uploadRequests.isEmpty)
    }

    func testOriginalSyncUploadsLocalReplacementWhenCloudStillMatchesBase() async throws {
        let fixture = try makeOriginalSyncFixture()
        let baseHash = String(repeating: "b", count: 64)
        fixture.entry.originalLastSyncedHash = baseHash
        let remoteStore = RecordingOriginalRemoteStore(
            inventory: [
                fixture.entry.id: RemoteOriginalPhoto(
                    entryID: fixture.entry.id,
                    contentHash: baseHash,
                    byteCount: 20,
                    modifiedAt: .now
                )
            ]
        )

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).syncOriginals(entries: [fixture.entry], in: fixture.context, limits: .unlimited)

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.conflictCount, 0)
        XCTAssertEqual(remoteStore.uploadRequests.first?.overwrite, true)
        XCTAssertEqual(fixture.entry.originalLastSyncedHash, fixture.entry.originalContentHash)
    }

    func testOriginalSyncDownloadsRemoteReplacementWhenLocalStillMatchesBase() async throws {
        let fixture = try makeOriginalSyncFixture()
        let baseHash = try XCTUnwrap(fixture.entry.originalContentHash)
        let remoteData = Data("remote-replacement".utf8)
        let remoteHash = SHA256.hash(data: remoteData)
            .map { String(format: "%02x", $0) }
            .joined()
        fixture.entry.originalLastSyncedHash = baseHash
        let remoteStore = RecordingOriginalRemoteStore(
            inventory: [
                fixture.entry.id: RemoteOriginalPhoto(
                    entryID: fixture.entry.id,
                    contentHash: remoteHash,
                    byteCount: Int64(remoteData.count),
                    modifiedAt: .now
                )
            ],
            downloads: [fixture.entry.id: remoteData]
        )

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).syncOriginals(entries: [fixture.entry], in: fixture.context, limits: .unlimited)

        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(summary.conflictCount, 0)
        XCTAssertEqual(remoteStore.downloadRequests, [fixture.entry.id])
        XCTAssertEqual(fixture.store.originalData(for: fixture.entry), remoteData)
        XCTAssertEqual(fixture.entry.originalLastSyncedHash, remoteHash)
    }

    func testMetadataMergeKeepsIndependentOfflineEdits() {
        let baseDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let entry = PhotoEntry(day: .now, city: "Local City", caption: "Local Caption")
        let local = VersionedMetadata(
            snapshot: MetadataSnapshot(entry: entry),
            versions: [
                "city": MetadataFieldVersion(modifiedAt: newerDate, deviceID: "A"),
                "caption": MetadataFieldVersion(modifiedAt: baseDate, deviceID: "A"),
            ]
        )
        entry.city = "Remote City"
        entry.caption = "Remote Caption"
        let remote = VersionedMetadata(
            snapshot: MetadataSnapshot(entry: entry),
            versions: [
                "city": MetadataFieldVersion(modifiedAt: baseDate, deviceID: "B"),
                "caption": MetadataFieldVersion(modifiedAt: newerDate, deviceID: "B"),
            ]
        )

        let merged = MetadataSyncCoordinator(
            remoteStore: RecordingMetadataRemoteStore(),
            deviceID: "A"
        ).merge(local: local, remote: remote)

        XCTAssertEqual(merged.snapshot.city, "Local City")
        XCTAssertEqual(merged.snapshot.caption, "Remote Caption")
    }

    func testMetadataSyncAppliesRemoteFieldAndUploadsMergedRecord() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let entry = PhotoEntry(day: .now, city: "Shanghai", caption: "Local")
        context.insert(entry)
        let coordinator = MetadataSyncCoordinator(
            remoteStore: RecordingMetadataRemoteStore(),
            deviceID: "local-device"
        )
        let local = coordinator.captureLocalChanges(
            for: entry,
            at: Date(timeIntervalSince1970: 100)
        )
        entry.caption = "Local edit"
        let remoteEntry = PhotoEntry(day: entry.day, city: "Tokyo", caption: "Local")
        let remote = VersionedMetadata(
            snapshot: MetadataSnapshot(entry: remoteEntry),
            versions: local.versions.merging([
                "city": MetadataFieldVersion(
                    modifiedAt: Date(timeIntervalSince1970: 300),
                    deviceID: "remote-device"
                )
            ]) { _, new in new }
        )
        let remoteStore = RecordingMetadataRemoteStore(
            inventory: [entry.id: RemoteMetadataRecord(entryID: entry.id, metadata: remote)]
        )

        let summary = try await MetadataSyncCoordinator(
            remoteStore: remoteStore,
            deviceID: "local-device"
        ).sync(entries: [entry], in: context)

        XCTAssertEqual(entry.city, "Tokyo")
        XCTAssertEqual(entry.caption, "Local edit")
        XCTAssertEqual(summary.mergedCount, 1)
        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(remoteStore.uploadedRecords.first?.metadata.snapshot.city, "Tokyo")
        XCTAssertEqual(remoteStore.uploadedRecords.first?.metadata.snapshot.caption, "Local edit")
    }

    func testSyncStatusSnapshotUsesRealPendingBytes() {
        let upload = PhotoEntry(
            day: .now,
            viewPhotoByteCount: 1_024,
            viewPhotoSyncState: .pendingUpload
        )
        let download = PhotoEntry(
            day: .now,
            originalByteCount: 4_096,
            originalSyncState: .pendingDownload
        )
        let store = SyncEngineStatusStore.shared

        store.refresh(entries: [upload, download])

        XCTAssertEqual(store.snapshot.pendingUploadCount, 1)
        XCTAssertEqual(store.snapshot.pendingUploadBytes, 1_024)
        XCTAssertEqual(store.snapshot.pendingDownloadCount, 1)
        XCTAssertEqual(store.snapshot.pendingDownloadBytes, 4_096)
    }

    func testSyncStatusRequiresAttentionWhilePhotoConflictExists() {
        let conflict = PhotoEntry(
            day: .now,
            originalSyncState: .conflict
        )
        conflict.recordOriginalConflict(
            remote: RemoteOriginalPhoto(
                entryID: conflict.id,
                contentHash: String(repeating: "c", count: 64),
                byteCount: 512,
                modifiedAt: .now
            )
        )
        let store = SyncEngineStatusStore.shared

        store.finish(entries: [conflict], confirmed: false)

        XCTAssertEqual(store.snapshot.phase, "Needs Attention")
        XCTAssertEqual(store.snapshot.conflicts.count, 1)
    }

    func testConflictResolverKeepsLocalAndOverwritesRemote() async throws {
        let fixture = try makeOriginalSyncFixture()
        fixture.entry.originalSyncState = .conflict
        fixture.entry.recordOriginalConflict(
            remote: RemoteOriginalPhoto(
                entryID: fixture.entry.id,
                contentHash: String(repeating: "f", count: 64),
                byteCount: 500,
                modifiedAt: .now
            )
        )
        let remoteStore = RecordingOriginalRemoteStore()

        try await OriginalPhotoConflictResolver(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).keepLocal(fixture.entry, in: fixture.context)

        XCTAssertEqual(fixture.entry.originalSyncState, .synced)
        XCTAssertEqual(fixture.entry.originalConflictResolution, .keptLocal)
        XCTAssertNil(fixture.entry.originalConflictRemoteHash)
        XCTAssertNil(fixture.entry.lastSyncErrorMessage)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(remoteStore.uploadRequests.first?.overwrite, true)
        XCTAssertEqual(remoteStore.uploadRequests.first?.request.data, fixture.data)
    }

    func testConflictResolverUsesVerifiedICloudOriginal() async throws {
        let fixture = try makeOriginalSyncFixture()
        let cloudData = Data("icloud-wins".utf8)
        let cloudHash = SHA256.hash(data: cloudData)
            .map { String(format: "%02x", $0) }
            .joined()
        fixture.entry.originalSyncState = .conflict
        fixture.entry.recordOriginalConflict(
            remote: RemoteOriginalPhoto(
                entryID: fixture.entry.id,
                contentHash: cloudHash,
                byteCount: Int64(cloudData.count),
                modifiedAt: .now
            )
        )
        let remoteStore = RecordingOriginalRemoteStore(
            downloads: [fixture.entry.id: cloudData]
        )

        try await OriginalPhotoConflictResolver(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).useICloud(fixture.entry, in: fixture.context)

        XCTAssertEqual(fixture.entry.originalSyncState, .synced)
        XCTAssertEqual(fixture.entry.originalConflictResolution, .usedICloud)
        XCTAssertNil(fixture.entry.originalConflictRemoteHash)
        XCTAssertEqual(fixture.store.originalData(for: fixture.entry), cloudData)
        XCTAssertEqual(fixture.entry.originalContentHash, cloudHash)
    }

    func testConflictResolverUsesPreservedICloudOriginalWithoutNetwork() async throws {
        let fixture = try makeOriginalSyncFixture()
        let cloudData = Data("preserved-icloud-wins".utf8)
        let cloudHash = SHA256.hash(data: cloudData)
            .map { String(format: "%02x", $0) }
            .joined()
        let stored = try fixture.store.storeConflictOriginal(cloudData, for: fixture.entry)
        fixture.entry.originalSyncState = .conflict
        fixture.entry.recordOriginalConflict(
            remote: RemoteOriginalPhoto(
                entryID: fixture.entry.id,
                contentHash: cloudHash,
                byteCount: Int64(cloudData.count),
                modifiedAt: .now
            ),
            filename: stored.filename
        )
        let remoteStore = RecordingOriginalRemoteStore()

        try await OriginalPhotoConflictResolver(
            remoteStore: remoteStore,
            photoStore: fixture.store
        ).useICloud(fixture.entry, in: fixture.context)

        XCTAssertEqual(remoteStore.downloadRequests, [])
        XCTAssertEqual(fixture.store.originalData(for: fixture.entry), cloudData)
        XCTAssertNil(fixture.entry.originalConflictRemoteFilename)
        XCTAssertEqual(fixture.entry.originalConflictResolution, .usedICloud)
    }

    func testConflictResolverRejectsUnverifiedICloudOriginal() async throws {
        let fixture = try makeOriginalSyncFixture()
        fixture.entry.originalSyncState = .conflict
        fixture.entry.recordOriginalConflict(
            remote: RemoteOriginalPhoto(
                entryID: fixture.entry.id,
                contentHash: String(repeating: "a", count: 64),
                byteCount: 20,
                modifiedAt: .now
            )
        )
        let remoteStore = RecordingOriginalRemoteStore(
            downloads: [fixture.entry.id: Data("tampered".utf8)]
        )

        do {
            try await OriginalPhotoConflictResolver(
                remoteStore: remoteStore,
                photoStore: fixture.store
            ).useICloud(fixture.entry, in: fixture.context)
            XCTFail("Expected checksum verification to fail")
        } catch let error as OriginalPhotoSyncError {
            XCTAssertEqual(error, .downloadHashMismatch)
        }

        XCTAssertEqual(fixture.entry.originalSyncState, .conflict)
        XCTAssertEqual(fixture.store.originalData(for: fixture.entry), fixture.data)
    }

    func testOriginalSyncCoordinatorDefersTransfersBeyondBatchLimit() async throws {
        let first = try makeOriginalSyncFixture(entryID: "first-entry")
        let secondData = Data("second-original".utf8)
        let secondFileStore = OriginalPhotoFileStore(directoryURL: first.directoryURL)
        let secondStored = try secondFileStore.write(secondData, ownerID: "second-entry")
        let secondEntry = PhotoEntry(
            id: "second-entry",
            day: .now.addingTimeInterval(1),
            localOriginalFilename: secondStored.filename,
            originalByteCount: secondStored.byteCount,
            originalContentHash: secondStored.contentHash,
            originalSyncState: .localOnly
        )
        first.context.insert(secondEntry)
        try first.context.save()
        let remoteStore = RecordingOriginalRemoteStore()

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: first.store
        ).syncOriginals(
            entries: [first.entry, secondEntry],
            in: first.context,
            limits: OriginalPhotoSyncLimits(
                maximumTransferCount: 1,
                maximumTransferredBytes: .max
            )
        )

        XCTAssertEqual(summary.uploadedCount, 1)
        XCTAssertEqual(summary.deferredCount, 1)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(secondEntry.originalSyncState, .pendingUpload)
    }

    func testOriginalSyncCoordinatorCountsFailedAttemptsAgainstBatchLimit() async throws {
        let first = try makeOriginalSyncFixture(entryID: "failed-first")
        let secondData = Data("deferred-after-failure".utf8)
        let fileStore = OriginalPhotoFileStore(directoryURL: first.directoryURL)
        let secondStored = try fileStore.write(secondData, ownerID: "deferred-second")
        let secondEntry = PhotoEntry(
            id: "deferred-second",
            day: .now.addingTimeInterval(1),
            localOriginalFilename: secondStored.filename,
            originalByteCount: secondStored.byteCount,
            originalContentHash: secondStored.contentHash,
            originalSyncState: .localOnly
        )
        first.context.insert(secondEntry)
        try first.context.save()
        let remoteStore = RecordingOriginalRemoteStore(uploadError: TestUploadError.offline)

        let summary = try await OriginalPhotoSyncCoordinator(
            remoteStore: remoteStore,
            photoStore: first.store
        ).syncOriginals(
            entries: [first.entry, secondEntry],
            in: first.context,
            limits: OriginalPhotoSyncLimits(
                maximumTransferCount: 1,
                maximumTransferredBytes: .max
            )
        )

        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.deferredCount, 1)
        XCTAssertEqual(remoteStore.uploadRequests.count, 1)
        XCTAssertEqual(secondEntry.originalSyncState, .pendingUpload)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([PhotoEntry.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func makeRemoteViewPhoto(entryID: String, data: Data) -> RemoteViewPhoto {
        RemoteViewPhoto(
            entryID: entryID,
            contentHash: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined(),
            byteCount: Int64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
    }

    private func makeOriginalSyncFixture(entryID: String = "sync-entry") throws -> (
        context: ModelContext,
        entry: PhotoEntry,
        store: PhotoStore,
        data: Data,
        directoryURL: URL
    ) {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = OriginalPhotoFileStore(directoryURL: directoryURL)
        let data = Data("original-sync-payload".utf8)
        let stored = try fileStore.write(data, ownerID: entryID)
        let entry = PhotoEntry(
            id: entryID,
            day: .now,
            localOriginalFilename: stored.filename,
            originalByteCount: stored.byteCount,
            originalContentHash: stored.contentHash,
            originalSyncState: .localOnly
        )
        context.insert(entry)
        try context.save()
        return (
            context,
            entry,
            PhotoStore(
                originalsDirectoryURL: directoryURL,
                conflictPhotosDirectoryURL: directoryURL.appendingPathComponent("conflicts")
            ),
            data,
            directoryURL
        )
    }
}

@MainActor
private final class RecordingOriginalRemoteStore: OriginalPhotoRemoteStore {
    struct RecordedUpload {
        let request: OriginalPhotoUploadRequest
        let overwrite: Bool
    }

    private(set) var uploadRequests: [RecordedUpload] = []
    private(set) var downloadRequests: [String] = []
    private let remoteInventory: [String: RemoteOriginalPhoto]
    private let downloads: [String: Data]
    private let uploadError: Error?

    init(
        inventory: [String: RemoteOriginalPhoto] = [:],
        downloads: [String: Data] = [:],
        uploadError: Error? = nil
    ) {
        remoteInventory = inventory
        self.downloads = downloads
        self.uploadError = uploadError
    }

    func inventory() async throws -> [String: RemoteOriginalPhoto] {
        remoteInventory
    }

    func upload(_ request: OriginalPhotoUploadRequest, overwrite: Bool) async throws {
        uploadRequests.append(RecordedUpload(request: request, overwrite: overwrite))
        if let uploadError {
            throw uploadError
        }
    }

    func download(entryID: String) async throws -> Data {
        downloadRequests.append(entryID)
        guard let data = downloads[entryID] else {
            throw OriginalPhotoSyncError.missingRemoteAsset
        }
        return data
    }
}

@MainActor
private final class RecordingThumbnailRemoteStore: ThumbnailPhotoRemoteStore {
    struct RecordedUpload {
        let request: ThumbnailPhotoUploadRequest
        let overwrite: Bool
    }

    private(set) var uploadRequests: [RecordedUpload] = []
    private(set) var batchUploadSizes: [Int] = []
    private let remoteInventory: [String: RemoteThumbnailPhoto]
    private let downloads: [String: Data]

    init(
        inventory: [String: RemoteThumbnailPhoto] = [:],
        downloads: [String: Data] = [:]
    ) {
        remoteInventory = inventory
        self.downloads = downloads
    }

    func inventory() async throws -> [String: RemoteThumbnailPhoto] {
        remoteInventory
    }

    func upload(_ request: ThumbnailPhotoUploadRequest, overwrite: Bool) async throws {
        uploadRequests.append(RecordedUpload(request: request, overwrite: overwrite))
    }

    func upload(_ requests: [ThumbnailPhotoUploadRequest], overwrite: Bool) async throws {
        batchUploadSizes.append(requests.count)
        for request in requests {
            uploadRequests.append(RecordedUpload(request: request, overwrite: overwrite))
        }
    }

    func download(entryID: String) async throws -> Data {
        guard let data = downloads[entryID] else {
            throw ThumbnailPhotoSyncError.missingRemoteAsset
        }
        return data
    }

    func download(entryIDs: [String]) async throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entryID in entryIDs {
            result[entryID] = try await download(entryID: entryID)
        }
        return result
    }
}

@MainActor
private final class RecordingMetadataRemoteStore: MetadataRemoteStore {
    private(set) var uploadedRecords: [RemoteMetadataRecord] = []
    private let remoteInventory: [String: RemoteMetadataRecord]

    init(inventory: [String: RemoteMetadataRecord] = [:]) {
        remoteInventory = inventory
    }

    func inventory() async throws -> [String: RemoteMetadataRecord] {
        remoteInventory
    }

    func upload(_ records: [RemoteMetadataRecord]) async throws {
        uploadedRecords.append(contentsOf: records)
    }
}

@MainActor
private final class RecordingViewPhotoRemoteStore: ViewPhotoRemoteStore {
    struct RecordedUpload {
        let requests: [ViewPhotoUploadRequest]
        let overwrite: Bool
    }

    private(set) var uploadRequests: [RecordedUpload] = []
    private(set) var downloadRequests: [String] = []
    private let remoteInventory: [String: RemoteViewPhoto]
    private let downloads: [String: Data]

    init(
        inventory: [String: RemoteViewPhoto] = [:],
        downloads: [String: Data] = [:]
    ) {
        remoteInventory = inventory
        self.downloads = downloads
    }

    func inventory() async throws -> [String: RemoteViewPhoto] {
        remoteInventory
    }

    func upload(_ requests: [ViewPhotoUploadRequest], overwrite: Bool) async throws {
        uploadRequests.append(RecordedUpload(requests: requests, overwrite: overwrite))
    }

    func download(entryID: String) async throws -> DownloadedViewPhoto {
        downloadRequests.append(entryID)
        guard let remote = remoteInventory[entryID],
              let data = downloads[entryID] else {
            throw ViewPhotoSyncError.missingRemoteAsset
        }
        return DownloadedViewPhoto(remote: remote, data: data)
    }
}

private enum TestUploadError: LocalizedError {
    case offline

    var errorDescription: String? {
        "Network offline"
    }
}
